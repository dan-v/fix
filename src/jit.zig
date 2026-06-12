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

pub fn jitGetAttr(vm: *anyopaque, attrs_val: Value, name_id: types.InternId) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const access = @import("vm/access.zig");
    const VM = @import("vm.zig").VM;
    const v = access.getAttrValue(@as(*VM, @ptrCast(@alignCast(vm))), attrs_val, name_id) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = v, .error_code = 0 };
}

/// `builtins.<name>` — load `vm.builtins` and look up `name_id`.
/// Bytecode shape: `push_builtins; get_attr N; ret; halt`.
pub fn jitBuiltinAttr(vm: *anyopaque, name_id: types.InternId) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const access = @import("vm/access.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const result = access.getAttrValue(v, v.builtins, name_id) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = result, .error_code = 0 };
}

/// Chain two attr accesses on an upvalue. Bytecode:
/// `get_upvalue_attr N M; get_attr P; ret; halt`.
pub fn jitGetUpvalueAttrAttr(vm: *anyopaque, attrs_val: Value, name1: u32, name2: u32) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const access = @import("vm/access.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const mid = access.getAttrValue(v, attrs_val, name1) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    const result = access.getAttrValue(v, mid, name2) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = result, .error_code = 0 };
}

/// Force an upvalue (the function) and call it with a baked-in
/// constant argument. Bytecode: `get_upvalue N; constant K; call;
/// ret; halt`.
pub fn jitForceCallConst(vm: *anyopaque, func_unforced: Value, arg: Value) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const force = @import("vm/force.zig");
    const closures = @import("vm/closures.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const func = force.forceValue(v, func_unforced) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    const result = closures.callValue(v, func, arg) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = result, .error_code = 0 };
}

/// Force an upvalue function and call it with another upvalue
/// (passed unforced — the callee decides laziness, same as the
/// well-known apply chunks). Bytecode shape:
/// `get_upvalue N; get_upvalue M; call; ret; halt`.
pub fn jitForceCallUpvalue(vm: *anyopaque, func_unforced: Value, arg: Value) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const force = @import("vm/force.zig");
    const closures = @import("vm/closures.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const func = force.forceValue(v, func_unforced) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    const result = closures.callValue(v, func, arg) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = result, .error_code = 0 };
}

/// `get_upvalue N; eq_null; ret; halt` (or `neq_null`). Force the
/// upvalue and compare its kind against null. The compiler emits
/// `eq_null` for explicit `x == null` / `x != null` comparisons,
/// which are pervasive defaulting idioms in Nix.
pub fn jitForceEqNull(vm: *anyopaque, val_unforced: Value) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const force = @import("vm/force.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const forced = force.forceValue(v, val_unforced) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = Value.boolVal(forced.kind() == .null), .error_code = 0 };
}

pub fn jitForceNeqNull(vm: *anyopaque, val_unforced: Value) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const force = @import("vm/force.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const forced = force.forceValue(v, val_unforced) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = Value.boolVal(forced.kind() != .null), .error_code = 0 };
}

/// `get_upvalue N; not; ret; halt`. Force the upvalue, expect a
/// boolean, return its negation. Common as a thunk body for `!x`.
pub fn jitForceNot(vm: *anyopaque, val_unforced: Value) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const run = @import("vm/run.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const b = run.expectBool(v, val_unforced) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = Value.boolVal(!b), .error_code = 0 };
}

/// Three chained attr accesses on an upvalue. Bytecode:
/// `get_upvalue_attr N M; get_attr P; get_attr Q; ret; halt`.
/// Examples: `config.foo.bar.baz`, `pkgs.lib.attrsets.zipAttrs`.
pub fn jitGetUpvalueAttr3(vm: *anyopaque, attrs_val: Value, name1: u32, name2: u32, name3: u32) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    const access = @import("vm/access.zig");
    const VM = @import("vm.zig").VM;
    const v: *VM = @ptrCast(@alignCast(vm));
    const a = access.getAttrValue(v, attrs_val, name1) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    const b = access.getAttrValue(v, a, name2) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    const c = access.getAttrValue(v, b, name3) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = c, .error_code = 0 };
}

/// JIT handler for the well-known `mapattrs_apply` chunk. Equivalent
/// to running:
///   capture_upvalue 0 (func); capture_upvalue 1 (name); call;
///   capture_upvalue 2 (value); tail_call; ret; halt
/// through the interpreter, but skips bytecode dispatch and the
/// inner-frame push for the partial result.
pub fn jitMapAttrsApply(vm: *anyopaque, upvalues_ptr: [*]const Value, upvalues_len: usize) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    _ = upvalues_len;
    const VM = @import("vm.zig").VM;
    const closures = @import("vm/closures.zig");
    const v: *VM = @ptrCast(@alignCast(vm));
    const func = upvalues_ptr[0];
    const name = upvalues_ptr[1];
    const value = upvalues_ptr[2];
    const partial = closures.callValue(v, func, name) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    const result = closures.callValue(v, partial, value) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = result, .error_code = 0 };
}

/// JIT handler for the well-known `genlist_apply` chunk. Body:
///   capture_upvalue 0 (func); capture_upvalue 1 (arg); tail_call;
///   ret; halt
pub fn jitGenListApply(vm: *anyopaque, upvalues_ptr: [*]const Value, upvalues_len: usize) callconv(.c) JitResult {
    if (!enabled) return .{ .value = Value.null_val, .error_code = 0 };
    _ = upvalues_len;
    const VM = @import("vm.zig").VM;
    const closures = @import("vm/closures.zig");
    const v: *VM = @ptrCast(@alignCast(vm));
    const func = upvalues_ptr[0];
    const arg = upvalues_ptr[1];
    const result = closures.callValue(v, func, arg) catch |err| {
        return .{ .value = Value.null_val, .error_code = @intFromError(err) };
    };
    return .{ .value = result, .error_code = 0 };
}

/// RWX executable code buffer. mmap-backed for simplicity (W^X
/// would require remapping after each write; not worth it yet). One
/// instance per Evaluator, owned by the chunk registry — compiled
/// stubs live for the registry's lifetime.
///
/// `append` serializes on a SpinMutex — chunk registration runs
/// concurrently from parallel imports, and an unsynchronized bump
/// of `len` produces silently overlapping stubs that read each
/// other's bytes. (Manifested as MissingAttribute/TypeError on
/// random chunks during NixOS toplevel only at workers >= 2.)
pub const CodeBuffer = struct {
    base: [*]u8,
    capacity: usize,
    len: usize,
    mu: @import("runtime/stable_segments.zig").SpinMutex,

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
        return .{ .base = @ptrCast(raw.ptr), .capacity = aligned, .len = 0, .mu = .{} };
    }

    pub fn deinit(self: *CodeBuffer) void {
        if (!enabled) return;
        std.posix.munmap(@alignCast(self.base[0..self.capacity]));
        self.* = undefined;
    }

    /// Append raw bytes to the buffer, returning a fn-pointer to the
    /// start of the appended region. Caller is responsible for the
    /// bytes being a valid function (e.g., must end in `ret`).
    /// Serialized — safe to call concurrently from multiple
    /// registrations.
    pub fn append(self: *CodeBuffer, bytes: []const u8) ?CompiledFn {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.len + bytes.len > self.capacity) return null;
        const dest = self.base + self.len;
        self.len += bytes.len;
        @memcpy(dest[0..bytes.len], bytes);
        return @ptrCast(@alignCast(dest));
    }
};

/// Try to JIT-compile `ch`'s body. Returns null when the chunk's
/// shape isn't yet supported — caller leaves `ch.jit_code` null and
/// the interpreter handles it.
/// Temporary diagnostic switch; toggle by hand when investigating
/// which bytecode shapes still slip through to the interpreter.
const dump_unsupported = false;

/// Per-shape JIT compile counters, summed across all chunks
/// registered in this process. Read via `compileCounts()`. Cheap
/// (un-atomic) — single-writer per `register` call up to the
/// `CodeBuffer` mutex, and only read post-hoc.
pub var compile_counts: Counts = .{};

pub const Counts = struct {
    constant_ret: u32 = 0,
    push_lit_ret: u32 = 0,
    get_upvalue_ret: u32 = 0,
    get_upvalue_attr_ret: u32 = 0,
    get_upvalue_attr_attr_ret: u32 = 0,
    get_upvalue_attr3_ret: u32 = 0,
    get_upvalue_eq_null_ret: u32 = 0,
    get_upvalue_neq_null_ret: u32 = 0,
    get_upvalue_not_ret: u32 = 0,
    builtin_attr_ret: u32 = 0,
    upvalue_call_const_ret: u32 = 0,
    upvalue_call_upvalue_ret: u32 = 0,
    mapattrs_apply: u32 = 0,
    genlist_apply: u32 = 0,
    /// Chunks that were offered to `compile` but didn't match any
    /// shape; the interpreter handles them.
    unsupported: u32 = 0,
    /// Histogram of unsupported chunks keyed by the first opcode in
    /// the body. Cheap visibility into what shapes the JIT is still
    /// missing — readable via `--print-sched-stats`.
    unsupported_by_first_op: [256]u32 = [_]u32{0} ** 256,
};

pub fn compile(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (!enabled) return null;
    if (compileConstantRet(buf, ch)) |f| {
        compile_counts.constant_ret += 1;
        return f;
    }
    if (compilePushLitRet(buf, ch)) |f| {
        compile_counts.push_lit_ret += 1;
        return f;
    }
    if (compileGetUpvalueRet(buf, ch)) |f| {
        compile_counts.get_upvalue_ret += 1;
        return f;
    }
    if (compileGetUpvalueAttrRet(buf, ch)) |f| {
        compile_counts.get_upvalue_attr_ret += 1;
        return f;
    }
    if (compileGetUpvalueAttrAttrRet(buf, ch)) |f| {
        compile_counts.get_upvalue_attr_attr_ret += 1;
        return f;
    }
    if (compileGetUpvalueAttr3Ret(buf, ch)) |f| {
        compile_counts.get_upvalue_attr3_ret += 1;
        return f;
    }
    if (compileGetUpvalueCmpNullRet(buf, ch, .eq_null, &jitForceEqNull)) |f| {
        compile_counts.get_upvalue_eq_null_ret += 1;
        return f;
    }
    if (compileGetUpvalueCmpNullRet(buf, ch, .neq_null, &jitForceNeqNull)) |f| {
        compile_counts.get_upvalue_neq_null_ret += 1;
        return f;
    }
    if (compileGetUpvalueNotRet(buf, ch)) |f| {
        compile_counts.get_upvalue_not_ret += 1;
        return f;
    }
    if (compileBuiltinAttrRet(buf, ch)) |f| {
        compile_counts.builtin_attr_ret += 1;
        return f;
    }
    if (compileUpvalueCallConstRet(buf, ch)) |f| {
        compile_counts.upvalue_call_const_ret += 1;
        return f;
    }
    if (compileUpvalueCallUpvalueRet(buf, ch)) |f| {
        compile_counts.upvalue_call_upvalue_ret += 1;
        return f;
    }
    if (matchMapAttrsApply(ch)) {
        compile_counts.mapattrs_apply += 1;
        return &jitMapAttrsApply;
    }
    if (matchGenListApply(ch)) {
        compile_counts.genlist_apply += 1;
        return &jitGenListApply;
    }
    compile_counts.unsupported += 1;
    if (ch.code.len > 0) {
        compile_counts.unsupported_by_first_op[ch.code[0]] += 1;
        if (dump_unsupported and ch.code.len <= 24) {
            // Only dump the first 64 instances of each first-op so the
            // sample is enough to spot the dominant shape without
            // drowning out the rest of stderr.
            if (compile_counts.unsupported_by_first_op[ch.code[0]] <= 64) {
                std.debug.print("jit-unsup len={d}:", .{ch.code.len});
                for (ch.code) |b| std.debug.print(" {x:0>2}", .{b});
                std.debug.print("\n", .{});
            }
        }
    }
    return null;
}

/// `get_upvalue_attr N M; get_attr P; ret; halt` →
///   mov rsi, [rsi + 8*N]    ; load upvalues[N]
///   mov edx, M               ; first name
///   mov ecx, P               ; second name
///   jmp jitGetUpvalueAttrAttr
/// `lib.foo.bar` / `config.system.build` pattern.
fn compileGetUpvalueAttrAttrRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 10) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue_attr) return null;
    if (@as(OpCode, @enumFromInt(ch.code[5])) != .get_attr) return null;
    if (@as(OpCode, @enumFromInt(ch.code[8])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[9])) != .halt) return null;
    const slot: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const name1: u16 = @as(u16, ch.code[3]) | (@as(u16, ch.code[4]) << 8);
    const name2: u16 = @as(u16, ch.code[6]) | (@as(u16, ch.code[7]) << 8);
    const disp: u32 = @as(u32, slot) * @sizeOf(Value);

    var stub: [30]u8 = undefined;
    var len: usize = 0;
    if (disp <= 0x7f) {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0x76;
        stub[3] = @intCast(disp);
        len = 4;
    } else {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0xb6;
        std.mem.writeInt(u32, stub[3..7], disp, .little);
        len = 7;
    }
    // mov edx, name1
    stub[len] = 0xba;
    std.mem.writeInt(u32, stub[len + 1 ..][0..4], name1, .little);
    len += 5;
    // mov ecx, name2
    stub[len] = 0xb9;
    std.mem.writeInt(u32, stub[len + 1 ..][0..4], name2, .little);
    len += 5;
    // movabs r11, &jitGetUpvalueAttrAttr ; jmp r11
    const target: u64 = @intFromPtr(&jitGetUpvalueAttrAttr);
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

/// `get_upvalue_attr N M; get_attr P; get_attr Q; ret; halt` →
///   mov rsi, [rsi + 8*N]
///   mov edx, M ; mov ecx, P ; mov r8d, Q
///   jmp jitGetUpvalueAttr3
/// `config.foo.bar.baz` / `pkgs.lib.attrsets.x` pattern.
fn compileGetUpvalueAttr3Ret(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 13) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue_attr) return null;
    if (@as(OpCode, @enumFromInt(ch.code[5])) != .get_attr) return null;
    if (@as(OpCode, @enumFromInt(ch.code[8])) != .get_attr) return null;
    if (@as(OpCode, @enumFromInt(ch.code[11])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[12])) != .halt) return null;
    const slot: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const name1: u16 = @as(u16, ch.code[3]) | (@as(u16, ch.code[4]) << 8);
    const name2: u16 = @as(u16, ch.code[6]) | (@as(u16, ch.code[7]) << 8);
    const name3: u16 = @as(u16, ch.code[9]) | (@as(u16, ch.code[10]) << 8);
    const disp: u32 = @as(u32, slot) * @sizeOf(Value);

    var stub: [36]u8 = undefined;
    var len: usize = 0;
    if (disp <= 0x7f) {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0x76;
        stub[3] = @intCast(disp);
        len = 4;
    } else {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0xb6;
        std.mem.writeInt(u32, stub[3..7], disp, .little);
        len = 7;
    }
    // mov edx, name1
    stub[len] = 0xba;
    std.mem.writeInt(u32, stub[len + 1 ..][0..4], name1, .little);
    len += 5;
    // mov ecx, name2
    stub[len] = 0xb9;
    std.mem.writeInt(u32, stub[len + 1 ..][0..4], name2, .little);
    len += 5;
    // mov r8d, name3
    stub[len] = 0x41;
    stub[len + 1] = 0xb8;
    std.mem.writeInt(u32, stub[len + 2 ..][0..4], name3, .little);
    len += 6;
    // movabs r11, &jitGetUpvalueAttr3 ; jmp r11
    const target: u64 = @intFromPtr(&jitGetUpvalueAttr3);
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

/// `get_upvalue N; eq_null|neq_null; ret; halt` (6 bytes) →
///   mov rsi, [rsi + 8*N]
///   movabs r11, &jitForceEqNull|jitForceNeqNull
///   jmp r11
fn compileGetUpvalueCmpNullRet(buf: *CodeBuffer, ch: *const Chunk, expected_op: OpCode, helper: *const anyopaque) ?CompiledFn {
    if (ch.code.len != 6) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue) return null;
    if (@as(OpCode, @enumFromInt(ch.code[3])) != expected_op) return null;
    if (@as(OpCode, @enumFromInt(ch.code[4])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[5])) != .halt) return null;
    const slot: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const disp: u32 = @as(u32, slot) * @sizeOf(Value);

    var stub: [20]u8 = undefined;
    var len: usize = 0;
    if (disp <= 0x7f) {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0x76;
        stub[3] = @intCast(disp);
        len = 4;
    } else {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0xb6;
        std.mem.writeInt(u32, stub[3..7], disp, .little);
        len = 7;
    }
    const target: u64 = @intFromPtr(helper);
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

/// `get_upvalue N; not; ret; halt` (6 bytes) → load + tail-call helper.
fn compileGetUpvalueNotRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 6) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue) return null;
    if (@as(OpCode, @enumFromInt(ch.code[3])) != .not) return null;
    if (@as(OpCode, @enumFromInt(ch.code[4])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[5])) != .halt) return null;
    const slot: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const disp: u32 = @as(u32, slot) * @sizeOf(Value);

    var stub: [20]u8 = undefined;
    var len: usize = 0;
    if (disp <= 0x7f) {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0x76;
        stub[3] = @intCast(disp);
        len = 4;
    } else {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0xb6;
        std.mem.writeInt(u32, stub[3..7], disp, .little);
        len = 7;
    }
    const target: u64 = @intFromPtr(&jitForceNot);
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

/// `push_builtins; get_attr N; ret; halt` → load `vm.builtins` and
/// tail-call `jitBuiltinAttr`. The `builtins.X` pattern is
/// everywhere in NixOS module code (`builtins.elem`,
/// `builtins.foldl'`, `builtins.toString`, ...).
fn compileBuiltinAttrRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 6) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .push_builtins) return null;
    if (@as(OpCode, @enumFromInt(ch.code[1])) != .get_attr) return null;
    if (@as(OpCode, @enumFromInt(ch.code[4])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[5])) != .halt) return null;
    const name_id: u16 = @as(u16, ch.code[2]) | (@as(u16, ch.code[3]) << 8);

    //   be <imm32>          mov esi, name_id  (zero-extends to rsi)
    //   49 bb <imm64>        movabs r11, &jitBuiltinAttr
    //   41 ff e3             jmp r11
    var stub: [18]u8 = undefined;
    stub[0] = 0xbe;
    std.mem.writeInt(u32, stub[1..5], name_id, .little);
    const target: u64 = @intFromPtr(&jitBuiltinAttr);
    stub[5] = 0x49;
    stub[6] = 0xbb;
    std.mem.writeInt(u64, stub[7..15], target, .little);
    stub[15] = 0x41;
    stub[16] = 0xff;
    stub[17] = 0xe3;
    return buf.append(&stub);
}

/// `get_upvalue N; constant K; call; ret; halt` →
///   mov rsi, [rsi + 8*N]            ; func = upvalues[N] (unforced)
///   movabs rdx, <constant_bits>      ; arg = ch.constants[K] (baked in)
///   movabs r11, &jitForceCallConst
///   jmp r11
/// `f(literal)` pattern; topped the unsupported-chunk frequency
/// histogram on NixOS toplevel.
fn compileUpvalueCallConstRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 9) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue) return null;
    if (@as(OpCode, @enumFromInt(ch.code[3])) != .constant) return null;
    const call_op = @as(OpCode, @enumFromInt(ch.code[6]));
    if (call_op != .call and call_op != .tail_call) return null;
    if (@as(OpCode, @enumFromInt(ch.code[7])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[8])) != .halt) return null;
    const slot: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const const_idx: u16 = @as(u16, ch.code[4]) | (@as(u16, ch.code[5]) << 8);
    if (const_idx >= ch.constants.len) return null;
    const constant_bits: u64 = @bitCast(ch.constants[const_idx]);
    const disp: u32 = @as(u32, slot) * @sizeOf(Value);

    var stub: [30]u8 = undefined;
    var len: usize = 0;
    // Load upvalues[slot] into rsi.
    if (disp <= 0x7f) {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0x76;
        stub[3] = @intCast(disp);
        len = 4;
    } else {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0xb6;
        std.mem.writeInt(u32, stub[3..7], disp, .little);
        len = 7;
    }
    // movabs rdx, <constant_bits>
    stub[len] = 0x48;
    stub[len + 1] = 0xba;
    std.mem.writeInt(u64, stub[len + 2 ..][0..8], constant_bits, .little);
    len += 10;
    // movabs r11, &jitForceCallConst ; jmp r11
    const target: u64 = @intFromPtr(&jitForceCallConst);
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

/// `get_upvalue N; get_upvalue M; call|tail_call; ret; halt` →
///   mov rdx, [rsi + 8*M]     ; arg = upvalues[M] (unforced)
///   mov rsi, [rsi + 8*N]     ; func = upvalues[N] (unforced)
///   movabs r11, &jitForceCallUpvalue
///   jmp r11
/// `f x` where both `f` and `x` are upvalues. The compiler emits
/// `tail_call` for `f x` in tail position, which is the common case
/// for thunk bodies; `call` shows up when the value is consumed by
/// a non-tail op. Both run the same helper — semantics are
/// equivalent for thunk bodies (no frame to elide).
fn compileUpvalueCallUpvalueRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 9) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue) return null;
    if (@as(OpCode, @enumFromInt(ch.code[3])) != .get_upvalue) return null;
    const call_op = @as(OpCode, @enumFromInt(ch.code[6]));
    if (call_op != .call and call_op != .tail_call) return null;
    if (@as(OpCode, @enumFromInt(ch.code[7])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[8])) != .halt) return null;
    const slot_func: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const slot_arg: u16 = @as(u16, ch.code[4]) | (@as(u16, ch.code[5]) << 8);
    const disp_arg: u32 = @as(u32, slot_arg) * @sizeOf(Value);
    const disp_func: u32 = @as(u32, slot_func) * @sizeOf(Value);

    // Important ordering: load the arg into rdx *before* we
    // clobber rsi with the func value, because the upvalues base
    // is in rsi on entry. Two source loads off rsi, one of which
    // also overwrites rsi.
    var stub: [40]u8 = undefined;
    var len: usize = 0;

    // mov rdx, [rsi + 8*slot_arg]
    if (disp_arg <= 0x7f) {
        stub[len] = 0x48;
        stub[len + 1] = 0x8b;
        stub[len + 2] = 0x56;
        stub[len + 3] = @intCast(disp_arg);
        len += 4;
    } else {
        stub[len] = 0x48;
        stub[len + 1] = 0x8b;
        stub[len + 2] = 0x96;
        std.mem.writeInt(u32, stub[len + 3 ..][0..4], disp_arg, .little);
        len += 7;
    }

    // mov rsi, [rsi + 8*slot_func]
    if (disp_func <= 0x7f) {
        stub[len] = 0x48;
        stub[len + 1] = 0x8b;
        stub[len + 2] = 0x76;
        stub[len + 3] = @intCast(disp_func);
        len += 4;
    } else {
        stub[len] = 0x48;
        stub[len + 1] = 0x8b;
        stub[len + 2] = 0xb6;
        std.mem.writeInt(u32, stub[len + 3 ..][0..4], disp_func, .little);
        len += 7;
    }

    // movabs r11, &jitForceCallUpvalue ; jmp r11
    const target: u64 = @intFromPtr(&jitForceCallUpvalue);
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

/// Recognize the exact bytecode shape of the well-known
/// `mapattrs_apply` chunk (`registerMapAttrsApplyChunk`):
///   capture_upvalue 0  ; func
///   capture_upvalue 1  ; name
///   call
///   capture_upvalue 2  ; value
///   tail_call
///   ret
///   halt
fn matchMapAttrsApply(ch: *const Chunk) bool {
    if (ch.local_count != 0) return false;
    if (ch.code.len != 13) return false;
    const expected = [_]u8{
        @intFromEnum(OpCode.capture_upvalue), 0, 0,
        @intFromEnum(OpCode.capture_upvalue), 1, 0,
        @intFromEnum(OpCode.call),
        @intFromEnum(OpCode.capture_upvalue), 2, 0,
        @intFromEnum(OpCode.tail_call),
        @intFromEnum(OpCode.ret),
        @intFromEnum(OpCode.halt),
    };
    return std.mem.eql(u8, ch.code, &expected);
}

/// Recognize the well-known `genlist_apply` chunk
/// (`registerGenListApplyChunk`):
///   capture_upvalue 0  ; func
///   capture_upvalue 1  ; arg
///   tail_call
///   ret
///   halt
fn matchGenListApply(ch: *const Chunk) bool {
    if (ch.local_count != 0) return false;
    if (ch.code.len != 9) return false;
    const expected = [_]u8{
        @intFromEnum(OpCode.capture_upvalue), 0, 0,
        @intFromEnum(OpCode.capture_upvalue), 1, 0,
        @intFromEnum(OpCode.tail_call),
        @intFromEnum(OpCode.ret),
        @intFromEnum(OpCode.halt),
    };
    return std.mem.eql(u8, ch.code, &expected);
}

/// `push_null|push_true|push_false; ret; halt` → bake the literal
/// `Value` bits in and return. Slips through the trivial-body
/// classifier (which only recognizes constant_ret / get_upvalue_ret /
/// closure / push_builtins) so these tiny 3-byte chunks were
/// previously executed by the interpreter end-to-end.
fn compilePushLitRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 3) return null;
    const op: OpCode = @enumFromInt(ch.code[0]);
    const value: Value = switch (op) {
        .push_null => Value.null_val,
        .push_true => Value.boolVal(true),
        .push_false => Value.boolVal(false),
        else => return null,
    };
    if (@as(OpCode, @enumFromInt(ch.code[1])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[2])) != .halt) return null;

    //   48 b8 <imm64>    movabs rax, value.bits
    //   31 d2            xor edx, edx
    //   c3               ret
    var stub: [13]u8 = undefined;
    stub[0] = 0x48;
    stub[1] = 0xb8;
    std.mem.writeInt(u64, stub[2..10], @bitCast(value), .little);
    stub[10] = 0x31;
    stub[11] = 0xd2;
    stub[12] = 0xc3;
    return buf.append(&stub);
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

/// `get_upvalue_attr N M; ret; halt` → load `upvalues[N]` and
/// tail-call `jitGetAttr(vm, val, name_id)`. The common `lib.foo` /
/// `config.bar` chunk after `emitGetAttr`'s `get_upvalue+get_attr`
/// fusion (see `compiler/emit.zig`).
fn compileGetUpvalueAttrRet(buf: *CodeBuffer, ch: *const Chunk) ?CompiledFn {
    if (ch.code.len != 7) return null;
    if (@as(OpCode, @enumFromInt(ch.code[0])) != .get_upvalue_attr) return null;
    if (@as(OpCode, @enumFromInt(ch.code[5])) != .ret) return null;
    if (@as(OpCode, @enumFromInt(ch.code[6])) != .halt) return null;
    const slot: u16 = @as(u16, ch.code[1]) | (@as(u16, ch.code[2]) << 8);
    const name_id: u16 = @as(u16, ch.code[3]) | (@as(u16, ch.code[4]) << 8);
    const disp: u32 = @as(u32, slot) * @sizeOf(Value);

    var stub: [25]u8 = undefined;
    var len: usize = 0;

    // Load upvalues[slot] into rsi (becomes `attrs_val` arg).
    if (disp <= 0x7f) {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0x76;
        stub[3] = @intCast(disp);
        len = 4;
    } else {
        stub[0] = 0x48;
        stub[1] = 0x8b;
        stub[2] = 0xb6;
        std.mem.writeInt(u32, stub[3..7], disp, .little);
        len = 7;
    }

    // mov edx, name_id (zero-extends into rdx)
    //   ba <imm32>
    stub[len] = 0xba;
    std.mem.writeInt(u32, stub[len + 1 ..][0..4], name_id, .little);
    len += 5;

    // movabs r11, &jitGetAttr ; jmp r11
    const target: u64 = @intFromPtr(&jitGetAttr);
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
