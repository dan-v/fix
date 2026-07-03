//! Depth-0 safepoint frequency probe (`-Ddepth0-probe`, off by default —
//! zero cost in normal builds). Answers the one measurement the concurrent-
//! SATB design hinges on.
//!
//! A concurrent SATB collector can only take its root SNAPSHOT (and reach
//! mark termination) at a *clean* safepoint — `native_depth == 0` at a
//! `forceThunk` boundary, where the root set is provably the operand
//! stack/frames and no builtin holds un-enumerable Zig-local heap refs. If
//! those points are frequent and well-spread through the module fixpoint,
//! snapshot-at-depth-0 bounds RSS with NO mutator rooting tax. If they
//! cluster at output (nixpkgs eval is heavy on `mapAttrs`/`foldl'`, which sit
//! at `native_depth > 0`), then the allocation between two snapshottable
//! points — the RSS "float" — can be most of the heap, and depth-0-only
//! snapshots can't bound RSS.
//!
//! At every `forceThunkImpl` entry we record the per-thread `native_depth`
//! and the monotonic total-reserved bytes, and tally:
//!   - the native_depth histogram (how deep builtin nesting goes),
//!   - depth-0 vs depth>0 safepoint counts,
//!   - the allocation-GAP distribution between consecutive depth-0 points
//!     plus the MAX gap — the worst-case RSS float,
//!   - a 64 MB-banded timeline of depth-0 vs depth>0 points — to see whether
//!     the fixpoint's big allocation phase is a depth-0 desert.
//!
//! Run at `--workers=1` and WITHOUT `-Dgc` so allocation grows monotonically
//! (no reclaim rewinds the byte counts) and the plain global counters don't
//! race. `native_depth` is maintained under this flag too (see access.zig /
//! eval.zig), so no `-Dgc` is needed.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const enabled: bool = build_options.depth0_probe;

const DEPTH_BUCKETS: usize = 8; // 0,1,2,3,4,5,6,7+
const GAP_BUCKETS: usize = 9; // <64K,256K,1M,4M,16M,64M,256M,1G,>=1G
const BAND_BYTES: u64 = 64 << 20; // 64 MB timeline resolution
const NUM_BANDS: usize = 64; // up to 4 GB of monotonic allocation

var total: u64 = 0;
var depth0: u64 = 0;
var depth_nonzero: u64 = 0;
var depth_hist: [DEPTH_BUCKETS]u64 = [_]u64{0} ** DEPTH_BUCKETS;
var gap_hist: [GAP_BUCKETS]u64 = [_]u64{0} ** GAP_BUCKETS;
var max_gap: u64 = 0;
var last_d0_bytes: u64 = 0;
var have_last: bool = false;
var band_d0: [NUM_BANDS]u64 = [_]u64{0} ** NUM_BANDS;
var band_nz: [NUM_BANDS]u64 = [_]u64{0} ** NUM_BANDS;
var final_bytes: u64 = 0;

/// Called at every `forceThunkImpl` entry (a collector safepoint). `depth`
/// is the per-thread `native_depth`; `reserved_bytes` is the monotonic
/// total-reserved-bytes allocation cursor.
pub inline fn onForceThunk(depth: u32, reserved_bytes: u64) void {
    if (comptime !enabled) return;
    total += 1;
    depth_hist[@min(@as(usize, depth), DEPTH_BUCKETS - 1)] += 1;
    const band = @min(reserved_bytes / BAND_BYTES, NUM_BANDS - 1);
    if (depth == 0) {
        depth0 += 1;
        band_d0[@intCast(band)] += 1;
        if (have_last) {
            const gap = reserved_bytes - last_d0_bytes;
            if (gap > max_gap) max_gap = gap;
            gap_hist[gapBucket(gap)] += 1;
        }
        last_d0_bytes = reserved_bytes;
        have_last = true;
    } else {
        depth_nonzero += 1;
        band_nz[@intCast(band)] += 1;
    }
    if (reserved_bytes > final_bytes) final_bytes = reserved_bytes;
}

fn gapBucket(gap: u64) usize {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * 1024;
    if (gap < 64 * KB) return 0;
    if (gap < 256 * KB) return 1;
    if (gap < 1 * MB) return 2;
    if (gap < 4 * MB) return 3;
    if (gap < 16 * MB) return 4;
    if (gap < 64 * MB) return 5;
    if (gap < 256 * MB) return 6;
    if (gap < 1024 * MB) return 7;
    return 8;
}

const gap_labels = [GAP_BUCKETS][]const u8{
    "<64K", "<256K", "<1M", "<4M", "<16M", "<64M", "<256M", "<1G", ">=1G",
};

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn pct(n: u64, d: u64) f64 {
    if (d == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
}

pub fn report() void {
    if (comptime !enabled) return;
    // Diagnostic stderr during `zig build test --listen=-` corrupts the runner.
    if (builtin.is_test) return;
    const p = std.debug.print;
    p("\n=== depth-0 safepoint probe (-Ddepth0-probe, --workers=1) ===\n", .{});
    p("forceThunk safepoints: {d} total\n", .{total});
    p("  native_depth==0 (snapshottable): {d} ({d:.1}%)\n", .{ depth0, pct(depth0, total) });
    p("  native_depth >0 (inside builtin): {d} ({d:.1}%)\n", .{ depth_nonzero, pct(depth_nonzero, total) });
    p("native_depth histogram (0..7+):\n", .{});
    for (depth_hist, 0..) |c, d| {
        const tag = if (d == DEPTH_BUCKETS - 1) "7+" else "  ";
        p("  d={d}{s}: {d} ({d:.1}%)\n", .{ d, tag, c, pct(c, total) });
    }
    p("total allocation (monotonic, no reclaim): {d:.1} MB\n", .{mb(final_bytes)});
    p("--- RSS float feasibility: allocation gap between consecutive depth-0 points ---\n", .{});
    p("  MAX gap: {d:.1} MB   (this is the RSS floor for depth-0-only snapshots)\n", .{mb(max_gap)});
    if (depth0 > 1)
        p("  mean gap: {d:.2} MB\n", .{mb(final_bytes) / @as(f64, @floatFromInt(depth0 - 1))});
    p("  gap histogram:\n", .{});
    for (gap_hist, 0..) |c, i| p("    {s:>6}: {d}\n", .{ gap_labels[i], c });
    p("--- timeline (per 64 MB of allocation): depth-0 / depth>0 safepoints ---\n", .{});
    const last_band: usize = @intCast(@min(final_bytes / BAND_BYTES, NUM_BANDS - 1));
    var i: usize = 0;
    while (i <= last_band) : (i += 1) {
        const lo = i * 64;
        const desert = if (band_d0[i] == 0 and band_nz[i] > 0) "  <-- depth-0 DESERT" else "";
        p("  {d:>4}-{d:>4} MB: d0={d:>7}  nz={d:>8}{s}\n", .{ lo, lo + 64, band_d0[i], band_nz[i], desert });
    }
    p("=== end depth-0 probe ===\n\n", .{});
}
