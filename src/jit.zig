//! Experimental native-code JIT for fix's bytecode VM.
//!
//! **Build-gated.** Disabled by default; build with `-Djit` on
//! x86_64 Linux. The interpreter remains the canonical path —
//! everything in here is purely an opt-in fast path. Disabling the
//! flag compiles the JIT out entirely (`enabled = false`), so
//! non-x86_64 targets and "I just don't want RWX pages" builds stay
//! identical to the pre-JIT interpreter.
//!
//! Integration model: a `Chunk` optionally holds a
//! `?CompiledFn` pointer. `evalThunkTarget` checks the pointer once;
//! present → call native; null → run the bytecode interpreter as
//! before. Both paths produce the same `Value` and observable
//! state, so a single eval can freely mix JIT'd and interpreted
//! chunks.
//!
//! Scope right now: the foundation only. We expose
//!   - an executable-page allocator (`CodeBuffer`),
//!   - a thin x86_64 emitter,
//!   - a `CompiledFn` ABI definition,
//!   - a "compile" entry point that returns `null` for everything
//!     not yet supported.
//!
//! Subsequent commits will expand the compile pass to cover specific
//! op shapes. The interpreter is the safe fallback for any op we
//! haven't taught the JIT yet, plus anything potentially-yielding
//! (force on a busy thunk, fiber suspension, etc.) which stays on
//! the interpreter for now.

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

/// ABI for JIT'd chunk entry: takes a VM pointer + the chunk's
/// upvalues slice, returns the chunk's result `Value` (or panics on
/// an unrecoverable JIT bug — proper error propagation is future
/// work and currently keeps all error-raising ops on the
/// interpreter).
///
/// Calling convention is the platform default (System V on Linux
/// x86_64): rdi=vm, rsi=upvalues.ptr, rdx=upvalues.len, return in rax.
pub const CompiledFn = *const fn (vm: *anyopaque, upvalues_ptr: [*]const Value, upvalues_len: usize) callconv(.c) Value;

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
/// shape isn't yet supported — caller (`registerChunk`) leaves
/// `ch.jit_code` null and the interpreter handles it.
///
/// Currently handles exactly one shape: a chunk whose entire body
/// is `constant_ret #idx; halt` — i.e., the same trivial body the
/// `.constant` `TrivialBody` arm catches at thunk_captures time, but
/// for the case where the chunk *isn't* used as a thunk body (so the
/// trivial-body short-circuit doesn't fire). Vanishingly rare in
/// practice — this is here to exercise the compile/emit/dispatch
/// loop end-to-end before we expand the op coverage.
pub fn compile(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (!enabled) return null;
    if (ch.code.len != 4) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .constant_ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[3])) != .halt) return null;
    const idx: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    if (idx >= ch.constants.len) return null;
    const value: Value = ch.constants[idx];

    // System V x86_64: return value in rax. The `Value` is an
    // 8-byte struct that lives in a single register on return. We
    // emit `movabs rax, imm64; ret`.
    //
    //   48 b8 <imm64>           movabs rax, imm64
    //   c3                      ret
    var stub: [11]u8 = undefined;
    stub[0] = 0x48;
    stub[1] = 0xb8;
    std.mem.writeInt(u64, stub[2..10], @bitCast(value), .little);
    stub[10] = 0xc3;
    return buf.append(&stub);
}

test "JIT stub: constant_ret round-trips a Value" {
    if (!enabled) return error.SkipZigTest;
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();

    // Synthesize a chunk: constant_ret 0; halt; with one constant.
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

    // Call the stub. Args are unused for this shape but required by ABI.
    const result = fn_ptr(undefined, undefined, 0);
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}
