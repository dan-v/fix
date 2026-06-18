//! Deforestation-headroom probe (gated behind `-Dstruct-census`, off by
//! default — zero cost in normal builds). The structural sibling of
//! `vm/trace_probe.zig` (which measures *thunk* single-use → the
//! `sink_ceiling`).
//!
//! The question this answers: a demand-aware / deforesting tracing
//! optimizer can fuse away an intermediate **list or attrset** only when
//! it is *single-use* — built by one producer and consumed by exactly one
//! operation, never read again. A structure read by *multiple* consumers
//! IS shared state (the module-system config graph); fusing it would
//! recompute. So the upper bound on deforestation headroom is the
//! single-use fraction of the structures we build — and, weighted by
//! allocation volume, how much of the heap churn that represents.
//!
//! We record, per list/attrset ObjectId: its kind, and how many times it
//! is *consumed* (getList / getAttrs / getAttrValueOpt entry). At eval end
//! we print a read-count histogram split by kind. Run at `--workers=1` so
//! the plain (non-atomic) counters don't race — w=1 is the serial-eval
//! shape, which is exactly the critical path we care about.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.struct_census;

// Sized to cover the NixOS toplevel object count (~19M); ids beyond this
// are folded into overflow counters (counted, not indexed).
const CAP: usize = 32 * 1024 * 1024;

pub const Kind = enum(u8) { none = 0, list = 1, attrs = 2 };

const State = struct {
    /// Per-object kind, indexed by ObjectId. `none` = not a tracked
    /// structure (or unallocated slot).
    kinds: []u8 = &.{},
    /// Saturating per-object consume count, indexed by ObjectId.
    reads: []u8 = &.{},
    overflow_allocs: u64 = 0,
    overflow_reads: u64 = 0,
};

var state: State = .{};

pub fn init(allocator: std.mem.Allocator) void {
    if (comptime !enabled) return;
    state.kinds = allocator.alloc(u8, CAP) catch &.{};
    state.reads = allocator.alloc(u8, CAP) catch &.{};
    @memset(state.kinds, 0);
    @memset(state.reads, 0);
}

/// Record allocation of a list/attrset (called from `ObjectHeap.add`).
pub inline fn recordAlloc(id: u32, kind: Kind) void {
    if (comptime !enabled) return;
    const i: usize = id;
    if (i >= state.kinds.len) {
        state.overflow_allocs += 1;
        return;
    }
    state.kinds[i] = @intFromEnum(kind);
}

/// Record one consume of structure `id` (getList / getAttrs / lookup).
pub inline fn recordRead(id: u32) void {
    if (comptime !enabled) return;
    const i: usize = id;
    if (i >= state.reads.len) {
        state.overflow_reads += 1;
        return;
    }
    if (state.reads[i] != 255) state.reads[i] += 1;
}

const Hist = struct {
    allocated: u64 = 0,
    read0: u64 = 0,
    read1: u64 = 0,
    read2: u64 = 0,
    read3_4: u64 = 0,
    read5_8: u64 = 0,
    read9: u64 = 0,
    reads_total: u64 = 0,

    fn add(self: *Hist, r: u8) void {
        self.allocated += 1;
        self.reads_total += r;
        switch (r) {
            0 => self.read0 += 1,
            1 => self.read1 += 1,
            2 => self.read2 += 1,
            3, 4 => self.read3_4 += 1,
            5...8 => self.read5_8 += 1,
            else => self.read9 += 1,
        }
    }
};

fn pct(n: u64, d: u64) f64 {
    if (d == 0) return 0;
    return @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(d));
}

fn printKind(name: []const u8, h: Hist) void {
    std.debug.print("--- {s} ---\n", .{name});
    std.debug.print("  allocated:        {d}\n", .{h.allocated});
    std.debug.print("  total consumes:   {d}\n", .{h.reads_total});
    std.debug.print("  consume-count histogram (of allocated):\n", .{});
    std.debug.print("    0x  (built, never read): {d} ({d:.1}%)\n", .{ h.read0, pct(h.read0, h.allocated) });
    std.debug.print("    1x  (SINGLE-USE / fusable): {d} ({d:.1}%)\n", .{ h.read1, pct(h.read1, h.allocated) });
    std.debug.print("    2x  (shared):            {d} ({d:.1}%)\n", .{ h.read2, pct(h.read2, h.allocated) });
    std.debug.print("    3-4x:                    {d} ({d:.1}%)\n", .{ h.read3_4, pct(h.read3_4, h.allocated) });
    std.debug.print("    5-8x:                    {d} ({d:.1}%)\n", .{ h.read5_8, pct(h.read5_8, h.allocated) });
    std.debug.print("    9+x:                     {d} ({d:.1}%)\n", .{ h.read9, pct(h.read9, h.allocated) });
    const single = h.read0 + h.read1;
    std.debug.print("  => single-use (<=1 consume): {d} of {d} ({d:.1}% of structures, {d:.1}% of consumes are to single-use)\n", .{
        single, h.allocated, pct(single, h.allocated), pct(h.read1, h.reads_total),
    });
}

pub fn report() void {
    if (comptime !enabled) return;
    var lists: Hist = .{};
    var attrs: Hist = .{};
    for (state.kinds, state.reads) |k, r| {
        switch (@as(Kind, @enumFromInt(k))) {
            .none => {},
            .list => lists.add(r),
            .attrs => attrs.add(r),
        }
    }
    std.debug.print("\n=== deforestation-headroom probe (list/attrset reuse) ===\n", .{});
    std.debug.print("overflow: allocs={d} reads={d} (ids beyond CAP, not bucketed)\n", .{ state.overflow_allocs, state.overflow_reads });
    printKind("lists", lists);
    printKind("attrsets", attrs);
    std.debug.print("note: run at --workers=1 for an unraced single-thread (serial-eval) picture.\n", .{});
}
