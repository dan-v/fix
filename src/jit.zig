//! Experimental native-code JIT for fix's bytecode VM.
//!
//! **Build-gated.** Disabled by default; build with `-Djit` on
//! x86_64 Linux. The interpreter remains the canonical path —
//! everything in here is purely an opt-in fast path. Disabling the
//! flag compiles the JIT out entirely (`enabled = false`), so
//! non-x86_64 targets and "I just don't want RWX pages" builds stay
//! identical to the pre-JIT interpreter.
//!
//! Integration model: a `Chunk` optionally holds a `?CompiledFn`
//! pointer. `evalThunkTarget` checks the pointer once; present →
//! call native; null → run the bytecode interpreter as before. Both
//! paths produce the same `Value` and observable state, so a single
//! eval can freely mix JIT'd and interpreted chunks.
//!
//! **Error propagation.** JIT'd code returns a 16-byte `JitResult`
//! struct (System V: low 8 bytes in rax, high 8 bytes in rdx). A
//! zero `error_code` means success; nonzero is `@intFromError(err)`
//! cast back via `@errorFromInt` at the call site. Helpers like
//! `jitForceValue` package any `forceValue` error this way.

const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");

const Value = @import("runtime/value.zig").Value;
const types = @import("runtime/types.zig");
const chunk_mod = @import("bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = @import("bytecode/opcode.zig").OpCode;

/// Compile-time switch. `false` when `-Djit` wasn't passed, or when
/// the target isn't a JIT-supported platform.
pub const enabled: bool = build_options.jit and
    builtin.cpu.arch == .x86_64 and
    builtin.os.tag == .linux;

/// 16-byte struct return: SysV x86_64 returns the low 8 bytes in
/// rax and the high 8 bytes in rdx, so JIT'd code can hand back
/// both `value` and `error_code` in registers without spilling.
pub const JitResult = extern struct {
    value: Value,
    /// 0 = success (`value` is meaningful); nonzero = an
    /// `anyerror` cast via `@intFromError`. The interpreter side
    /// of `evalThunkTarget` reconstructs the error with
    /// `@errorFromInt`.
    error_code: u64 = 0,
};

/// ABI for JIT'd chunk entry: takes a VM pointer + the chunk's
/// upvalues slice, returns `JitResult`.
///
/// Calling convention is System V on Linux x86_64:
///   rdi=vm, rsi=upvalues.ptr, rdx=upvalues.len.
///   return = JitResult: rax=value bits, rdx=error_code.
pub const CompiledFn = *const fn (vm: *anyopaque, upvalues_ptr: [*]const Value, upvalues_len: usize) callconv(.c) JitResult;

/// Helper called from JIT'd code to force a Value through the VM's
/// existing thunk machinery. Wraps `forceValue`'s error union as a
/// `JitResult` so the JIT'd code can tail-call this and return
/// directly.
pub fn jitForceValue(vm: *anyopaque, value: Value) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const force = @import("vm/force.zig");
    const VM = @import("vm.zig").VM;
    const v = force.forceValue(@as(*VM, @ptrCast(@alignCast(vm))), value) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = v, .error_code = 0 };
}

/// RWX executable code buffer. mmap-backed for simplicity (W^X
/// would require remapping after each write; not worth it yet). One
/// instance per Evaluator, owned by the chunk registry — compiled
/// stubs live for the registry's lifetime.
pub const CodeBuffer = struct {
    base: [*]u8,
    capacity: usize,
    len: usize,

    pub fn init(capacity: usize) !CodeBuffer {
        if (!enabled) @compileError("CodeBuffer used in a build without -Djit");
        const aligned = std.mem.alignForward(usize, capacity, std.heap.pageSize());
        const raw = std.posix.mmap(
            null,
            aligned,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.OutOfMemory;
        return .{ .base = @ptrCast(raw.ptr), .capacity = aligned, .len = 0 };
    }

    pub fn deinit(self: *CodeBuffer) void {
        if (!enabled) return;
        std.posix.munmap(@alignCast(self.base[0..self.capacity]));
        self.* = undefined;
    }

    /// Reserve `n` bytes and return a writable pointer to them.
    /// Returns null when full — caller falls back to interpreter.
    pub fn reserve(self: *CodeBuffer, n: usize) ?[*]u8 {
        if (self.len + n > self.capacity) return null;
        const p = self.base + self.len;
        self.len += n;
        return p;
    }

    /// Append raw bytes to the buffer, returning a fn-pointer to the
    /// start of the appended region. Caller is responsible for the
    /// bytes being a valid function (e.g., must end in `ret`).
    pub fn append(self: *CodeBuffer, bytes: []const u8) ?CompiledFn {
        const dest = self.reserve(bytes.len) orelse return null;
        @memcpy(dest[0..bytes.len], bytes);
        return @ptrCast(@alignCast(dest));
    }
};

/// Try to JIT-compile `ch`'s body. Returns null when the chunk's
/// shape isn't yet supported — caller leaves `ch.jit_code` null and
/// the interpreter handles it.
pub fn compile(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (!enabled) return null;
    if (compileConstantRet(buf, ch)) |f| return f;
    if (compileGetUpvalueRet(buf, ch)) |f| return f;
    return null;
}

/// `constant_ret #idx; halt` → `movabs rax, imm64; xor edx, edx; ret`.
/// Same chunk the trivial-body classifier short-circuits at
/// thunk_captures time; here for the rare case the chunk *runs* as
/// bytecode.
fn compileConstantRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 4) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .constant_ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[3])) != .halt) return null;
    const idx: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    if (idx >= ch.constants.len) return null;
    const value: Value = ch.constants[idx];

    //   48 b8 <imm64>           movabs rax, imm64   ; rax = value bits
    //   31 d2                   xor edx, edx        ; rdx = 0 (no error)
    //   c3                      ret
    var stub: [13]u8 = undefined;
    stub[0] = 0x48;
    stub[1] = 0xb8;
    std.mem.writeInt(u64, stub[2..10], @bitCast(value), .little);
    stub[10] = 0x31;
    stub[11] = 0xd2;
    stub[12] = 0xc3;
    return buf.append(&stub);
}

/// `get_upvalue_ret N; halt` → load `upvalues[N]` and tail-call
/// `jitForceValue` for the force. The slow path goes through the
/// existing `forceValue` machinery; the resolved-thunk fast path
/// inside `forceValueImpl` keeps the common case to one inlined
/// branch.
fn compileGetUpvalueRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 4) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue_ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[3])) != .halt) return null;
    const idx: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const disp: u32 = @as(u32, idx) * @sizeOf(Value);

    var stub: [20]u8 = undefined;
    var len: usize = 0;

    // Load upvalues[idx] into rsi (which becomes the `value` arg to
    // the tail-call). rsi already holds upvalues.ptr on entry.
    if (disp <= 0x7f) {
        //   48 8b 76 <disp8>     mov rsi, [rsi + disp8]
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0x76;
        stub[3] = @intCast(disp);
        len = 4;
    } else {
        //   48 8b b6 <disp32>    mov rsi, [rsi + disp32]
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0xb6;
        std.mem.writeInt(u32, stub[3..7], disp, .little);
        len = 7;
    }

    // Tail-call jitForceValue. rdi (vm) is already set; rsi is the
    // value we just loaded; we use r11 as a scratch (caller-saved).
    //   49 bb <imm64>           movabs r11, &jitForceValue
    //   41 ff e3                jmp r11
    const target: u64 = @intFromPtr(&jitForceValue);
    stub[len] = 0x49;
    stub[len + 1] = 0xbb;
    std.mem.writeInt(u64, stub[len + 2 ..][0..8], target, .little);
    len += 10;
    stub[len] = 0x41;
    stub[len + 1] = 0xff;
    stub[len + 2] = 0xe3;
    len += 3;

    return buf.append(stub[0..len]);
}

test "JIT stub: constant_ret round-trips a Value" {
    if (!enabled) return error.SkipZigTest;
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();

    var code = [_]u8{
        @intFromEnum(OpCode.constant_ret), 0, 0,
        @intFromEnum(OpCode.halt),
    };
    var constants = [_]Value{Value.int(42)};
    const ch: Chunk = .{
        .code = &code,
        .constants = &constants,
        .local_count = 0,
    };
    const fn_ptr = compile(&buf, &ch) orelse return error.JitCompileFailed;

    const result = fn_ptr(undefined, undefined, 0);
    try std.testing.expectEqual(@as(u64, 0), result.error_code);
    try std.testing.expectEqual(@as(i64, 42), result.value.asInt());
}

test "JIT stub: get_upvalue_ret loads from upvalues and forces" {
    if (!enabled) return error.SkipZigTest;
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();

    // get_upvalue_ret 1; halt — load upvalues[1].
    var code = [_]u8{
        @intFromEnum(OpCode.get_upvalue_ret), 1, 0,
        @intFromEnum(OpCode.halt),
    };
    var constants = [_]Value{};
    const ch: Chunk = .{
        .code = &code,
        .constants = &constants,
        .local_count = 0,
    };
    const fn_ptr = compile(&buf, &ch) orelse return error.JitCompileFailed;

    // For a non-thunk Value, `jitForceValue` returns it unchanged
    // (forceValueImpl's early-out for `!isThunk`). We don't need a
    // real VM to exercise that path — `forceValue`'s `if
    // (!value.isThunk()) return value;` runs first.
    //
    // We can't fully test the thunk-forcing path here without a VM,
    // but the eager-return case proves the stack-frame setup and
    // tail-call mechanics work.
    const upvalues = [_]Value{ Value.int(99), Value.boolVal(true) };
    var dummy_vm: usize = 0; // never dereferenced for non-thunk values
    const result = fn_ptr(@ptrCast(&dummy_vm), &upvalues, upvalues.len);
    try std.testing.expectEqual(@as(u64, 0), result.error_code);
    try std.testing.expectEqual(true, result.value.asBool());
}
