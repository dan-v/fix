//! Linear (whole-body) JIT compiler for the fix bytecode VM.
//!
//! Unlike the peephole stub matcher in `native.zig` (which recognizes a
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
//! in `native.zig`, which return `JitResult{value, error_code}` in rax:rdx.
//! After each helper call we `test rdx,rdx; jnz epilogue` to propagate
//! errors. `ret` loads the top operand into rax, zeroes rdx, and jumps to
//! the shared epilogue (restore rsp + callee-saved regs + `ret`).

const std = @import("std");
const jit = @import("native.zig");
const Value = @import("runtime").value.Value;
const Chunk = @import("../bytecode/chunk.zig").Chunk;
const OpCode = @import("../bytecode/opcode.zig").OpCode;

const CodeBuffer = jit.CodeBuffer;
const Emitter = @import("emit.zig").Emitter;

const MAX_DEPTH = 64; // max operand-stack depth supported

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
