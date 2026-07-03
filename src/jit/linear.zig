//! Linear (whole-body) JIT compiler for the fix bytecode VM.
//!
//! Unlike the peephole stub matcher in `jit.zig` (which recognizes a
//! fixed catalog of tiny exact bytecode shapes), this compiles an
//! *arbitrary* straight-line chunk body op-by-op into native code,
//! falling back to the interpreter (returns null) on any op it doesn't
//! yet handle. Coverage grows by adding op cases; correctness is held by
//! the fallback (uncovered chunks run interpreted) plus the `.drv`
//! oracle.
//!
//! Model: a stack machine whose operand stack lives in native-stack
//! memory at `[rsp + slot*8]` (no VM-struct-layout knowledge needed).
//! Callee-saved regs hold the live context across helper calls:
//!   rbx = vm, r14 = upvalues.ptr, r15 = arg (lambda only).
//! Complex ops (force, call, attr) tail into the existing C-ABI helpers
//! in `jit.zig`, which return `JitResult{value, error_code}` in rax:rdx.
//! After each helper call we `test rdx,rdx; jnz epilogue` to propagate
//! errors. `ret` loads the top operand into rax, zeroes rdx, and jumps to
//! the shared epilogue (restore rsp + callee-saved regs + `ret`).

const std = @import("std");
const jit = @import("native.zig");
const Value = @import("runtime").value.Value;
const Chunk = @import("../bytecode/chunk.zig").Chunk;
const OpCode = @import("../bytecode/opcode.zig").OpCode;

const CodeBuffer = jit.CodeBuffer;

const MAX_CODE = 8192; // max emitted bytes per chunk body
const MAX_DEPTH = 64; // max operand-stack depth supported
const MAX_PATCHES = 128; // max epilogue jump sites

/// Minimal append-only x86-64 emitter. Only the instruction forms the
/// linear compiler needs; memory operands always use disp32 to keep the
/// encoder branch-free.
pub const Emitter = struct {
    buf: [MAX_CODE]u8 = undefined,
    len: usize = 0,
    epi_patches: [MAX_PATCHES]usize = undefined,
    n_patches: usize = 0,
    overflow: bool = false,

    pub fn byte(self: *Emitter, v: u8) void {
        if (self.len >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = v;
        self.len += 1;
    }

    pub fn bytes(self: *Emitter, vs: []const u8) void {
        for (vs) |v| self.byte(v);
    }

    pub fn u32le(self: *Emitter, v: u32) void {
        self.byte(@truncate(v));
        self.byte(@truncate(v >> 8));
        self.byte(@truncate(v >> 16));
        self.byte(@truncate(v >> 24));
    }

    pub fn u64le(self: *Emitter, v: u64) void {
        self.u32le(@truncate(v));
        self.u32le(@truncate(v >> 32));
    }

    // ---- memory operands (disp32) ----

    /// mov [rsp + disp], <reg encoded in `modrm_reg`>  (REX provided).
    pub fn movStoreRsp(self: *Emitter, rex: u8, modrm_reg: u8, disp: u32) void {
        self.byte(rex);
        self.byte(0x89);
        self.byte(0x84 | (modrm_reg << 3)); // mod=10, rm=100(SIB)
        self.byte(0x24); // SIB: base=rsp
        self.u32le(disp);
    }
    /// mov <reg>, [rsp + disp]
    pub fn movLoadRsp(self: *Emitter, rex: u8, modrm_reg: u8, disp: u32) void {
        self.byte(rex);
        self.byte(0x8b);
        self.byte(0x84 | (modrm_reg << 3));
        self.byte(0x24);
        self.u32le(disp);
    }
    /// mov <reg>, [r14 + disp]  (REX.W+B = 0x49 baked into callers)
    pub fn movLoadR14(self: *Emitter, rex: u8, modrm_reg: u8, disp: u32) void {
        self.byte(rex);
        self.byte(0x8b);
        self.byte(0x86 | (modrm_reg << 3)); // mod=10, rm=110 (r14, no SIB)
        self.u32le(disp);
    }

    // Common register-encoded variants (modrm_reg in bits 5:3).
    pub fn storeRaxToStack(self: *Emitter, slot: u32) void {
        self.movStoreRsp(0x48, 0, slot * 8); // rax
    }
    pub fn storeR15ToStack(self: *Emitter, slot: u32) void {
        self.movStoreRsp(0x4c, 7, slot * 8); // r15 (REX.R)
    }
    pub fn loadStackToRax(self: *Emitter, slot: u32) void {
        self.movLoadRsp(0x48, 0, slot * 8);
    }
    pub fn loadStackToRsi(self: *Emitter, slot: u32) void {
        self.movLoadRsp(0x48, 6, slot * 8);
    }
    pub fn loadStackToRdx(self: *Emitter, slot: u32) void {
        self.movLoadRsp(0x48, 2, slot * 8);
    }
    pub fn loadUpvalueToRax(self: *Emitter, slot: u32) void {
        self.movLoadR14(0x49, 0, slot * 8);
    }
    pub fn loadUpvalueToRsi(self: *Emitter, slot: u32) void {
        self.movLoadR14(0x49, 6, slot * 8);
    }

    // ---- immediates / reg moves ----
    pub fn movRaxImm64(self: *Emitter, v: u64) void {
        self.bytes(&.{ 0x48, 0xb8 });
        self.u64le(v);
    }
    pub fn movRdiRbx(self: *Emitter) void {
        self.bytes(&.{ 0x48, 0x89, 0xdf });
    }
    pub fn movRsiR15(self: *Emitter) void {
        self.bytes(&.{ 0x4c, 0x89, 0xfe });
    }
    /// mov rsi, imm64 (48 BE imm64) — e.g. a stable snapshot pointer.
    pub fn movRsiImm64(self: *Emitter, v: u64) void {
        self.bytes(&.{ 0x48, 0xbe });
        self.u64le(v);
    }
    /// mov rdx, rsp (48 89 E2) — the slot-array base for a side-exit helper.
    pub fn movRdxRsp(self: *Emitter) void {
        self.bytes(&.{ 0x48, 0x89, 0xe2 });
    }
    pub fn xorEdxEdx(self: *Emitter) void {
        self.bytes(&.{ 0x31, 0xd2 });
    }
    /// mov edx, imm32 (zero-extends to rdx). For passing an attr-name /
    /// chunk-id immediate as a helper's 3rd C-ABI arg.
    pub fn movEdxImm32(self: *Emitter, v: u32) void {
        self.byte(0xba);
        self.u32le(v);
    }

    // ---- calls / control ----
    /// movabs r11, target ; call r11
    pub fn callHelper(self: *Emitter, target: u64) void {
        self.bytes(&.{ 0x49, 0xbb });
        self.u64le(target);
        self.bytes(&.{ 0x41, 0xff, 0xd3 });
    }
    /// test rdx,rdx ; jnz epilogue  (records a patch site)
    pub fn errCheckToEpilogue(self: *Emitter) void {
        self.bytes(&.{ 0x48, 0x85, 0xd2 }); // test rdx,rdx
        self.bytes(&.{ 0x0f, 0x85 }); // jnz rel32
        self.recordEpiPatch();
        self.u32le(0); // placeholder
    }
    /// jmp epilogue (records a patch site)
    pub fn jmpEpilogue(self: *Emitter) void {
        self.byte(0xe9); // jmp rel32
        self.recordEpiPatch();
        self.u32le(0);
    }
    pub fn recordEpiPatch(self: *Emitter) void {
        if (self.n_patches >= self.epi_patches.len) {
            self.overflow = true;
            return;
        }
        self.epi_patches[self.n_patches] = self.len; // offset of rel32 field
        self.n_patches += 1;
    }

    pub fn prologue(self: *Emitter, reserve: u32) void {
        // push rbx ; push r14 ; push r15
        self.bytes(&.{ 0x53, 0x41, 0x56, 0x41, 0x57 });
        // mov rbx,rdi ; mov r14,rsi ; mov r15,rdx
        self.bytes(&.{ 0x48, 0x89, 0xfb, 0x49, 0x89, 0xf6, 0x49, 0x89, 0xd7 });
        // sub rsp, reserve   (48 81 EC imm32)
        self.bytes(&.{ 0x48, 0x81, 0xec });
        self.u32le(reserve);
    }

    pub fn bindEpilogue(self: *Emitter, reserve: u32) void {
        const epi: usize = self.len;
        // add rsp, reserve ; pop r15 ; pop r14 ; pop rbx ; ret
        self.bytes(&.{ 0x48, 0x81, 0xc4 });
        self.u32le(reserve);
        self.bytes(&.{ 0x41, 0x5f, 0x41, 0x5e, 0x5b, 0xc3 });
        // Patch all jumps to point at `epi`.
        for (self.epi_patches[0..self.n_patches]) |off| {
            const rel: i32 = @intCast(@as(i64, @intCast(epi)) - @as(i64, @intCast(off + 4)));
            std.mem.writeInt(i32, self.buf[off..][0..4], rel, .little);
        }
    }
};

/// Decode the operand-byte length for a supported op. Returns null for
/// ops the linear compiler can't handle (caller falls back).
fn operandLen(op: OpCode) ?usize {
    return switch (op) {
        .constant, .get_upvalue, .capture_upvalue, .constant_ret, .get_upvalue_ret => 2,
        .get_local, .capture_local, .get_local_ret => 1,
        .get_local_long, .capture_local_long, .get_local_ret_long => 2,
        .call, .tail_call, .ret, .halt, .pop, .push_null, .push_true, .push_false => 0,
        else => null,
    };
}

fn readU16(code: []const u8, off: usize) u16 {
    return @as(u16, code[off]) | (@as(u16, code[off + 1]) << 8);
}

/// Compile `ch` (a thunk body if `is_lambda` is false, else a single-arg
/// lambda body) into native code. Returns the appended fn pointer, or
/// null to fall back to the interpreter.
pub fn compileLinear(buf: *CodeBuffer, ch: *const Chunk, is_lambda: bool) ?*const anyopaque {
    if (!jit.enabled) return null;
    if (is_lambda) {
        if (ch.local_count != 1) return null; // only the arg, no extra locals
    } else {
        if (ch.local_count != 0) return null;
    }

    const code = ch.code;
    if (code.len == 0) return null;

    // Pass 1: validate ops + locals, compute max operand-stack depth.
    var depth: i32 = 0;
    var maxdepth: i32 = 0;
    var i: usize = 0;
    var terminated = false;
    while (i < code.len) {
        const op: OpCode = @enumFromInt(code[i]);
        const olen = operandLen(op) orelse return null;
        // Locals only valid for the lambda arg at slot 0.
        switch (op) {
            .get_local, .capture_local, .get_local_ret => {
                if (!is_lambda or code[i + 1] != 0) return null;
            },
            .get_local_long, .capture_local_long, .get_local_ret_long => {
                if (!is_lambda or readU16(code, i + 1) != 0) return null;
            },
            else => {},
        }
        // Stack effect.
        switch (op) {
            .constant, .get_upvalue, .capture_upvalue, .get_local, .capture_local, .get_local_long, .capture_local_long, .push_null, .push_true, .push_false => {
                depth += 1;
            },
            .pop => depth -= 1,
            .call, .tail_call => depth -= 1, // pop2 push1
            .constant_ret, .get_upvalue_ret, .get_local_ret, .get_local_ret_long => {
                depth += 1; // produces the return value
                terminated = true;
            },
            .ret => terminated = true,
            .halt => {},
            else => unreachable, // operandLen already filtered to supported ops
        }
        if (depth < 0 or depth > MAX_DEPTH) return null;
        if (depth > maxdepth) maxdepth = depth;
        i += 1 + olen;
        if (terminated) break;
    }
    if (!terminated) return null;
    if (maxdepth < 1) return null;

    const reserve: u32 = std.mem.alignForward(u32, @as(u32, @intCast(maxdepth)) * 8, 16);

    // Pass 2: emit.
    var e: Emitter = .{};
    e.prologue(reserve);

    depth = 0;
    i = 0;
    while (i < code.len) {
        const op: OpCode = @enumFromInt(code[i]);
        const olen = operandLen(op).?;
        const d: u32 = @intCast(depth);
        switch (op) {
            .constant => {
                const idx = readU16(code, i + 1);
                e.movRaxImm64(@bitCast(ch.constants[idx]));
                e.storeRaxToStack(d);
                depth += 1;
            },
            .push_null => {
                e.movRaxImm64(@bitCast(Value.null_val));
                e.storeRaxToStack(d);
                depth += 1;
            },
            .push_true => {
                e.movRaxImm64(@bitCast(Value.boolVal(true)));
                e.storeRaxToStack(d);
                depth += 1;
            },
            .push_false => {
                e.movRaxImm64(@bitCast(Value.boolVal(false)));
                e.storeRaxToStack(d);
                depth += 1;
            },
            .capture_upvalue => {
                e.loadUpvalueToRax(readU16(code, i + 1));
                e.storeRaxToStack(d);
                depth += 1;
            },
            .get_upvalue => {
                forceUpvalue(&e, readU16(code, i + 1));
                e.storeRaxToStack(d);
                depth += 1;
            },
            .capture_local, .capture_local_long => {
                e.storeR15ToStack(d); // arg
                depth += 1;
            },
            .get_local, .get_local_long => {
                forceArg(&e);
                e.storeRaxToStack(d);
                depth += 1;
            },
            .pop => depth -= 1,
            .call, .tail_call => {
                // arg = top (d-1), callee = (d-2).
                e.loadStackToRdx(@intCast(depth - 1)); // arg
                e.loadStackToRsi(@intCast(depth - 2)); // callee
                e.movRdiRbx();
                e.callHelper(@intFromPtr(&jit.jitCallValue));
                e.errCheckToEpilogue();
                depth -= 2;
                e.storeRaxToStack(@intCast(depth));
                depth += 1;
            },
            .constant_ret => {
                const idx = readU16(code, i + 1);
                e.movRaxImm64(@bitCast(ch.constants[idx]));
                e.xorEdxEdx();
                e.jmpEpilogue();
            },
            .get_upvalue_ret => {
                forceUpvalue(&e, readU16(code, i + 1)); // result in rax
                e.xorEdxEdx();
                e.jmpEpilogue();
            },
            .get_local_ret, .get_local_ret_long => {
                forceArg(&e);
                e.xorEdxEdx();
                e.jmpEpilogue();
            },
            .ret => {
                e.loadStackToRax(@intCast(depth - 1));
                e.xorEdxEdx();
                e.jmpEpilogue();
            },
            .halt => {},
            else => unreachable,
        }
        if (e.overflow) return null;
        i += 1 + olen;
        switch (op) {
            .ret, .constant_ret, .get_upvalue_ret, .get_local_ret, .get_local_ret_long => break,
            else => {},
        }
    }

    e.bindEpilogue(reserve);
    if (e.overflow) return null;
    return @ptrCast(@alignCast(buf.append(e.buf[0..e.len]) orelse return null));
}

/// upvalues[slot] -> rax, forced (jitForceValue). Errors jump to epilogue.
fn forceUpvalue(e: *Emitter, slot: u16) void {
    e.loadUpvalueToRsi(slot); // value arg
    e.movRdiRbx(); // vm
    e.callHelper(@intFromPtr(&jit.jitForceValue));
    e.errCheckToEpilogue();
    // result already in rax
}

/// arg (r15) -> rax, forced.
fn forceArg(e: *Emitter) void {
    e.movRsiR15();
    e.movRdiRbx();
    e.callHelper(@intFromPtr(&jit.jitForceValue));
    e.errCheckToEpilogue();
}

test "compileLinear: thunk body (local_count != 0) is rejected" {
    if (!jit.enabled) return error.SkipZigTest;
    var code = [_]u8{
        @intFromEnum(OpCode.constant_ret), 0, 0,
        @intFromEnum(OpCode.halt),
    };
    var constants = [_]Value{Value.int(1)};
    const ch: Chunk = .{ .code = &code, .constants = &constants, .local_count = 1 };
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compileLinear(&buf, &ch, false));
}

test "compileLinear: empty code body is rejected" {
    if (!jit.enabled) return error.SkipZigTest;
    var code = [_]u8{};
    var constants = [_]Value{};
    const ch: Chunk = .{ .code = &code, .constants = &constants, .local_count = 0 };
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compileLinear(&buf, &ch, false));
}

test "compileLinear: an unsupported opcode is rejected" {
    if (!jit.enabled) return error.SkipZigTest;
    // add_int isn't in operandLen's supported set.
    var code = [_]u8{
        @intFromEnum(OpCode.add_int),
        @intFromEnum(OpCode.ret),
        @intFromEnum(OpCode.halt),
    };
    var constants = [_]Value{};
    const ch: Chunk = .{ .code = &code, .constants = &constants, .local_count = 0 };
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compileLinear(&buf, &ch, false));
}

test "compileLinear: a body with no terminating ret is rejected" {
    if (!jit.enabled) return error.SkipZigTest;
    var code = [_]u8{
        @intFromEnum(OpCode.push_null),
        @intFromEnum(OpCode.pop),
        @intFromEnum(OpCode.halt),
    };
    var constants = [_]Value{};
    const ch: Chunk = .{ .code = &code, .constants = &constants, .local_count = 0 };
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compileLinear(&buf, &ch, false));
}

test "compileLinear: get_local on a non-lambda thunk body is rejected" {
    if (!jit.enabled) return error.SkipZigTest;
    // get_local reading a local is only valid in a lambda body (slot 0 = arg);
    // a thunk body (is_lambda=false) has no locals at all.
    var code = [_]u8{
        @intFromEnum(OpCode.get_local_ret), 0,
        @intFromEnum(OpCode.halt),
    };
    var constants = [_]Value{};
    const ch: Chunk = .{ .code = &code, .constants = &constants, .local_count = 0 };
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compileLinear(&buf, &ch, false));
}

test "compileLinear: constant_ret thunk body compiles and executes" {
    if (!jit.enabled) return error.SkipZigTest;
    var code = [_]u8{
        @intFromEnum(OpCode.constant_ret), 0, 0,
        @intFromEnum(OpCode.halt),
    };
    var constants = [_]Value{Value.int(21)};
    const ch: Chunk = .{ .code = &code, .constants = &constants, .local_count = 0 };
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    const raw = compileLinear(&buf, &ch, false) orelse return error.CompileFailed;
    const fn_ptr: jit.CompiledFn = @ptrCast(@alignCast(raw));
    // constant_ret never touches vm/upvalues — safe with dummy args.
    const result = fn_ptr(undefined, undefined, 0);
    try std.testing.expectEqual(@as(u64, 0), result.error_code);
    try std.testing.expectEqual(@as(i64, 21), result.value.asInt());
}
