//! Trace IR for the tracing/inlining JIT (`-Dtjit`).
//!
//! A `Trace` is a linear SSA sequence recorded from one hot execution path,
//! inlined through `force` and `call` boundaries. The recorder appends
//! `Instr`s; the optimizer rewrites them (guard/force CSE, allocation
//! sinking, DCE); the backend lowers them to native code with side-exit
//! stubs. See `docs/tracing-jit.md` for the full design and the laziness /
//! parallelism rationale.
//!
//! This file is types + construction only — no recording, optimization, or
//! codegen logic (those are separate modules so each stays testable). It
//! compiles in every build; the `-Dtjit` gate lives at the call sites.

const std = @import("std");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;

const InternId = types.InternId;
const ChunkId = types.ChunkId;

/// SSA value: an index into `Trace.instrs`. Instruction N defines value N.
pub const Ref = u32;

pub const Op = enum(u8) {
    // ---- inputs (trace entry values) ----
    /// Constant from `Trace.consts[aux]`.
    const_val,
    /// Upvalue slot `aux` of the anchor closure.
    load_upvalue,
    /// Upvalue slot `aux` of an *inlined* closure `a` (its func Ref). Distinct
    /// from `load_upvalue` because each closure instance of a chunk has its
    /// own upvalues; an inlined callee reads the specific closure it was
    /// called on, captured in the trace.
    load_upvalue_of,
    /// Frame local slot `aux`, live at trace entry.
    load_local,
    /// The argument supplied at the anchor (lambda traces).
    trace_arg,

    // ---- guarded effects (may inline a callee/thunk body region) ----
    /// `force(a)`. Resolves a thunk. The recorder splits the common cases via
    /// a preceding `guard` (resolved → load memo; single-use unresolved →
    /// claim + inline body). See docs.
    force,
    /// `get_attr(a=attrs, aux=InternId)`. Guarded by attrset shape / IC.
    get_attr,
    /// `call(a=func, b=arg)`. Guarded by callee chunk-id; body inlined.
    call,
    /// Atomically claim thunk `a` for evaluation (CAS unresolved→evaluating,
    /// the interpreter's exact protocol). Deopt if it isn't ours to claim
    /// (already resolved / busy / errored) — the interpreter then waits or
    /// loads the memo. Precedes an inlined thunk body.
    thunk_claim,
    /// Publish value `b` as thunk `a`'s result (resolve + wake waiters + mark
    /// demanded), matching `forceThunkImpl`. Closes an inlined thunk body.
    thunk_resolve,

    // ---- pure ----
    add_int,
    sub_int,
    mul_int,
    eq,
    lt,
    not,

    // ---- allocation (sink candidates) ----
    /// Build a bytecode thunk: `aux` = chunk id, `a` = start index into
    /// `Trace.extra`, `b` = capture count. The capture value Refs live in
    /// `extra[a .. a+b]` (a thunk can capture any number of upvalues, more than
    /// the two Instr operand slots hold). `a`/`b` are NOT Refs (see usesA/usesB).
    alloc_thunk,
    alloc_attrs,
    alloc_list,

    // ---- control ----
    /// Side-exit to the interpreter if the guard fails. `aux` is a
    /// `GuardKind`; `snapshot` indexes `Trace.snapshots` for deopt state.
    guard,
    /// Trace result is value `a`.
    ret,
    /// Truncation point: the trace stops here and hands control back to the
    /// interpreter mid-chunk. `snapshot` carries the operand-stack + live-local
    /// Refs and the bytecode `ip` to resume at; the executor reconstructs the
    /// anchor frame from it, then interprets to the chunk's real `ret`. Lets a
    /// trace keep its handled prefix instead of aborting at the first
    /// unsupported op. Only emitted at anchor depth (no inlined frames live).
    side_exit,
    /// Deleted instruction (left in place by optimizer passes so SSA `Ref`s —
    /// which are array indices — don't need renumbering). Skipped by codegen.
    nop,
};

/// True for ops with no observable effect: removable by DCE when their result
/// is unused, and foldable. Effectful/control ops (guard, ret, get_attr,
/// force, call, allocations) are conservatively kept.
pub fn isPure(op: Op) bool {
    return switch (op) {
        .const_val, .load_upvalue, .load_upvalue_of, .load_local, .trace_arg, .add_int, .sub_int, .mul_int, .eq, .lt, .not => true,
        else => false,
    };
}

/// Whether operand field `a` / `b` of an instruction is an SSA `Ref` (vs an
/// immediate like a const index or slot). Used by passes to walk the dataflow.
pub fn usesA(op: Op) bool {
    return switch (op) {
        .load_upvalue_of, .add_int, .sub_int, .mul_int, .eq, .lt, .not, .guard, .get_attr, .force, .call, .ret, .thunk_claim, .thunk_resolve => true,
        else => false,
    };
}

pub fn usesB(op: Op) bool {
    return switch (op) {
        .add_int, .sub_int, .mul_int, .eq, .lt, .call, .thunk_resolve => true,
        else => false,
    };
}

pub const GuardKind = enum(u8) {
    /// Thunk `a` is already resolved (acquire load of future.state).
    thunk_resolved,
    /// Thunk `a` is unresolved and we atomically claimed it; fail → wait path.
    thunk_claimed,
    /// `a.kind() == aux2` (the expected Value kind).
    value_kind,
    /// Attrset `a` has the recorded shape (so attr indices are valid).
    attr_shape,
    /// Callee `a` is the recorded chunk id (so the inlined body is valid).
    chunk_id,
    /// Boolean `a` equals the recorded branch condition (`aux2`: 1=true,
    /// 0=false). Lets a trace specialize one side of a conditional and
    /// side-exit if the branch flips. `a` is an already-forced bool.
    bool_is,
};

pub const NO_SNAPSHOT: u32 = std.math.maxInt(u32);

pub const Instr = struct {
    op: Op,
    a: Ref = 0,
    b: Ref = 0,
    /// Inline payload: const index / slot / InternId / chunk id / GuardKind.
    aux: u32 = 0,
    /// Secondary payload (e.g. expected kind for a `value_kind` guard).
    aux2: u32 = 0,
    /// For `guard`: index into `Trace.snapshots`. `NO_SNAPSHOT` otherwise.
    snapshot: u32 = NO_SNAPSHOT,
};

/// Where a live SSA value must be written when a guard side-exits, so the
/// interpreter resumes with a consistent stack/frame.
pub const Loc = union(enum) {
    /// Operand-stack slot (absolute index within the resuming frame).
    stack: u16,
    /// Frame local slot.
    local: u16,
};

pub const SnapshotEntry = struct { ref: Ref, loc: Loc };

/// One reconstructed VM frame at a side-exit. Frames are ordered anchor →
/// deepest; mid-inline truncation reconstructs the whole inlined CALL stack so
/// the interpreter unwinds naturally. `chunk` is the frame's current chunk (a
/// tail call may have replaced the anchor's). `upvalue_src` is the Ref of the
/// closure whose upvalues this frame runs with (null = the anchor's own).
/// `resume_ip` is where this frame continues — the call-return ip for a frame
/// whose callee is deeper, or the unhandled-op ip for the deepest frame.
pub const SnapshotFrame = struct {
    chunk: ChunkId,
    upvalue_src: ?Ref,
    resume_ip: u32,
    /// `loc = .local` entries (slot, ref).
    local_entries: []const SnapshotEntry,
    /// `loc = .stack` entries (slot = position), in operand-stack order.
    operand_entries: []const SnapshotEntry,
};

/// The full interpreter state to reconstruct at a side-exit.
pub const Snapshot = struct {
    frames: []SnapshotFrame,
};

pub const Trace = struct {
    /// Chunk the trace is anchored at (its hot entry).
    anchor_chunk: ChunkId,
    /// True if the anchor is a lambda body (has `trace_arg`); false for a
    /// thunk body.
    is_lambda: bool,
    instrs: std.ArrayListUnmanaged(Instr) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    snapshots: std.ArrayListUnmanaged(Snapshot) = .empty,
    /// Side array of Refs for ops with a variable operand count (`alloc_thunk`
    /// captures, …) that don't fit the two Instr slots. Indexed by `[a .. a+b]`.
    extra: std.ArrayListUnmanaged(Ref) = .empty,

    pub fn init(anchor_chunk: ChunkId, is_lambda: bool) Trace {
        return .{ .anchor_chunk = anchor_chunk, .is_lambda = is_lambda };
    }

    pub fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        self.instrs.deinit(allocator);
        self.consts.deinit(allocator);
        for (self.snapshots.items) |snap| {
            for (snap.frames) |f| {
                allocator.free(f.local_entries);
                allocator.free(f.operand_entries);
            }
            allocator.free(snap.frames);
        }
        self.snapshots.deinit(allocator);
        self.extra.deinit(allocator);
    }

    /// Append `refs` to the side array, returning the start index.
    pub fn addExtra(self: *Trace, allocator: std.mem.Allocator, refs: []const Ref) !u32 {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(allocator, refs);
        return start;
    }

    /// Append an instruction, returning its SSA `Ref`.
    pub fn emit(self: *Trace, allocator: std.mem.Allocator, instr: Instr) !Ref {
        const ref: Ref = @intCast(self.instrs.items.len);
        try self.instrs.append(allocator, instr);
        return ref;
    }

    /// Intern a constant into the trace's pool, returning its index.
    pub fn addConst(self: *Trace, allocator: std.mem.Allocator, v: Value) !u32 {
        const idx: u32 = @intCast(self.consts.items.len);
        try self.consts.append(allocator, v);
        return idx;
    }

    /// Append a side-exit snapshot, deep-copying `frames` (and each frame's
    /// entry slices) into trace-owned memory.
    pub fn addSnapshot(self: *Trace, allocator: std.mem.Allocator, frames: []const SnapshotFrame) !u32 {
        const idx: u32 = @intCast(self.snapshots.items.len);
        const owned = try allocator.alloc(SnapshotFrame, frames.len);
        for (frames, 0..) |f, i| {
            owned[i] = .{
                .chunk = f.chunk,
                .upvalue_src = f.upvalue_src,
                .resume_ip = f.resume_ip,
                .local_entries = try allocator.dupe(SnapshotEntry, f.local_entries),
                .operand_entries = try allocator.dupe(SnapshotEntry, f.operand_entries),
            };
        }
        try self.snapshots.append(allocator, .{ .frames = owned });
        return idx;
    }

    pub fn len(self: *const Trace) usize {
        return self.instrs.items.len;
    }
};

test "trace IR: build a small inlined force chain" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(7, true);
    defer trace.deinit(allocator);

    // arg; force(arg); get_attr(forced, "foo"); side_exit (1-frame snapshot)
    const arg = try trace.emit(allocator, .{ .op = .trace_arg });
    const forced = try trace.emit(allocator, .{ .op = .force, .a = arg });
    const attr = try trace.emit(allocator, .{ .op = .get_attr, .a = forced, .aux = 42 });
    const snap = try trace.addSnapshot(allocator, &.{.{
        .chunk = 7,
        .upvalue_src = null,
        .resume_ip = 3,
        .local_entries = &.{},
        .operand_entries = &.{.{ .ref = attr, .loc = .{ .stack = 0 } }},
    }});
    _ = try trace.emit(allocator, .{ .op = .side_exit, .snapshot = snap });

    try std.testing.expectEqual(@as(usize, 4), trace.len());
    try std.testing.expectEqual(Op.side_exit, trace.instrs.items[trace.len() - 1].op);
    try std.testing.expectEqual(@as(usize, 1), trace.snapshots.items.len);
    try std.testing.expectEqual(@as(u32, 3), trace.snapshots.items[0].frames[0].resume_ip);
}
