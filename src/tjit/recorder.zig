//! Trace recorder for the tracing JIT (`-Dtjit`).
//!
//! Driven by the interpreter (a method per executed op). It keeps an
//! **inline-frame stack** and a shared **abstract operand stack** of IR
//! `Ref`s, emitting IR as it goes. Inlining is the point: `enterCall` pushes
//! an inline frame whose first local *is the caller's argument Ref* — so a
//! callee's parameter reads become direct uses of the caller's value, with no
//! frame at trace-execution time. That's what later lets allocation sinking
//! delete intermediate thunks/attrsets. See `docs/tracing-jit.md`.
//!
//! Locals and upvalues are pure dataflow (resolved to existing Refs, no IR);
//! only genuine effects (force/get_attr/call guards, arithmetic) emit IR. The
//! driver keeps the recorder's frame depth in lock-step with the VM's, so an
//! *unmodeled* nesting (an implicit force that ran a thunk body) is detected
//! as a depth mismatch and aborts the trace.

const std = @import("std");
const ir = @import("ir.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;

const Trace = ir.Trace;
const Ref = ir.Ref;
const Op = ir.Op;
const GuardKind = ir.GuardKind;
const InternId = types.InternId;
const ChunkId = types.ChunkId;

pub const MAX_TRACE_LEN: usize = 4096;
pub const MAX_INLINE_DEPTH: usize = 64;

/// One inlined call frame. `locals[i]` is the IR Ref currently in local slot
/// `i` (null = uninitialized). `upvalue_src` is null for the anchor frame
/// (upvalues are a trace input → `load_upvalue`) or the callee's func Ref for
/// an inlined frame (→ `load_upvalue_of`). `operand_base` is where this
/// frame's operands start in the shared operand stack.
const InlineFrame = struct {
    locals: []?Ref,
    upvalue_src: ?Ref,
    operand_base: u32,
    /// The frame's current chunk (changes on a tail call). Needed so a side-exit
    /// resumes the right bytecode, not the anchor's.
    chunk_id: ChunkId = 0,
    /// For a *force-inlined thunk body*: the thunk's Ref. On this frame's `ret`
    /// the recorder emits `thunk_resolve(thunk, result)`. Null for call frames
    /// and the anchor (a call/anchor `ret` just yields its value).
    resolve_thunk: ?Ref = null,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    trace: *Trace,
    operand: std.ArrayListUnmanaged(Ref) = .empty,
    frames: std.ArrayListUnmanaged(InlineFrame) = .empty,
    ip: u32 = 0,
    aborted: bool = false,
    done: bool = false,
    /// Set by an op handler that can't continue the trace but reached a clean
    /// op boundary — the driver finalizes a truncated trace (side-exit) if at
    /// anchor depth, else aborts. Distinct from `aborted` (a broken state).
    truncate_requested: bool = false,
    /// Set to the `force` instr Ref right after `forceTop` emits one. If the
    /// interpreter then runs an unresolved thunk body (force-site hook), this
    /// tells the recorder which `force` to convert into an inlined thunk body.
    /// Cleared by the driver before each observed op.
    pending_force: ?Ref = null,

    pub fn init(allocator: std.mem.Allocator, trace: *Trace) Recorder {
        return .{ .allocator = allocator, .trace = trace };
    }

    pub fn deinit(self: *Recorder) void {
        for (self.frames.items) |f| self.allocator.free(f.locals);
        self.frames.deinit(self.allocator);
        self.operand.deinit(self.allocator);
    }

    /// Push the anchor frame. For an arity-1 lambda, local 0 is the trace
    /// argument; a thunk anchor has no locals.
    pub fn startRoot(self: *Recorder, anchor_chunk: ChunkId, local_count: u16, is_lambda: bool) !void {
        const locals = try self.allocator.alloc(?Ref, local_count);
        @memset(locals, null);
        try self.frames.append(self.allocator, .{ .locals = locals, .upvalue_src = null, .operand_base = 0, .chunk_id = anchor_chunk });
        if (is_lambda and local_count >= 1) {
            locals[0] = try self.emit(.{ .op = .trace_arg });
        }
    }

    pub fn setIp(self: *Recorder, ip: u32) void {
        self.ip = ip;
    }

    pub fn inlineDepth(self: *const Recorder) usize {
        return self.frames.items.len;
    }

    pub fn operandLen(self: *const Recorder) usize {
        return self.operand.items.len;
    }

    fn cur(self: *Recorder) *InlineFrame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn emit(self: *Recorder, instr: ir.Instr) !Ref {
        if (self.trace.len() >= MAX_TRACE_LEN) return error.TraceAborted;
        return self.trace.emit(self.allocator, instr);
    }

    fn push(self: *Recorder, ref: Ref) !void {
        try self.operand.append(self.allocator, ref);
    }

    fn pop(self: *Recorder) !Ref {
        if (self.operand.items.len == 0) return error.TraceAborted;
        return self.operand.pop().?;
    }

    fn snapshot(self: *Recorder) !u32 {
        const items = self.operand.items;
        var entries = try self.allocator.alloc(ir.SnapshotEntry, items.len);
        defer self.allocator.free(entries);
        for (items, 0..) |ref, i| entries[i] = .{ .ref = ref, .loc = .{ .stack = @intCast(i) } };
        return self.trace.addSnapshot(self.allocator, self.ip, entries);
    }

    // ---- inputs ----

    pub fn pushConst(self: *Recorder, v: Value) !void {
        const cidx = try self.trace.addConst(self.allocator, v);
        try self.push(try self.emit(.{ .op = .const_val, .aux = cidx }));
    }

    /// Resolve a frame local to its current Ref without pushing (for collecting
    /// capture operands). Aborts if the slot was never written in the trace.
    pub fn localRef(self: *Recorder, slot: u16) !Ref {
        const f = self.cur();
        if (slot >= f.locals.len) return error.TraceAborted;
        return f.locals[slot] orelse error.TraceAborted;
    }

    pub fn getLocal(self: *Recorder, slot: u16) !void {
        try self.push(try self.localRef(slot));
    }

    pub fn setLocal(self: *Recorder, slot: u16) !void {
        const f = self.cur();
        if (slot >= f.locals.len) return error.TraceAborted;
        f.locals[slot] = try self.pop();
    }

    /// Resolve an upvalue to a Ref without pushing (for collecting captures).
    pub fn upvalueRef(self: *Recorder, slot: u16) !Ref {
        const f = self.cur();
        if (f.upvalue_src) |src| {
            return self.emit(.{ .op = .load_upvalue_of, .a = src, .aux = slot });
        }
        return self.emit(.{ .op = .load_upvalue, .aux = slot });
    }

    pub fn getUpvalue(self: *Recorder, slot: u16) !void {
        try self.push(try self.upvalueRef(slot));
    }

    /// Emit `alloc_thunk` capturing `refs` (in upvalue order) for body `chunk_id`,
    /// pushing the new thunk's Ref. The captures live in the trace's `extra`
    /// side-array so a thunk can close over any number of upvalues.
    pub fn allocThunk(self: *Recorder, chunk_id: ChunkId, refs: []const Ref) !void {
        const start = try self.trace.addExtra(self.allocator, refs);
        try self.push(try self.emit(.{ .op = .alloc_thunk, .a = start, .b = @intCast(refs.len), .aux = chunk_id }));
    }

    /// Force the top-of-stack value to WHNF, replacing it with the forced Ref.
    /// Emitted for the *forcing* load opcodes (`get_local`/`get_upvalue`) so the
    /// trace reproduces the interpreter's evaluation exactly — without it a body
    /// like `get_upvalue 0; ret` would carry an unforced thunk where the
    /// interpreter produced WHNF (deep-equal, but breaks downstream type checks).
    /// `capture_*` opcodes intentionally skip this (closure captures stay lazy).
    pub fn forceTop(self: *Recorder) !void {
        const v = try self.pop();
        const f = try self.emit(.{ .op = .force, .a = v });
        try self.push(f);
        self.pending_force = f;
    }

    /// Is the operand of the pending `force` an `alloc_thunk` (a thunk built in
    /// this trace)? Only those are worth force-inlining — inlining yields a
    /// sink candidate; inlining a thunk created elsewhere is pure overhead.
    pub fn pendingForceIsTraceThunk(self: *Recorder) bool {
        const f = self.pending_force orelse return false;
        const src = self.trace.instrs.items[f].a;
        return self.trace.instrs.items[src].op == .alloc_thunk;
    }

    /// Begin inlining a forced thunk's body. Converts the pending `force` into
    /// a `thunk_claim` (claims the thunk at run time), removes the force's
    /// placeholder result from the operand stack, and pushes a new inline frame
    /// whose upvalues read the thunk (`load_upvalue_of(thunk, slot)`). The
    /// body's `ret` will emit `thunk_resolve` and leave the value on the stack.
    pub fn beginForceInline(self: *Recorder, local_count: u16) !void {
        if (self.frames.items.len >= MAX_INLINE_DEPTH) return error.TraceAborted;
        const f = self.pending_force orelse return error.TraceAborted;
        self.pending_force = null;
        const thunk_ref = self.trace.instrs.items[f].a;
        // The force's pushed result must be the operand-stack top; drop it.
        if (self.operand.items.len == 0 or self.operand.items[self.operand.items.len - 1] != f)
            return error.TraceAborted;
        _ = self.operand.pop();
        // Repurpose the force instr as the claim of the thunk.
        self.trace.instrs.items[f] = .{ .op = .thunk_claim, .a = thunk_ref };
        const locals = try self.allocator.alloc(?Ref, local_count);
        @memset(locals, null);
        try self.frames.append(self.allocator, .{
            .locals = locals,
            .upvalue_src = thunk_ref,
            .operand_base = @intCast(self.operand.items.len),
            .resolve_thunk = thunk_ref,
        });
    }

    // ---- stack shuffles ----

    pub fn dropTop(self: *Recorder) !void {
        _ = try self.pop();
    }

    pub fn dup(self: *Recorder) !void {
        if (self.operand.items.len == 0) return error.TraceAborted;
        try self.push(self.operand.items[self.operand.items.len - 1]);
    }

    // ---- pure ops ----

    pub fn binOp(self: *Recorder, op: Op) !void {
        const b = try self.pop();
        const a = try self.pop();
        try self.push(try self.emit(.{ .op = op, .a = a, .b = b }));
    }

    pub fn unOp(self: *Recorder, op: Op) !void {
        const a = try self.pop();
        try self.push(try self.emit(.{ .op = op, .a = a }));
    }

    // ---- guarded effects ----

    pub fn getAttr(self: *Recorder, name: InternId) !void {
        if (self.operand.items.len == 0) return error.TraceAborted;
        const attrs = self.operand.items[self.operand.items.len - 1];
        const snap = try self.snapshot();
        _ = try self.pop();
        _ = try self.emit(.{ .op = .guard, .a = attrs, .aux = @intFromEnum(GuardKind.attr_shape), .aux2 = name, .snapshot = snap });
        try self.push(try self.emit(.{ .op = .get_attr, .a = attrs, .aux = name }));
    }

    /// Inline a call: pop func + arg, guard the callee chunk, push an inline
    /// frame whose local 0 is the arg Ref.
    pub fn enterCall(self: *Recorder, callee_chunk: ChunkId, local_count: u16) !void {
        if (self.frames.items.len >= MAX_INLINE_DEPTH) return error.TraceAborted;
        const arg = try self.pop();
        const func = try self.pop();
        const snap = try self.snapshot();
        _ = try self.emit(.{ .op = .guard, .a = func, .aux = @intFromEnum(GuardKind.chunk_id), .aux2 = callee_chunk, .snapshot = snap });
        const locals = try self.allocator.alloc(?Ref, local_count);
        @memset(locals, null);
        if (local_count >= 1) locals[0] = arg;
        try self.frames.append(self.allocator, .{
            .locals = locals,
            .upvalue_src = func,
            .operand_base = @intCast(self.operand.items.len),
            .chunk_id = callee_chunk,
        });
    }

    /// Tail call: like `enterCall` but reuses the current frame (no depth
    /// change), matching the interpreter's frame reuse.
    pub fn replaceTail(self: *Recorder, callee_chunk: ChunkId, local_count: u16) !void {
        const arg = try self.pop();
        const func = try self.pop();
        const snap = try self.snapshot();
        _ = try self.emit(.{ .op = .guard, .a = func, .aux = @intFromEnum(GuardKind.chunk_id), .aux2 = callee_chunk, .snapshot = snap });
        const f = self.cur();
        // Tail position: no live operands should remain above this frame's base.
        self.operand.shrinkRetainingCapacity(f.operand_base);
        const locals = try self.allocator.alloc(?Ref, local_count);
        @memset(locals, null);
        if (local_count >= 1) locals[0] = arg;
        self.allocator.free(f.locals);
        f.locals = locals;
        f.upvalue_src = func;
        f.chunk_id = callee_chunk;
    }

    /// Specialize a conditional branch: pop the (forced bool) condition and
    /// guard it equals `taken` (the value observed at record time). At runtime
    /// a flipped branch side-exits; the recorder keeps following whichever path
    /// the interpreter actually took.
    pub fn guardBool(self: *Recorder, taken: bool) !void {
        if (self.operand.items.len == 0) return error.TraceAborted;
        const cond = self.operand.items[self.operand.items.len - 1];
        const snap = try self.snapshot();
        // jump_if_false PEEKS the condition (the VM leaves it on the stack for
        // a later explicit `pop`), so we must not pop it here either.
        _ = try self.emit(.{ .op = .guard, .a = cond, .aux = @intFromEnum(GuardKind.bool_is), .aux2 = @intFromBool(taken), .snapshot = snap });
    }

    /// Return from the current frame. At the anchor frame this finalizes the
    /// trace; in an inlined frame the result becomes the caller's call result.
    pub fn ret(self: *Recorder) !void {
        const result = try self.pop();
        if (self.frames.items.len == 1) {
            _ = try self.emit(.{ .op = .ret, .a = result });
            self.done = true;
            return;
        }
        const f = self.frames.pop().?;
        self.operand.shrinkRetainingCapacity(f.operand_base);
        self.allocator.free(f.locals);
        // A force-inlined thunk body publishes its value to the thunk before
        // the value flows on (sinking later removes both when the thunk doesn't
        // escape).
        if (f.resolve_thunk) |thunk_ref| {
            _ = try self.emit(.{ .op = .thunk_resolve, .a = thunk_ref, .b = result });
        }
        try self.push(result);
    }

    pub fn abort(self: *Recorder) void {
        self.aborted = true;
    }

    /// Request a truncated finish at this op boundary (the op is unsupported but
    /// the abstract state is clean). The driver turns this into a `side_exit`.
    pub fn requestTruncate(self: *Recorder) void {
        self.truncate_requested = true;
    }

    /// Finalize a truncated trace: snapshot the live operand stack + anchor
    /// locals at the current `ip`, emit `side_exit`, mark done. Only valid at
    /// anchor depth (one frame) — reconstructing inlined frames isn't supported.
    pub fn emitSideExit(self: *Recorder) !void {
        if (self.frames.items.len != 1) return error.TraceAborted;
        const f = &self.frames.items[0];
        var entries: std.ArrayListUnmanaged(ir.SnapshotEntry) = .empty;
        defer entries.deinit(self.allocator);
        for (self.operand.items, 0..) |ref, i| {
            try entries.append(self.allocator, .{ .ref = ref, .loc = .{ .stack = @intCast(i) } });
        }
        for (f.locals, 0..) |maybe, slot| {
            if (maybe) |ref| try entries.append(self.allocator, .{ .ref = ref, .loc = .{ .local = @intCast(slot) } });
        }
        const snap = try self.trace.addSnapshot(self.allocator, self.ip, entries.items);
        // Resume the frame's *current* chunk (a tail call may have replaced it)
        // with that chunk's own upvalues (anchor's own if no tail call happened).
        self.trace.snapshots.items[snap].resume_chunk = f.chunk_id;
        self.trace.snapshots.items[snap].upvalue_src = f.upvalue_src;
        _ = try self.emit(.{ .op = .side_exit, .snapshot = snap });
        self.done = true;
    }
};

test "recorder: inlined call makes the callee param the caller arg" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(7, true);
    defer trace.deinit(allocator);
    var rec = Recorder.init(allocator, &trace);
    defer rec.deinit();

    // anchor lambda: local0 = arg. Body: push local0 as func-ish... model a
    // call `f x` where f and x are upvalues, callee body returns its param.
    try rec.startRoot(7, 1, true);
    try rec.getUpvalue(0); // func
    try rec.getUpvalue(1); // arg
    try rec.enterCall(99, 1); // inline callee chunk 99 (1 local)
    // callee body: `local0` (its param) then ret
    try rec.getLocal(0);
    try rec.ret(); // returns from inlined frame
    try std.testing.expectEqual(@as(usize, 1), rec.inlineDepth()); // back at root
    // root ret of the call result
    try rec.ret();
    try std.testing.expect(rec.done and !rec.aborted);

    // The callee's param (local 0) resolved to the arg Ref (load_upvalue 1),
    // NOT a fresh load — that's the inlining win.
    const ops = trace.instrs.items;
    // trace_arg, load_upvalue(0)=func, load_upvalue(1)=arg, guard(chunk_id), ret
    try std.testing.expectEqual(Op.trace_arg, ops[0].op);
    try std.testing.expectEqual(Op.load_upvalue, ops[1].op);
    try std.testing.expectEqual(Op.load_upvalue, ops[2].op);
    try std.testing.expectEqual(Op.guard, ops[3].op);
    try std.testing.expectEqual(@as(Ref, 1), ops[3].a); // guards the func Ref (%1)
    try std.testing.expectEqual(Op.ret, ops[ops.len - 1].op);
    // The final ret returns the arg Ref (%2) — the callee just echoed its param.
    try std.testing.expectEqual(@as(Ref, 2), ops[ops.len - 1].a);
}

test "recorder: inlined upvalue reads the callee closure" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, true);
    defer trace.deinit(allocator);
    var rec = Recorder.init(allocator, &trace);
    defer rec.deinit();

    try rec.startRoot(7, 1, true);
    try rec.getUpvalue(0); // func  (%1 load_upvalue 0)
    try rec.getLocal(0); // arg = trace_arg (%0)
    try rec.enterCall(42, 1);
    try rec.getUpvalue(3); // upvalue 3 of the *callee* closure
    try rec.ret();
    try rec.ret();

    try std.testing.expect(rec.done and !rec.aborted);
    const ops = trace.instrs.items;
    // find the load_upvalue_of
    var found = false;
    for (ops) |o| {
        if (o.op == .load_upvalue_of) {
            found = true;
            try std.testing.expectEqual(@as(Ref, 1), o.a); // the func Ref
            try std.testing.expectEqual(@as(u32, 3), o.aux); // slot 3
        }
    }
    try std.testing.expect(found);
}

test "recorder: get_local on uninitialized slot aborts" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, false);
    defer trace.deinit(allocator);
    var rec = Recorder.init(allocator, &trace);
    defer rec.deinit();
    try rec.startRoot(1, 2, true); // local0 = arg, local1 = null
    try std.testing.expectError(error.TraceAborted, rec.getLocal(1));
}
