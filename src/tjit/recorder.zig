//! Trace recorder for the tracing JIT (`-Dtjit`).
//!
//! The recorder is *driven by the interpreter*: in record mode each opcode
//! handler calls the matching method here, passing decoded operands and (for
//! the guarded ops) the runtime value needed to choose a guard. The recorder
//! keeps an **abstract operand stack** mapping each live VM stack slot to the
//! IR `Ref` that produces it, and emits IR as it goes. This mirrors how
//! LuaJIT's recorder hangs off the bytecode interpreter — it avoids
//! re-decoding bytecode and naturally inlines through `call`/`force` (the
//! interpreter just keeps executing into the callee/thunk body and the
//! recorder keeps recording). See `docs/tracing-jit.md`.
//!
//! This module is the recording *core* — abstract-stack discipline, IR
//! emission, and deopt-snapshot capture. The interpreter integration (record
//! mode in the dispatch loop) and the guard-value decisions live at the call
//! sites; the core is unit-tested by driving the methods directly.

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

/// Bound on a single trace's length; over-long paths abort (they rarely
/// re-converge and blow out codegen / register pressure).
pub const MAX_TRACE_LEN: usize = 4096;

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    trace: *Trace,
    /// Abstract operand stack: slot i holds the IR Ref producing VM stack[i].
    /// Length tracks the VM's `sp` for the recorded region.
    stack: std.ArrayListUnmanaged(Ref) = .empty,
    /// Current bytecode position, for snapshot resume points. The driver
    /// updates this before each guarded op.
    ip: u32 = 0,
    aborted: bool = false,
    done: bool = false,

    pub fn init(allocator: std.mem.Allocator, trace: *Trace) Recorder {
        return .{ .allocator = allocator, .trace = trace };
    }

    pub fn deinit(self: *Recorder) void {
        self.stack.deinit(self.allocator);
    }

    pub fn setIp(self: *Recorder, ip: u32) void {
        self.ip = ip;
    }

    fn emit(self: *Recorder, instr: ir.Instr) !Ref {
        if (self.trace.len() >= MAX_TRACE_LEN) {
            self.aborted = true;
            return error.TraceAborted;
        }
        return self.trace.emit(self.allocator, instr);
    }

    fn push(self: *Recorder, ref: Ref) !void {
        try self.stack.append(self.allocator, ref);
    }

    fn pop(self: *Recorder) !Ref {
        if (self.stack.items.len == 0) {
            self.aborted = true;
            return error.TraceAborted;
        }
        return self.stack.pop().?;
    }

    fn peek(self: *Recorder) !Ref {
        if (self.stack.items.len == 0) {
            self.aborted = true;
            return error.TraceAborted;
        }
        return self.stack.items[self.stack.items.len - 1];
    }

    /// Capture the live abstract stack as a deopt snapshot at the current ip:
    /// each live Ref must be written back to its VM stack slot on side-exit.
    fn snapshot(self: *Recorder) !u32 {
        var entries = try self.allocator.alloc(ir.SnapshotEntry, self.stack.items.len);
        defer self.allocator.free(entries);
        for (self.stack.items, 0..) |ref, i| {
            entries[i] = .{ .ref = ref, .loc = .{ .stack = @intCast(i) } };
        }
        return self.trace.addSnapshot(self.allocator, self.ip, entries);
    }

    // ---- value-producing inputs ----

    pub fn pushConst(self: *Recorder, v: Value) !void {
        const cidx = try self.trace.addConst(self.allocator, v);
        try self.push(try self.emit(.{ .op = .const_val, .aux = cidx }));
    }

    pub fn pushLocal(self: *Recorder, slot: u16) !void {
        try self.push(try self.emit(.{ .op = .load_local, .aux = slot }));
    }

    pub fn pushUpvalue(self: *Recorder, slot: u16) !void {
        try self.push(try self.emit(.{ .op = .load_upvalue, .aux = slot }));
    }

    pub fn pushArg(self: *Recorder) !void {
        try self.push(try self.emit(.{ .op = .trace_arg }));
    }

    // ---- stack shuffles ----

    pub fn dropTop(self: *Recorder) !void {
        _ = try self.pop();
    }

    pub fn dup(self: *Recorder) !void {
        try self.push(try self.peek());
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

    /// Force the top-of-stack value. Emits a guard (driven by the runtime
    /// thunk state the interpreter observed) then the force; replaces the top
    /// with the forced value. For an already-resolved thunk the guard is
    /// `thunk_resolved` (load memo); for a single-use unresolved thunk the
    /// driver passes `thunk_claimed` (atomic-claim, body inlined as recording
    /// continues into it). A non-thunk needs no force — the driver skips this.
    pub fn forceTop(self: *Recorder, guard: GuardKind) !void {
        const v = try self.peek();
        const snap = try self.snapshot();
        _ = try self.emit(.{ .op = .guard, .a = v, .aux = @intFromEnum(guard), .snapshot = snap });
        const forced = try self.emit(.{ .op = .force, .a = v });
        self.stack.items[self.stack.items.len - 1] = forced;
    }

    /// `attrs.name`. Assumes `attrs` (top) is already forced. Guards the
    /// attrset shape so the resolved attr position stays valid, then reads it.
    pub fn getAttr(self: *Recorder, name: InternId) !void {
        // Snapshot before popping: a side-exit resumes at the get_attr op,
        // which still expects `attrs` on the operand stack.
        const attrs = try self.peek();
        const snap = try self.snapshot();
        _ = try self.pop();
        _ = try self.emit(.{ .op = .guard, .a = attrs, .aux = @intFromEnum(GuardKind.attr_shape), .aux2 = name, .snapshot = snap });
        try self.push(try self.emit(.{ .op = .get_attr, .a = attrs, .aux = name }));
    }

    /// Apply `func` (below `arg` on the stack) to `arg`. Guards that `func`
    /// resolves to the recorded chunk so the inlined body stays valid; the
    /// interpreter then executes into that body and the recorder keeps
    /// recording (inlining). The `call` IR node marks the boundary.
    pub fn call(self: *Recorder, callee_chunk: ChunkId) !void {
        // Snapshot before popping: a side-exit resumes at the call op, which
        // still expects [.., func, arg] on the operand stack.
        const snap = try self.snapshot();
        const arg = try self.pop();
        const func = try self.pop();
        _ = try self.emit(.{ .op = .guard, .a = func, .aux = @intFromEnum(GuardKind.chunk_id), .aux2 = callee_chunk, .snapshot = snap });
        try self.push(try self.emit(.{ .op = .call, .a = func, .b = arg, .aux = callee_chunk }));
    }

    /// Finalize: the trace result is the top of stack.
    pub fn ret(self: *Recorder) !void {
        const r = try self.pop();
        _ = try self.emit(.{ .op = .ret, .a = r });
        self.done = true;
    }

    pub fn abort(self: *Recorder) void {
        self.aborted = true;
    }
};

test "recorder: config.foo style force+attr access" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(7, true);
    defer trace.deinit(allocator);
    var rec = Recorder.init(allocator, &trace);
    defer rec.deinit();

    // upvalue `config`; force it (resolved); .foo; ret
    try rec.pushUpvalue(0);
    try rec.forceTop(.thunk_resolved);
    try rec.getAttr(42);
    try rec.ret();

    try std.testing.expect(!rec.aborted);
    try std.testing.expect(rec.done);
    // load_upvalue, guard, force, guard, get_attr, ret
    const ops = trace.instrs.items;
    try std.testing.expectEqual(@as(usize, 6), ops.len);
    try std.testing.expectEqual(Op.load_upvalue, ops[0].op);
    try std.testing.expectEqual(Op.guard, ops[1].op);
    try std.testing.expectEqual(Op.force, ops[2].op);
    try std.testing.expectEqual(Op.guard, ops[3].op);
    try std.testing.expectEqual(Op.get_attr, ops[4].op);
    try std.testing.expectEqual(Op.ret, ops[5].op);
    // get_attr reads the forced value (ref 2), not the raw upvalue (ref 0).
    try std.testing.expectEqual(@as(Ref, 2), ops[4].a);
    // the attr-shape guard snapshot has one live entry (the forced attrs).
    const snap = trace.snapshots.items[ops[3].snapshot];
    try std.testing.expectEqual(@as(usize, 1), snap.entries.len);
}

test "recorder: arithmetic stack discipline" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, false);
    defer trace.deinit(allocator);
    var rec = Recorder.init(allocator, &trace);
    defer rec.deinit();

    // (a + b) where a=local0, b=const 5 ; then ret
    try rec.pushLocal(0);
    try rec.pushConst(Value.int(5));
    try rec.binOp(.add_int);
    try rec.ret();

    try std.testing.expect(rec.done and !rec.aborted);
    const ops = trace.instrs.items;
    try std.testing.expectEqual(Op.add_int, ops[2].op);
    try std.testing.expectEqual(@as(Ref, 0), ops[2].a); // local
    try std.testing.expectEqual(@as(Ref, 1), ops[2].b); // const
    try std.testing.expectEqual(@as(usize, 0), rec.stack.items.len); // balanced
}

test "recorder: stack underflow aborts cleanly" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, false);
    defer trace.deinit(allocator);
    var rec = Recorder.init(allocator, &trace);
    defer rec.deinit();

    try std.testing.expectError(error.TraceAborted, rec.binOp(.add_int));
    try std.testing.expect(rec.aborted);
}
