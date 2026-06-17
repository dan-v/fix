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
const hot = @import("hot.zig");
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

// --- abort-reason diagnostics (why traces fail to record) ---
const op_count = @import("../bytecode/opcode.zig").count;
var abort_underflow: u64 = 0; // VM popped above our model (defensive abort)
var abort_call: u64 = 0; // call/tail_call to a non-arity-1 / non-closure callee
var abort_error: u64 = 0; // recorder error (stack underflow, depth/emit overflow)
var abort_op: [op_count]u64 = @splat(0); // unhandled opcode, by op
var traces_done: u64 = 0;
var suppress_spans: u64 = 0; // implicit-force bodies skipped (recorded as re-force)
var force_inlines: u64 = 0; // trace-built thunks inlined at a force site
var force_inlines_in_done: u64 = 0; // ...that survived into a completed trace
var truncated: u64 = 0; // traces finalized early via side_exit at an unhandled op

pub fn report() void {
    if (comptime !enabled) return;
    if (!hot.report_enabled) return;
    std.debug.print("=== tjit recording aborts: {d} done, suppressed-force-spans={d} underflow={d} call={d} error={d} ===\n", .{ traces_done, suppress_spans, abort_underflow, abort_call, abort_error });
    std.debug.print("=== tjit force-inline: {d} attempted, {d} survived into completed traces; {d} traces truncated ===\n", .{ force_inlines, force_inlines_in_done, truncated });
    // Top unhandled ops.
    var shown: usize = 0;
    while (shown < 12) : (shown += 1) {
        var max: u64 = 0;
        var max_i: usize = op_count;
        for (abort_op, 0..) |c, i| {
            if (c > max) {
                max = c;
                max_i = i;
            }
        }
        if (max == 0) break;
        std.debug.print("  unhandled-op {s}: {d}\n", .{ @tagName(@as(OpCode, @enumFromInt(max_i))), max });
        abort_op[max_i] = 0; // consume for next iteration
    }
}

/// Per-VM recording state, heap-allocated for the duration of one recording
/// and referenced from `vm.tjit_rec` (as `?*anyopaque` to avoid a vm↔tjit
/// import cycle).
pub const Recording = struct {
    trace: ir.Trace,
    rec: Recorder,
    anchor: ChunkId,
    /// `frames_len` at the anchor frame. The recorder's modeled depth is
    /// `root_depth + inlineDepth() - 1`; a VM depth above it is an unmodeled
    /// implicit-force body we suppress (see `observe`).
    root_depth: u32,
    /// True while observation is suppressed inside a nested implicit-force
    /// body. Tracks span entry for the diagnostic counter.
    suppressing: bool = false,
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
    r.rec.startRoot(anchor, local_count, is_lambda) catch {
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
    traces_done += 1;
    for (r.trace.instrs.items) |in| {
        if (in.op == .thunk_resolve) force_inlines_in_done += 1;
    }
    const raw = r.trace.len();
    opt.optimize(&r.trace, vm.allocator) catch {};
    if (hot.report_enabled) printTrace(&r.trace, raw);
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
    // The recorder's inline-frame depth must track the VM's. A VM depth *above*
    // our model means a consumer op (get_attr / a binop / get_local …) forced
    // an unresolved thunk and the interpreter is running that thunk's body in a
    // nested frame we never modeled. We don't inline it: the consumer recorded
    // its operand as a raw (unforced) Ref, and the executor re-forces that Ref
    // through the full `forceValue` (running the body then, deterministically +
    // memoized). So we *suppress* observation until the body unwinds back to
    // our depth, then resume — turning the old hard abort into a recorded
    // re-force. Soundness rests on the guards actually validating re-forced
    // values (e.g. attr_shape deopts on a divergent shape, see exec.zig).
    var expected = r.root_depth + @as(u32, @intCast(r.rec.inlineDepth())) - 1;
    // A deferred `call_n` frame activates once its real callee frame appears:
    // the VM is one deeper than our model AND the current frame is the callee
    // chunk (distinguishing it from a `forceStrictArgs` arg-thunk body, which
    // has a different chunk and stays suppressed).
    if (r.rec.pending_call) |pc| {
        if (vm.frames_len == expected + 1 and vm.frames[vm.frames_len - 1].chunk_id == pc.callee_chunk) {
            r.rec.activatePendingCall() catch {
                abort(vm);
                return;
            };
            expected += 1;
        }
    }
    if (vm.frames_len > expected) {
        if (!r.suppressing) {
            r.suppressing = true;
            suppress_spans += 1;
        }
        return;
    }
    if (vm.frames_len < expected) {
        // Unwound past the anchor frame without observing its `ret` — shouldn't
        // happen on a normal path. Bail defensively.
        abort_underflow += 1;
        abort(vm);
        return;
    }
    r.suppressing = false;
    // A pending force is only live for the gap between forceTop and the
    // interpreter's immediate force; once we reach the next op it's resolved
    // (or was consumed by the inline hook). Clear it so a later implicit force
    // (e.g. inside get_attr) can't be mistaken for an inlinable explicit force.
    r.rec.pending_force = null;
    r.rec.setIp(@intCast(ip));
    observeOp(vm, &r.rec, frame, code, ip, op) catch {
        abort_error += 1;
        abort(vm);
        return;
    };
    if (r.rec.aborted) {
        abort(vm);
    } else if (r.rec.truncate_requested) {
        r.rec.truncate_requested = false;
        // Keep the handled prefix as a truncated trace if we're at anchor depth;
        // otherwise (mid-inline) we can't reconstruct the frame, so abort.
        if (r.rec.inlineDepth() == 1) {
            r.rec.emitSideExit() catch {
                abort(vm);
                return;
            };
            truncated += 1;
            finish(vm);
        } else {
            abort(vm);
        }
    } else if (r.rec.done) {
        finish(vm);
    }
}

/// Force-site hook: the interpreter just claimed an unresolved bytecode thunk
/// (chunk `chunk_id`) and is about to run its body. If we're recording and the
/// thunk being forced is one this trace built (`alloc_thunk`), inline the body
/// — push an inline frame reading the thunk's upvalues — so it becomes a sink
/// candidate. Otherwise do nothing (the body nests and suppression re-forces it
/// at execution). Called from `forceThunkImpl`.
pub fn onForceInline(vm: *VM, chunk_id: ChunkId) void {
    const r = state(vm) orelse return;
    if (!r.rec.pendingForceIsTraceThunk()) return;
    const ch = vm.registry.get(chunk_id) orelse return;
    r.rec.beginForceInline(ch.local_count) catch {
        // Couldn't set up the inline frame — abandon the trace cleanly (the
        // interpreter still runs the body normally).
        abort(vm);
        return;
    };
    force_inlines += 1;
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

/// Resolve a saturated `call_n`/`tail_call_n` callee (stack `[.., callee, a0,
/// .., a(n-1)]`) to an inlinable closure with arity == n. Only the saturated
/// path is inlinable — the under-applied fold (`callValue` per arg) has
/// different control flow, so non-saturated truncates.
fn inlinableCalleeN(vm: *VM, n: u16) ?struct { chunk: ChunkId, local_count: u16 } {
    if (vm.sp < @as(usize, n) + 1) return null;
    const callee = vm.stack[vm.sp - n - 1];
    if (!callee.isClosure()) return null;
    const closure = vm.heap.getClosure(callee.asObjectId()) catch return null;
    const ch = vm.registry.get(closure.chunk_id) orelse return null;
    if (ch.arity != n) return null; // saturated only
    return .{ .chunk = closure.chunk_id, .local_count = ch.local_count };
}

/// Record a `thunk_captures` whose body is a trivial shape — the interpreter
/// pushes a value with no allocation, and so does the trace. `desc_start`/
/// `count` locate the capture descriptors (kind:1, index:2 triples) within
/// `code`. Non-trivial / unsupported shapes abort.
fn recordThunkCaptures(vm: *VM, rec: *Recorder, chunk_id: u32, code: []const u8, desc_start: usize, count: u16) !void {
    const ch = vm.registry.get(chunk_id) orelse return rec.abort();
    const dlen = @as(usize, count) * 3;
    if (desc_start + dlen > code.len) return rec.abort();
    const descriptors = code[desc_start .. desc_start + dlen];
    switch (ch.scheduling.trivial) {
        // `get_upvalue N; ret` → forcing yields capture N's value, pushed
        // unforced exactly as the interpreter's short-circuit does.
        .identity_upvalue => |idx| try pushCaptureRef(rec, descriptors, idx),
        .constant => |ci| try rec.pushConst(ch.constants[ci]),
        .literal => |v| try rec.pushConst(v),
        .builtins => try rec.pushConst(vm.builtins),
        // A real (non-trivial) thunk: emit `alloc_thunk` capturing the same
        // upvalues. This is the sink candidate — escape analysis + force-inline
        // can later make the allocation vanish.
        .none => try recordAllocThunk(rec, chunk_id, descriptors, count),
        // closure_zero/closure_captures/attr_access build a closure/attr-access
        // thunk → need their own alloc IR; abort until that lands.
        else => rec.abort(),
    }
}

/// Cap on captures we model in one `alloc_thunk` (stack buffer for the Refs).
const MAX_THUNK_CAPTURES = 64;

/// Resolve all `count` capture descriptors to Refs and emit `alloc_thunk`.
fn recordAllocThunk(rec: *Recorder, chunk_id: u32, descriptors: []const u8, count: u16) !void {
    if (count > MAX_THUNK_CAPTURES) return rec.abort();
    var refs: [MAX_THUNK_CAPTURES]ir.Ref = undefined;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const off = k * 3;
        const cap_index = readU16(descriptors, off + 1);
        refs[k] = switch (descriptors[off]) {
            0 => try rec.localRef(cap_index),
            1 => try rec.upvalueRef(cap_index),
            else => return rec.abort(),
        };
    }
    try rec.allocThunk(chunk_id, refs[0..count]);
}

/// Resolve capture descriptor `idx` (kind:1, index:2) to its Ref against the
/// recorder's current frame and push it — same dataflow as get_local /
/// get_upvalue (unforced; a capture is closed over lazily).
fn pushCaptureRef(rec: *Recorder, descriptors: []const u8, idx: u16) !void {
    const off = @as(usize, idx) * 3;
    if (off + 3 > descriptors.len) return rec.abort();
    const cap_index = readU16(descriptors, off + 1);
    switch (descriptors[off]) {
        0 => try rec.getLocal(cap_index), // local capture
        1 => try rec.getUpvalue(cap_index), // upvalue capture
        else => rec.abort(),
    }
}

fn observeOp(vm: *VM, rec: *Recorder, frame: *Frame, code: []const u8, ip: usize, op: OpCode) !void {
    switch (op) {
        .push_null => try rec.pushConst(Value.null_val),
        .push_true => try rec.pushConst(Value.boolVal(true)),
        .push_false => try rec.pushConst(Value.boolVal(false)),
        .pop => try rec.dropTop(),
        .constant => try rec.pushConst(frame.chunk_ptr.constants[readU16(code, ip + 1)]),
        // Forcing loads: the interpreter evaluates the slot to WHNF, so the
        // trace forces too (forceTop). Skipping this would let an unforced thunk
        // flow to `ret` / a non-forcing consumer — deep-equal to the
        // interpreter's value but breaking downstream type checks.
        .get_local => {
            try rec.getLocal(code[ip + 1]);
            try rec.forceTop();
        },
        .get_local_long => {
            try rec.getLocal(readU16(code, ip + 1));
            try rec.forceTop();
        },
        .set_local => try rec.setLocal(code[ip + 1]),
        .set_local_long => try rec.setLocal(readU16(code, ip + 1)),
        .get_upvalue => {
            try rec.getUpvalue(readU16(code, ip + 1));
            try rec.forceTop();
        },
        // Capturing loads push the value *unforced* for a closure to capture —
        // they must NOT force (laziness preserved).
        .capture_upvalue => try rec.getUpvalue(readU16(code, ip + 1)),
        .capture_local => try rec.getLocal(code[ip + 1]),
        .capture_local_long => try rec.getLocal(readU16(code, ip + 1)),
        // Conditional: specialize the branch taken at record time, guarding
        // the (already-forced bool) condition. A flipped branch side-exits.
        .jump_if_false => {
            if (vm.sp < 1) return rec.abort();
            const cond = vm.stack[vm.sp - 1];
            if (!cond.isBool()) return rec.abort();
            try rec.guardBool(cond.asBool());
        },
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
            const callee = inlinableCallee(vm) orelse {
                abort_call += 1;
                return rec.requestTruncate();
            };
            try rec.enterCall(callee.chunk, callee.local_count);
        },
        .tail_call => {
            const callee = inlinableCallee(vm) orelse {
                abort_call += 1;
                return rec.requestTruncate();
            };
            try rec.replaceTail(callee.chunk, callee.local_count);
        },
        // Saturated multi-arg calls: inline when the callee arity matches the
        // arg count. `call_n` defers its inline frame (forceStrictArgs nests
        // before the callee frame); `tail_call_n` reuses the frame so its
        // pre-call forcing is naturally suppressed.
        .call_n => {
            const n = code[ip + 1];
            const callee = inlinableCalleeN(vm, n) orelse {
                abort_op[@intFromEnum(op)] += 1;
                return rec.requestTruncate();
            };
            try rec.enterCallN(callee.chunk, callee.local_count, n);
        },
        // tail_call_n inlining (replaceTailN) is built but has an isolated
        // RecursiveThunk bug at exec — truncate for now (the side-exit resumes
        // it correctly via the resume-chunk fix). call_n inlines.
        .tail_call_n => rec.requestTruncate(),
        .ret => try rec.ret(),
        // Thunk creation. The interpreter short-circuits trivial bodies
        // (`identity_upvalue`/`constant`/`literal`/`builtins`) by pushing a
        // value directly with no allocation — the trace mirrors that as pure
        // dataflow. Non-trivial (`.none`) thunks and closure/attr-access shapes
        // still abort (the alloc_* IR + sinking layer on next).
        .thunk_captures => try recordThunkCaptures(vm, rec, readU16(code, ip + 1), code, ip + 5, readU16(code, ip + 3)),
        .thunk_captures_long => try recordThunkCaptures(vm, rec, readU32(code, ip + 1), code, ip + 7, readU16(code, ip + 5)),
        // Everything else (call_n/tail_call_n, jumps, list/attr builds,
        // set_cell_local, …) is unsupported — truncate here (keep the prefix,
        // resume interpreting at this op) rather than discarding the trace.
        else => {
            abort_op[@intFromEnum(op)] += 1;
            rec.requestTruncate();
        },
    }
}

fn printTrace(trace: *const ir.Trace, raw_len: usize) void {
    std.debug.print("--- tjit trace (anchor chunk {d}, {d} raw -> {d} live instrs) ---\n", .{ trace.anchor_chunk, raw_len, opt.liveLen(trace) });
    for (trace.instrs.items, 0..) |instr, i| {
        if (instr.op == .nop) continue;
        std.debug.print("  %{d:<3} {s} a=%{d} b=%{d} aux={d}\n", .{ i, @tagName(instr.op), instr.a, instr.b, instr.aux });
    }
}
