//! Tracing-JIT headroom probe (gated behind `-Dtrace-probe`, off by
//! default — zero cost in normal builds).
//!
//! The question this answers: a tracing/inlining JIT can only eliminate
//! the allocation + claim + force machinery of thunks that are
//! **single-use** — created and forced by exactly one consumer within a
//! trace. A thunk read by *multiple* consumers IS the sharing mechanism
//! (memoizes a value reused across the graph); inlining it would
//! recompute, changing semantics/cost. So the upper bound on tracing-JIT
//! headroom is the single-use fraction of forced thunks.
//!
//! We record, per thunk ObjectId, how many times it is *read*
//! (`forceValueImpl` entry), and the body sizes of computed bytecode
//! thunks. At eval end we print a read-count histogram (1× = single-use /
//! inlinable, 2+× = shared) and the body-size distribution (chain
//! granularity). Run at `--workers=1` so the plain (non-atomic) counters
//! don't race.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.trace_probe;

// Sized to comfortably cover the NixOS toplevel object count (~6-15M);
// ids beyond this are folded into the last slot (counted, not indexed)
// so the histogram stays sound.
const CAP: usize = 64 * 1024 * 1024;

const State = struct {
    /// Saturating per-thunk read count, indexed by ObjectId.
    reads: []u8 = &.{},
    /// Reads of thunks whose id exceeded CAP (rare; kept out of the
    /// per-id array but still counted toward total reads).
    overflow_reads: u64 = 0,
    /// Body-size histogram of computed bytecode thunks (code bytes).
    body_buckets: [8]u64 = @splat(0),
    body_total: u64 = 0,
    body_bytes: u64 = 0,
};

var state: State = .{};

pub fn init(allocator: std.mem.Allocator) void {
    if (comptime !enabled) return;
    state.reads = allocator.alloc(u8, CAP) catch &.{};
    @memset(state.reads, 0);
}

/// Record one read of `thunk_id` (called from `forceValueImpl`).
pub inline fn recordRead(thunk_id: u32) void {
    if (comptime !enabled) return;
    const i: usize = thunk_id;
    if (i >= state.reads.len) {
        state.overflow_reads += 1;
        return;
    }
    if (state.reads[i] != 255) state.reads[i] += 1;
}

/// Record the body size (code bytes) of a freshly-computed bytecode thunk.
pub inline fn recordComputeBody(code_len: usize) void {
    if (comptime !enabled) return;
    state.body_total += 1;
    state.body_bytes += code_len;
    const b: usize = switch (code_len) {
        0...8 => 0,
        9...16 => 1,
        17...32 => 2,
        33...64 => 3,
        65...128 => 4,
        129...256 => 5,
        257...1024 => 6,
        else => 7,
    };
    state.body_buckets[b] += 1;
}

pub fn report() void {
    if (comptime !enabled) return;
    // Read-count histogram across all thunk slots.
    var c1: u64 = 0; // single-use (inlinable)
    var c2: u64 = 0;
    var c3_4: u64 = 0;
    var c5_8: u64 = 0;
    var c9: u64 = 0;
    var reads_total: u64 = state.overflow_reads;
    var thunks_read: u64 = 0;
    for (state.reads) |r| {
        if (r == 0) continue;
        thunks_read += 1;
        reads_total += r;
        switch (r) {
            1 => c1 += 1,
            2 => c2 += 1,
            3, 4 => c3_4 += 1,
            5, 6, 7, 8 => c5_8 += 1,
            else => c9 += 1,
        }
    }
    const pct = struct {
        fn f(n: u64, d: u64) f64 {
            if (d == 0) return 0;
            return @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(d));
        }
    }.f;

    std.debug.print("\n=== tracing-JIT headroom probe ===\n", .{});
    std.debug.print("thunks read at least once: {d}\n", .{thunks_read});
    std.debug.print("total thunk reads:         {d} (overflow {d})\n", .{ reads_total, state.overflow_reads });
    std.debug.print("read-count histogram (of read thunks):\n", .{});
    std.debug.print("  1x  (single-use / INLINABLE): {d} ({d:.1}%)\n", .{ c1, pct(c1, thunks_read) });
    std.debug.print("  2x  (shared):                 {d} ({d:.1}%)\n", .{ c2, pct(c2, thunks_read) });
    std.debug.print("  3-4x:                         {d} ({d:.1}%)\n", .{ c3_4, pct(c3_4, thunks_read) });
    std.debug.print("  5-8x:                         {d} ({d:.1}%)\n", .{ c5_8, pct(c5_8, thunks_read) });
    std.debug.print("  9+x:                          {d} ({d:.1}%)\n", .{ c9, pct(c9, thunks_read) });
    std.debug.print("=> single-use share of total reads: {d:.1}% (alloc+claim+force machinery a trace could elide)\n", .{pct(c1, reads_total)});

    std.debug.print("computed bytecode thunks:  {d}, total body {d} B, avg {d:.1} B\n", .{
        state.body_total,
        state.body_bytes,
        if (state.body_total == 0) 0 else @as(f64, @floatFromInt(state.body_bytes)) / @as(f64, @floatFromInt(state.body_total)),
    });
    const labels = [_][]const u8{ "<=8", "9-16", "17-32", "33-64", "65-128", "129-256", "257-1024", "1025+" };
    std.debug.print("body-size histogram (bytes):\n", .{});
    for (labels, state.body_buckets) |label, n| {
        std.debug.print("  {s:<9}: {d} ({d:.1}%)\n", .{ label, n, pct(n, state.body_total) });
    }
}
