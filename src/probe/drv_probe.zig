//! Derivation-build demand probe (gated behind `-Ddrv-probe`, off by
//! default — zero cost in normal builds).
//!
//! Answers the "is the serial chain's drv frontier already resolved when
//! main reaches it, or does main force it inline?" question that gates
//! deep consumer strict-demand fanout (P1, docs/plans/parallel-redesign-plan.md).
//!
//! Two independent measurements:
//!
//!   1. ATTR DEMAND (run at --workers=32). For each attr value the
//!      `normalizeDerivation` sequential walk is about to force, peek its
//!      thunk state *before* forcing and bucket it:
//!        - immediate   — not a thunk; no work to race.
//!        - ahead       — `.resolved` already: fanout/spec/a helper got
//!                        there first. This is the win we want maximised.
//!        - in_flight   — `.evaluating`: a helper is on it; main will park
//!                        (parallel, but pays wake/resume latency).
//!        - inline      — `.unresolved`: main claims and runs it itself.
//!                        Pure serial work on the critical path — the
//!                        headroom deep fanout would convert to `ahead`.
//!      Plus the one-level fanout submit loop's ok/rej tally.
//!      High `inline%` ⇒ build deep fanout. High `ahead%` ⇒ frontier is
//!      already resolved ahead; pivot to the cross-worker memo instead.
//!
//!   2. SERIAL DAG SHAPE (run at --workers=1). At w=1 a drv build is a DFS
//!      over the input-drv DAG: forcing an attr string coerces an input
//!      derivation, which recursively builds it. So the entry/exit nesting
//!      depth of `buildForcedDerivationValue` IS the DAG depth, and the
//!      per-build `input_drvs.len` is its fan-in. Depth is only meaningful
//!      at w=1 (at w=32 concurrent builds across workers inflate it).

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.drv_probe;

const Counters = struct {
    builds: std.atomic.Value(u64) = .init(0),

    attr_immediate: std.atomic.Value(u64) = .init(0),
    attr_ahead: std.atomic.Value(u64) = .init(0),
    attr_in_flight: std.atomic.Value(u64) = .init(0),
    attr_inline: std.atomic.Value(u64) = .init(0),

    fanout_ok: std.atomic.Value(u64) = .init(0),
    fanout_rej: std.atomic.Value(u64) = .init(0),

    // Serial DFS depth (w=1 only). `depth_cur` is bumped on build entry /
    // dropped on exit; `depth_max` is the high-water. Histogram buckets
    // the depth reached at each build entry.
    depth_cur: std.atomic.Value(i64) = .init(0),
    depth_max: std.atomic.Value(i64) = .init(0),

    // Per-build input-drv fan-in.
    fanin_sum: std.atomic.Value(u64) = .init(0),
};

var c: Counters = .{};

// Depth histogram and fan-in histogram. Plain arrays bumped under the
// monotonic counters; at w>1 these race but depth is documented w=1-only.
const DEPTH_BUCKETS = 8; // 1, 2, 3-4, 5-8, 9-16, 17-32, 33-64, 65+
var depth_hist: [DEPTH_BUCKETS]std.atomic.Value(u64) = blk: {
    var a: [DEPTH_BUCKETS]std.atomic.Value(u64) = undefined;
    for (&a) |*x| x.* = .init(0);
    break :blk a;
};
const FANIN_BUCKETS = 7; // 0, 1, 2, 3-4, 5-8, 9-16, 17+
var fanin_hist: [FANIN_BUCKETS]std.atomic.Value(u64) = blk: {
    var a: [FANIN_BUCKETS]std.atomic.Value(u64) = undefined;
    for (&a) |*x| x.* = .init(0);
    break :blk a;
};

/// Thunk state at the moment main is about to force an attr value.
pub const AttrState = enum { immediate, ahead, in_flight, inline_forced };

pub inline fn recordAttr(s: AttrState) void {
    if (comptime !enabled) return;
    switch (s) {
        .immediate => _ = c.attr_immediate.fetchAdd(1, .monotonic),
        .ahead => _ = c.attr_ahead.fetchAdd(1, .monotonic),
        .in_flight => _ = c.attr_in_flight.fetchAdd(1, .monotonic),
        .inline_forced => _ = c.attr_inline.fetchAdd(1, .monotonic),
    }
}

pub inline fn recordFanout(ok: bool) void {
    if (comptime !enabled) return;
    if (ok) {
        _ = c.fanout_ok.fetchAdd(1, .monotonic);
    } else {
        _ = c.fanout_rej.fetchAdd(1, .monotonic);
    }
}

/// Call on `buildForcedDerivationValue` entry. Returns the depth this
/// build is at (1-based) so the caller can pair it with `buildExit`.
pub inline fn buildEnter() void {
    if (comptime !enabled) return;
    _ = c.builds.fetchAdd(1, .monotonic);
    const d = c.depth_cur.fetchAdd(1, .monotonic) + 1; // depth at this entry
    // Bump high-water.
    var prev = c.depth_max.load(.monotonic);
    while (d > prev) {
        prev = c.depth_max.cmpxchgWeak(prev, d, .monotonic, .monotonic) orelse break;
    }
    bump(&depth_hist, depthBucket(d));
}

pub inline fn buildExit() void {
    if (comptime !enabled) return;
    _ = c.depth_cur.fetchSub(1, .monotonic);
}

/// Call once per build with the number of distinct input derivations.
pub inline fn recordFanin(n: usize) void {
    if (comptime !enabled) return;
    _ = c.fanin_sum.fetchAdd(n, .monotonic);
    bump(&fanin_hist, faninBucket(n));
}

inline fn bump(hist: []std.atomic.Value(u64), i: usize) void {
    _ = hist[i].fetchAdd(1, .monotonic);
}

fn depthBucket(d: i64) usize {
    return switch (d) {
        0, 1 => 0,
        2 => 1,
        3, 4 => 2,
        5...8 => 3,
        9...16 => 4,
        17...32 => 5,
        33...64 => 6,
        else => 7,
    };
}

fn faninBucket(n: usize) usize {
    return switch (n) {
        0 => 0,
        1 => 1,
        2 => 2,
        3, 4 => 3,
        5...8 => 4,
        9...16 => 5,
        else => 6,
    };
}

fn pct(n: u64, d: u64) f64 {
    if (d == 0) return 0;
    return @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(d));
}

pub fn report() void {
    if (comptime !enabled) return;
    const builds = c.builds.load(.monotonic);
    if (builds == 0) {
        std.debug.print("\n=== drv-probe: no derivation builds recorded ===\n", .{});
        return;
    }

    const imm = c.attr_immediate.load(.monotonic);
    const ahead = c.attr_ahead.load(.monotonic);
    const inflight = c.attr_in_flight.load(.monotonic);
    const inl = c.attr_inline.load(.monotonic);
    const attrs_total = imm + ahead + inflight + inl;
    // Thunked attrs are the ones that could have been resolved ahead;
    // immediates carry no parallelism signal.
    const thunked = ahead + inflight + inl;

    std.debug.print("\n=== drv-probe: derivation-build demand ===\n", .{});
    std.debug.print("derivations built (cache-miss): {d}\n", .{builds});

    std.debug.print("\nattr-walk demand (per attr forced in normalizeDerivation):\n", .{});
    std.debug.print("  total attrs walked: {d}  ({d} thunked, {d} immediate)\n", .{ attrs_total, thunked, imm });
    std.debug.print("  of THUNKED attrs (the parallelism-relevant set):\n", .{});
    std.debug.print("    ahead     (resolved before main arrived): {d:>9} ({d:.1}%)\n", .{ ahead, pct(ahead, thunked) });
    std.debug.print("    in_flight (helper running, main parks):    {d:>9} ({d:.1}%)\n", .{ inflight, pct(inflight, thunked) });
    std.debug.print("    inline    (main claims + runs it):         {d:>9} ({d:.1}%)\n", .{ inl, pct(inl, thunked) });
    std.debug.print("  => resolved-ahead-or-in-flight (parallel): {d:.1}%   inline-serial: {d:.1}%\n", .{
        pct(ahead + inflight, thunked), pct(inl, thunked),
    });

    const fok = c.fanout_ok.load(.monotonic);
    const frej = c.fanout_rej.load(.monotonic);
    std.debug.print("\none-level fanout submit (normalizeDerivation pre-walk): ok={d} rej={d} ({d:.1}% rejected)\n", .{
        fok, frej, pct(frej, fok + frej),
    });

    const fanin_sum = c.fanin_sum.load(.monotonic);
    std.debug.print("\ninput-drv fan-in: total={d}  avg={d:.1} per build\n", .{ fanin_sum, @as(f64, @floatFromInt(fanin_sum)) / @as(f64, @floatFromInt(builds)) });
    printHist("fan-in", fanin_hist[0..], &[_][]const u8{ "0", "1", "2", "3-4", "5-8", "9-16", "17+" });

    std.debug.print("\nserial input-DAG depth (buildForcedDerivationValue nesting):\n", .{});
    std.debug.print("  max depth: {d}   << ONLY meaningful at --workers=1 (DFS spine = DAG depth)\n", .{c.depth_max.load(.monotonic)});
    printHist("depth", depth_hist[0..], &[_][]const u8{ "1", "2", "3-4", "5-8", "9-16", "17-32", "33-64", "65+" });

    std.debug.print("\nread: high inline%% ⇒ deep consumer fanout has headroom; high ahead%% ⇒ frontier already resolved ahead (pivot to cross-worker memo).\n", .{});
    std.debug.print("run BOTH: --workers=32 for the demand split, --workers=1 for the true DAG depth.\n", .{});
}

fn printHist(name: []const u8, hist: []const std.atomic.Value(u64), labels: []const []const u8) void {
    var total: u64 = 0;
    for (hist) |*h| total += h.load(.monotonic);
    std.debug.print("  {s} histogram ({d} samples):", .{ name, total });
    for (hist, labels) |*h, label| {
        const n = h.load(.monotonic);
        if (n == 0) continue;
        std.debug.print("  {s}={d} ({d:.0}%)", .{ label, n, pct(n, total) });
    }
    std.debug.print("\n", .{});
}
