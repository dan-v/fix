//! Record mode for the tracing JIT (`-Dtjit`): drives the `Recorder` from
//! the interpreter dispatch loop. See `docs/tracing-jit.md`.
//!
//! When a chunk arms (`hot.onEntry` returns true in `stack.pushFrame`), the
//! interpreter `start`s a recording anchored at that frame. Thereafter the
//! dispatch loop calls `observe` before each op, which mirrors the op into
//! Trace IR via the recorder. **Recording is purely observational** — it
//! reads VM state and builds IR; it never alters execution, so a bug here
//! cannot change `.drv` output (worst case: an aborted/garbage trace).
//!
//! Phase 1 (this module): single-frame, no inlining. Any nesting — a `call`,
//! or an *implicit* force that ran a thunk body — moves `frames_len` off the
//! anchor depth, and we abort cleanly. So traces succeed only for leaf-ish
//! chunks whose body forces nothing that nests. That validates the
//! record→IR pipeline on the real workload and prints trace shapes. Inlining
//! through force/call (the valuable part) layers on next.

const std = @import("std");
const build_options = @import("build_options");
const vm_mod = @import("../vm.zig");
const ir = @import("ir.zig");
const Recorder = @import("recorder.zig").Recorder;
const opt = @import("opt.zig");
const codegen = @import("codegen.zig");
const jit = @import("../jit.zig");
const OpCode = @import("../bytecode/opcode.zig").OpCode;
const Value = @import("../runtime/value.zig").Value;
const types = @import("../runtime/types.zig");

pub const enabled: bool = build_options.tjit;

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const ChunkId = types.ChunkId;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;

/// Per-VM recording state, heap-allocated for the duration of one recording
/// and referenced from `vm.tjit_rec` (as `?*anyopaque` to avoid a vm↔tjit
/// import cycle).
pub const Recording = struct {
    trace: ir.Trace,
    rec: Recorder,
    anchor: ChunkId,
    /// `frames_len` at the anchor frame; ops observed at any other depth mean
    /// we've nested and must abort (phase 1 doesn't inline).
    root_depth: u32,
};

fn state(vm: *VM) ?*Recording {
    return @ptrCast(@alignCast(vm.tjit_rec orelse return null));
}

/// Begin recording at a freshly-armed anchor frame. No-op if already
/// recording (we don't nest recordings).
pub fn start(vm: *VM, anchor: ChunkId, local_count: u16, is_lambda: bool, root_depth: u32) void {
    if (vm.tjit_rec != null) return;
    const r = vm.allocator.create(Recording) catch return;
    r.* = .{
        .trace = ir.Trace.init(anchor, is_lambda),
        .rec = undefined,
        .anchor = anchor,
        .root_depth = root_depth,
    };
    r.rec = Recorder.init(vm.allocator, &r.trace);
    r.rec.startRoot(local_count, is_lambda) catch {
        r.rec.deinit();
        r.trace.deinit(vm.allocator);
        vm.allocator.destroy(r);
        return;
    };
    vm.tjit_rec = r;
}

fn teardown(vm: *VM) void {
    const r = state(vm) orelse return;
    r.rec.deinit();
    r.trace.deinit(vm.allocator);
    vm.allocator.destroy(r);
    vm.tjit_rec = null;
}

fn abort(vm: *VM) void {
    const r = state(vm) orelse return;
    const anchor = r.anchor;
    teardown(vm);
    if (vm.registry.hot) |h| h.markAborted(anchor);
}

fn finish(vm: *VM) void {
    const r = state(vm) orelse return;
    const anchor = r.anchor;
    const raw = r.trace.len();
    opt.optimize(&r.trace, vm.allocator) catch {};
    printTrace(&r.trace, raw);
    // Transfer the trace to a stable heap allocation and publish it for
    // execution. Ownership of the trace's arrays moves to `t`; we free the
    // recorder + Recording struct but must NOT deinit the moved-out trace.
    const t = vm.allocator.create(ir.Trace) catch {
        teardown(vm);
        if (vm.registry.hot) |h| h.markTraced(anchor);
        return;
    };
    t.* = r.trace;
    r.rec.deinit();
    vm.allocator.destroy(r);
    vm.tjit_rec = null;
    // Try to lower the trace to native code; fall back to the exec.zig
    // interpreter (publishTrace) either way.
    var native_fn: ?*const anyopaque = null;
    if (comptime jit.code_enabled) {
        const reg = @constCast(vm.registry); // append serializes internally
        native_fn = codegen.compile(&reg.jit_buffer, t);
    }
    if (vm.registry.hot) |h| {
        if (native_fn) |nf| h.publishNative(anchor, @intFromPtr(nf));
        h.publishTrace(anchor, @intFromPtr(t));
    }
}

/// Release a recording abandoned by an unwinding error (called from VM
/// teardown so a mid-trace exception doesn't leak the Recording).
pub fn cleanup(vm: *VM) void {
    teardown(vm);
}

/// Observe one about-to-execute op. Called from `dispatch` only while
/// `vm.tjit_rec != null`.
pub fn observe(vm: *VM, frame: *Frame, code: []const u8, ip: usize, op: OpCode) void {
    const r = state(vm) orelse return;
    // The recorder's inline-frame depth must track the VM's. A mismatch means
    // the VM nested a frame we didn't model — an *implicit* force that ran a
    // thunk body — which we can't linearize without force-inlining. Abort.
    const expected = r.root_depth + @as(u32, @intCast(r.rec.inlineDepth())) - 1;
    if (vm.frames_len != expected) {
        abort(vm);
        return;
    }
    r.rec.setIp(@intCast(ip));
    observeOp(vm, &r.rec, frame, code, ip, op) catch {
        abort(vm);
        return;
    };
    if (r.rec.aborted) {
        abort(vm);
    } else if (r.rec.done) {
        finish(vm);
    }
}

/// Resolve the callee of a `call`/`tail_call` (on the VM operand stack as
/// `[.., callee, arg]`) to an inlinable arity-1 closure chunk, or null.
fn inlinableCallee(vm: *VM) ?struct { chunk: ChunkId, local_count: u16 } {
    if (vm.sp < 2) return null;
    const callee = vm.stack[vm.sp - 2];
    if (!callee.isClosure()) return null;
    const closure = vm.heap.getClosure(callee.asObjectId()) catch return null;
    const ch = vm.registry.get(closure.chunk_id) orelse return null;
    if (ch.arity != 1) return null; // uncurried/saturated calls: later
    return .{ .chunk = closure.chunk_id, .local_count = ch.local_count };
}

fn observeOp(vm: *VM, rec: *Recorder, frame: *Frame, code: []const u8, ip: usize, op: OpCode) !void {
    switch (op) {
        .push_null => try rec.pushConst(Value.null_val),
        .push_true => try rec.pushConst(Value.boolVal(true)),
        .push_false => try rec.pushConst(Value.boolVal(false)),
        .pop => try rec.dropTop(),
        .constant => try rec.pushConst(frame.chunk_ptr.constants[readU16(code, ip + 1)]),
        .get_local => try rec.getLocal(code[ip + 1]),
        .get_local_long => try rec.getLocal(readU16(code, ip + 1)),
        .set_local => try rec.setLocal(code[ip + 1]),
        .set_local_long => try rec.setLocal(readU16(code, ip + 1)),
        .get_upvalue => try rec.getUpvalue(readU16(code, ip + 1)),
        .add_int => try rec.binOp(.add_int),
        .sub_int => try rec.binOp(.sub_int),
        .mul_int => try rec.binOp(.mul_int),
        .eq => try rec.binOp(.eq),
        .lt => try rec.binOp(.lt),
        .not => try rec.unOp(.not),
        .get_attr => try rec.getAttr(readU16(code, ip + 1)),
        .get_attr_long => try rec.getAttr(readU32(code, ip + 1)),
        .get_upvalue_attr => {
            try rec.getUpvalue(readU16(code, ip + 1));
            try rec.getAttr(readU16(code, ip + 3));
        },
        .get_local_attr => {
            try rec.getLocal(code[ip + 1]);
            try rec.getAttr(readU16(code, ip + 2));
        },
        .call => {
            const callee = inlinableCallee(vm) orelse return rec.abort();
            try rec.enterCall(callee.chunk, callee.local_count);
        },
        .tail_call => {
            const callee = inlinableCallee(vm) orelse return rec.abort();
            try rec.replaceTail(callee.chunk, callee.local_count);
        },
        .ret => try rec.ret(),
        // Everything else (call_n/tail_call_n, jumps, allocations,
        // thunk/closure creation, set_cell_local, …) needs handling we don't
        // do yet — abort the trace.
        else => rec.abort(),
    }
}

fn printTrace(trace: *const ir.Trace, raw_len: usize) void {
    std.debug.print("--- tjit trace (anchor chunk {d}, {d} raw -> {d} live instrs) ---\n", .{ trace.anchor_chunk, raw_len, opt.liveLen(trace) });
    for (trace.instrs.items, 0..) |instr, i| {
        if (instr.op == .nop) continue;
        std.debug.print("  %{d:<3} {s} a=%{d} b=%{d} aux={d}\n", .{ i, @tagName(instr.op), instr.a, instr.b, instr.aux });
    }
}
