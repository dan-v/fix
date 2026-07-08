//! Age-at-force census for the `-Dprof-main` profiler. For every thunk
//! main CLAIMS on its demand path, buckets the thunk's age at force and
//! attributes main's compute cycles to that bucket, sizing the
//! look-ahead ceiling of speculation. Split out of `prof.zig`; the core
//! stack profiler drives this via `ageForceBegin`/`ageForceEnd` and the
//! orchestrating `report()`.

const std = @import("std");
const worker_id = @import("runtime").worker_id;
const prof = @import("prof.zig");
const prof_path_mod = @import("prof_path.zig");
const enabled = prof.enabled;
const rdtsc = prof.rdtsc;
const pct = prof.pct;

/// Age-at-force probe (piggybacks on `-Dprof-main`). For every thunk
/// main CLAIMS on its demand path, buckets the thunk's age (force TSC
/// minus creation TSC — how long the thunk sat forcible before main
/// reached it) and attributes main's compute cycles to that bucket.
/// This measures the LOOK-AHEAD CEILING of speculation: cycles spent
/// in old thunks are cycles a helper could in principle have computed
/// before main arrived; cycles in just-created thunks are the truly
/// just-in-time chain no helper can get ahead of.
///
/// `offloadable_incl` counts INCLUSIVE cycles of top-level old forces
/// only (an old force nested inside another counted old force is
/// already covered by its parent), so it sums without double counting.
pub const AGE_BUCKET_SHIFT: u6 = 10; // bucket 0 = age < 2^10 cycles
pub const AGE_BUCKETS = 26;
pub const AgeBucket = struct { n: u64 = 0, excl: u64 = 0, incl_top: u64 = 0 };
pub var age_buckets: [AGE_BUCKETS]AgeBucket = @splat(.{});
/// Ages >= this many cycles count as "old" (~0.5ms at 3.6GHz — plenty
/// of time for a helper to have picked the thunk up).
pub const AGE_OLD_THRESHOLD: u64 = 1 << 21;
pub var age_offloadable_incl: u64 = 0;
pub var age_old_top_n: u64 = 0;
/// Old-force counts by thunk target kind (closure/bytecode/pass_through/
/// attr_access/deferred) to identify what the old thunks are.
pub var age_old_kind: [8]u64 = @splat(0);

const AgeFrame = struct {
    start_tsc: u64,
    child_exclusion: u64,
    age: u64,
    /// Offloadable cycles already claimed by OLD descendant forces of
    /// this frame (their contributions bubble up so an old ancestor
    /// only counts its remainder — no double counting).
    old_child_contrib: u64,
    key: u32,
    bucket: u8,
    is_old: bool,
};
/// Deeper than the shared prof stack: main's demand chain routinely
/// nests thousands of claimed forces (the module fixpoint recursion),
/// and a dropped frame mis-attributes its whole subtree.
const age_stack_cap: usize = 65536;
threadlocal var age_stack: [age_stack_cap]AgeFrame = undefined;
threadlocal var age_stack_len: usize = 0;
/// Diagnostics: frames not opened because the stack was full, and ends
/// dropped because the stack index didn't match (fiber migration).
pub var age_drop_full: u64 = 0;
pub var age_drop_end: u64 = 0;
pub var age_max_depth: u64 = 0;

/// Per-body aggregation of top-most old forces: which chunk/builtin
/// bodies hold the offloadable cycles. Keys follow `prof_path` (ChunkId
/// or BUILTIN_BASE+id). Open-addressed, fixed; overflow is counted.
pub const OldAgg = struct { key: u32 = SENTINEL_KEY, n: u64 = 0, sum_min: u64 = 0, sum_incl: u64 = 0 };
pub const SENTINEL_KEY: u32 = 0xFFFF_FFFF;
pub const old_agg_cap = 8192;
pub var old_agg: [old_agg_cap]OldAgg = @splat(.{});
pub var old_agg_overflow: u64 = 0;

fn oldAggAdd(key: u32, contrib: u64, incl: u64) void {
    const h: u64 = @as(u64, key) *% 0x9E3779B97F4A7C15;
    var i: usize = @intCast((h ^ (h >> 31)) & (old_agg_cap - 1));
    var probes: usize = 0;
    while (probes < 64) : (probes += 1) {
        const s = &old_agg[i];
        if (s.key == key) {
            s.n += 1;
            s.sum_min += contrib;
            s.sum_incl += incl;
            return;
        }
        if (s.key == SENTINEL_KEY) {
            s.* = .{ .key = key, .n = 1, .sum_min = contrib, .sum_incl = incl };
            return;
        }
        i = (i + 1) & (old_agg_cap - 1);
    }
    old_agg_overflow += 1;
}

/// Begin accounting a claimed demand-force on main. `created_tsc` = the
/// thunk's creation stamp (0 disables). `kind_idx` = its TargetKind int;
/// `key` identifies the body (`prof_path` key space). Returns a sentinel
/// when disabled/off-main; pass to `ageForceEnd`.
pub inline fn ageForceBegin(created_tsc: u64, kind_idx: u8, key: u32) u64 {
    if (!enabled) return std.math.maxInt(u64);
    if (worker_id.current != 0) return std.math.maxInt(u64);
    if (created_tsc == 0) return std.math.maxInt(u64);
    if (age_stack_len >= age_stack_cap) {
        age_drop_full += 1;
        return std.math.maxInt(u64);
    }
    const now = rdtsc();
    const age = now -| created_tsc;
    const lg: u6 = if (age == 0) 0 else @intCast(63 - @clz(age));
    const bucket: u8 = if (lg <= AGE_BUCKET_SHIFT) 0 else @min(@as(u8, @intCast(lg - AGE_BUCKET_SHIFT)), AGE_BUCKETS - 1);
    const is_old = age >= AGE_OLD_THRESHOLD;
    if (is_old) {
        if (kind_idx < age_old_kind.len) age_old_kind[kind_idx] += 1;
    }
    const idx = age_stack_len;
    age_stack[idx] = .{
        .start_tsc = now,
        .child_exclusion = 0,
        .age = age,
        .old_child_contrib = 0,
        .key = key,
        .bucket = bucket,
        .is_old = is_old,
    };
    age_stack_len += 1;
    if (age_stack_len > age_max_depth) age_max_depth = age_stack_len;
    return idx;
}

pub inline fn ageForceEnd(t: u64) void {
    if (!enabled) return;
    if (t == std.math.maxInt(u64)) return;
    // A fiber can resume on another worker mid-force, leaving orphan
    // frames above ours whose ends will never arrive on this thread.
    // Unwind them, then process ours. If our own frame was already
    // unwound by a later end, bail.
    if (t >= age_stack_len) {
        age_drop_end += 1;
        return;
    }
    while (age_stack_len - 1 > t) {
        age_stack_len -= 1;
        age_drop_end += 1;
    }
    const frame = &age_stack[t];
    const inclusive = rdtsc() - frame.start_tsc;
    const exclusive = inclusive - frame.child_exclusion;
    const b = &age_buckets[frame.bucket];
    b.n += 1;
    b.excl += exclusive;
    // Offload ceiling, antichain-style: an old force contributes
    // min(age, inclusive − old-descendant contributions) — a helper
    // claiming it at creation saves the full remaining compute if it
    // fits in the availability window, else a head start of `age`.
    // Descendant contributions bubble up so nothing double counts.
    var up_contrib = frame.old_child_contrib;
    if (frame.is_old) {
        const contrib = @min(frame.age, inclusive -| frame.old_child_contrib);
        if (contrib > 0) {
            age_offloadable_incl += contrib;
            age_old_top_n += 1;
            b.incl_top += contrib;
            oldAggAdd(frame.key, contrib, inclusive);
        }
        up_contrib += contrib;
    }
    age_stack_len -= 1;
    if (age_stack_len > 0) {
        const parent = &age_stack[age_stack_len - 1];
        parent.child_exclusion += inclusive;
        parent.old_child_contrib += up_contrib;
    }
}

/// Age-at-force breakdown of main's claimed demand-forces. `registry`/
/// `intern` resolve chunk keys to source locations for the per-body
/// breakdown (same shapes as `prof_path.report`).
pub fn report(registry: anytype, intern: anytype) void {
    var total_n: u64 = 0;
    var total_excl: u64 = 0;
    for (age_buckets) |b| {
        total_n += b.n;
        total_excl += b.excl;
    }
    if (total_n != 0) {
        std.debug.print(
            "prof age-at-force (main claimed demand-forces, n={d}, excl_cy={d}):\n",
            .{ total_n, total_excl },
        );
        for (age_buckets, 0..) |b, i| {
            if (b.n == 0) continue;
            const lo_shift: u6 = @intCast(AGE_BUCKET_SHIFT + i);
            std.debug.print(
                "  age<2^{d}cy: n={d} excl_cy={d} ({d:.1}%) incl_top={d}\n",
                .{ lo_shift + 1, b.n, b.excl, pct(b.excl, total_excl), b.incl_top },
            );
        }
        std.debug.print(
            "prof age-at-force diag: max_depth={d} drop_full={d} drop_end={d}\n",
            .{ age_max_depth, age_drop_full, age_drop_end },
        );
        std.debug.print(
            "prof age-at-force OLD (age>=2^21cy): top_n={d} offloadable_min_cy={d} ({d:.1}% of main claimed excl) kinds closure={d} bytecode={d} pass_through={d} attr_access={d} deferred={d}\n",
            .{
                age_old_top_n, age_offloadable_incl, pct(age_offloadable_incl, total_excl),
                age_old_kind[0], age_old_kind[1], age_old_kind[2], age_old_kind[3], age_old_kind[4],
            },
        );
        // Top bodies holding the offloadable cycles.
        const TOP = 24;
        var top: [TOP]OldAgg = @splat(.{});
        for (old_agg) |agg| {
            if (agg.key == SENTINEL_KEY) continue;
            var slot: usize = TOP;
            for (top, 0..) |t2, i| {
                if (agg.sum_min > t2.sum_min) {
                    slot = i;
                    break;
                }
            }
            if (slot < TOP) {
                var j: usize = TOP - 1;
                while (j > slot) : (j -= 1) top[j] = top[j - 1];
                top[slot] = agg;
            }
        }
        std.debug.print("prof age-at-force top offloadable bodies (overflow={d}):\n", .{old_agg_overflow});
        for (top) |agg| {
            if (agg.key == SENTINEL_KEY or agg.sum_min == 0) continue;
            std.debug.print("  min_cy={d:>11} incl_cy={d:>11} n={d:>6} {s}\n", .{
                agg.sum_min, agg.sum_incl, agg.n, prof_path_mod.locName(registry, intern, agg.key),
            });
        }
    }
}
