//! Piggyback censuses for the `-Dprof-main` profiler: the small
//! demand-path counters that ride along the main-thread rdtsc probe —
//! discovery-serialization, attr inline-cache, thunk-result memo,
//! repeat-force, attr-lookup size, and string-machinery. Split out of
//! `prof.zig`; these are plain worker-0-guarded counters written at
//! their call sites and dumped by the report helpers here.

const std = @import("std");
const prof = @import("prof.zig");
const pct = prof.pct;

/// Discovery-serialization probe (piggybacks on `-Dprof-main`).
/// Classifies MAIN worker 0's demand-path forces to size the gap
/// between "a helper resolved this ahead of me" (win), "I out-ran the
/// helpers and had to compute it myself" (claimed), and "I blocked on
/// a helper computing it" (busy_wait). At a busy-wait we also record
/// whether the awaited thunk was still un-`demanded` — i.e. claimed
/// speculatively at background priority, so a demand->spec PROMOTION
/// would let the critical path pull it up. All writes are worker-0-only
/// (no races); zero-cost when the build flag is off.
pub const Disc = struct {
    resolved_ahead: u64 = 0,
    claimed_by_main: u64 = 0,
    busy_wait: u64 = 0,
    busy_spec_owned: u64 = 0,
    busy_cycles: u64 = 0,
    busy_spec_cycles: u64 = 0,
};
pub var disc: Disc = .{};

/// Strict-collection-walk size census (piggybacks on `-Dprof-main`): sizes
/// the collections MAIN (worker 0, demand context) strictly walks via
/// `forceListAccelerate` / `forceAttrsAccelerate`. `fan_out_min_items` (=4)
/// is the fan-out floor, so walks below it are UNFANNABLE — main forces their
/// elements serially, one at a time. Tests whether the module-merge mass is
/// many SMALL (sub-threshold) lists — aggregate parallelism that per-list
/// fan-out structurally cannot reach — versus a few large ones. Worker-0-only.
pub const StrictWalks = struct {
    walks: u64 = 0, // total demand strict walks
    items: u64 = 0, // total elements across them
    small_walks: u64 = 0, // walks with < fan_out_min_items elements (unfannable)
    small_items: u64 = 0, // elements in those unfannable walks
    // size histogram: [0]=1 [1]=2-3 [2]=4-7 [3]=8-15 [4]=16-31 [5]=32-63 [6]=64+
    buckets: [7]u64 = @splat(0),
};
pub var list_walks: StrictWalks = .{};
pub var attrs_walks: StrictWalks = .{};

pub inline fn recordStrictWalk(w: *StrictWalks, len: usize, fan_min: usize) void {
    w.walks += 1;
    w.items += len;
    if (len < fan_min) {
        w.small_walks += 1;
        w.small_items += len;
    }
    const b: usize = if (len <= 1) 0 else if (len <= 3) 1 else if (len <= 7) 2 else if (len <= 15) 3 else if (len <= 31) 4 else if (len <= 63) 5 else 6;
    w.buckets[b] += 1;
}

pub fn reportStrictWalks(w: *const StrictWalks, label: []const u8) void {
    if (w.walks == 0) return;
    std.debug.print(
        "prof strict-{s} walks (main demand): n={d} items={d} | UNFANNABLE(<4) walks={d} ({d:.1}%) items={d} ({d:.1}%) | sizes 1={d} 2-3={d} 4-7={d} 8-15={d} 16-31={d} 32-63={d} 64+={d}\n",
        .{
            label, w.walks, w.items,
            w.small_walks, pct(w.small_walks, w.walks),
            w.small_items, pct(w.small_items, w.items),
            w.buckets[0], w.buckets[1], w.buckets[2], w.buckets[3], w.buckets[4], w.buckets[5], w.buckets[6],
        },
    );
}

/// Attr inline-cache hit/miss census (piggybacks on `-Dprof-main`).
/// Main-thread-only writes (guarded at the call site); zero-cost off.
pub var attr_cache_hits: u64 = 0;
pub var attr_cache_misses: u64 = 0;

/// Thunk-result-memo census (piggybacks on `-Dprof-main`). Sizes whether
/// the per-claimed-force TLS probe still pays for its cache misses.
pub var memo_probes: u64 = 0;
pub var memo_hits: u64 = 0;
/// Memo eligibility histogram: forces of freshly-claimed bytecode thunks
/// that were NOT memo-probed because their upvalue count exceeds the ≤2
/// inline-key limit. Sizes the widening headroom.
pub var memo_inel_3: u64 = 0;
pub var memo_inel_4: u64 = 0;
pub var memo_inel_ge5: u64 = 0;

/// Repeat-force census (piggybacks on `-Dprof-main`): demand forces that
/// hit an ALREADY-RESOLVED thunk, bucketed by access path. These are the
/// forces a resolved-value writeback (thunk shortcutting) would turn into
/// plain-value reads — each one currently touches the thunk's cache line.
/// Worker-0-only writes.
pub var fv_plain: u64 = 0; // forceValue on a non-thunk value
pub var fv_resolved: u64 = 0; // forceValue resolved-thunk fast-path hit
pub var rf_local: u64 = 0; // opGetLocal(/Long) re-read of resolved thunk in a stack slot
pub var rf_upvalue: u64 = 0; // opGetUpvalue re-read of resolved thunk in a capture array
pub var rf_attr_hit: u64 = 0; // attr-cache HIT returning an already-resolved thunk

/// Attr-lookup size census (piggybacks on `-Dprof-main`): attr-cache
/// MISSES (the compulsory binary-search population) bucketed by the
/// looked-up set's entry count — log2 buckets [0]=1..2, [1]=3..4, ...
/// Sizes the per-object hash-index headroom (binary-search probes are
/// dependent cache misses on large sets). `al_merge` counts lookups that
/// hit an unflattened merge_attrs chain (no single size).
pub const AL_BUCKETS = 16;
pub var al_size: [AL_BUCKETS]u64 = @splat(0);
pub var al_probes: [AL_BUCKETS]u64 = @splat(0); // ~log2(n) per lookup, summed
pub var al_merge: u64 = 0;

/// String-machinery census (piggybacks on `-Dprof-main`). Sizes the
/// byte-assembly cost of the interning value representation: every
/// binary concat (`+` and each `${...}` interpolation boundary)
/// allocates a temp buffer, copies both sides, and interns the
/// intermediate — a k-part interpolation pays O(k) passes over its
/// prefix bytes and leaks every intermediate into the intern table.
/// Worker-0-only writes (guarded at the call sites via `tscMainOnly`).
pub const StrCensus = struct {
    /// `concatInternedString` — the pure assembly step of every binary
    /// string/path concat (no forcing inside; excl == incl).
    concat_calls: u64 = 0,
    concat_cycles: u64 = 0,
    /// Result bytes per call, summed — the bytes copied AND hashed.
    concat_bytes: u64 = 0,
    /// Calls whose result was a first-time intern (table miss): these
    /// bytes stay in the intern table forever.
    concat_new: u64 = 0,
    concat_new_bytes: u64 = 0,
};
pub var str: StrCensus = .{};

/// String-machinery census.
pub fn reportStrConcat() void {
    if (str.concat_calls != 0) {
        std.debug.print(
            "prof str-concat: calls={d} cycles={d} avg_cy={d} bytes={d} new={d} ({d:.1}%) new_bytes={d}\n",
            .{
                str.concat_calls,           str.concat_cycles,
                str.concat_cycles / str.concat_calls, str.concat_bytes,
                str.concat_new,             pct(str.concat_new, str.concat_calls),
                str.concat_new_bytes,
            },
        );
    }
}

/// Attr inline-cache, thunk-memo, repeat-force, and attr-lookup size
/// censuses (contiguous demand-path breakdowns).
pub fn reportCaches() void {
    // Attr inline-cache census.
    {
        const total = attr_cache_hits + attr_cache_misses;
        if (total != 0) {
            std.debug.print(
                "prof attr-cache: lookups={d} hits={d} ({d:.1}%) misses={d}\n",
                .{ total, attr_cache_hits, pct(attr_cache_hits, total), attr_cache_misses },
            );
        }
    }
    // Thunk-result-memo census.
    if (memo_probes != 0) {
        std.debug.print(
            "prof thunk-memo: probes={d} hits={d} ({d:.1}%) inel_ups3={d} inel_ups4={d} inel_ups>=5={d}\n",
            .{ memo_probes, memo_hits, pct(memo_hits, memo_probes), memo_inel_3, memo_inel_4, memo_inel_ge5 },
        );
    }
    // Repeat-force census.
    {
        const total = fv_plain + fv_resolved;
        if (total != 0) {
            std.debug.print(
                "prof repeat-force: fv_plain={d} fv_resolved={d} rf_local={d} rf_upvalue={d} rf_attr_hit={d}\n",
                .{ fv_plain, fv_resolved, rf_local, rf_upvalue, rf_attr_hit },
            );
        }
    }
    // Attr-lookup size census.
    {
        var total: u64 = 0;
        for (al_size) |n| total += n;
        if (total != 0) {
            std.debug.print("prof attr-lookup sizes (cache misses; bucket=[2^k+1..2^(k+1)] entries):\n", .{});
            for (al_size, 0..) |n, k| {
                if (n == 0) continue;
                std.debug.print(
                    "  size<=2^{d}: lookups={d} ({d:.1}%) probes={d}\n",
                    .{ k + 1, n, pct(n, total), al_probes[k] },
                );
            }
            std.debug.print("  merge-chain lookups={d}\n", .{al_merge});
        }
    }
}

/// Discovery-serialization breakdown of main's demand forces.
pub fn reportDiscovery() void {
    const total = disc.resolved_ahead + disc.claimed_by_main + disc.busy_wait;
    if (total != 0) {
        std.debug.print(
            "prof discovery (main demand-forces, n={d}): resolved_ahead={d} ({d:.1}%) claimed_by_main={d} ({d:.1}%) busy_wait={d} ({d:.1}%)\n",
            .{
                total,
                disc.resolved_ahead,  pct(disc.resolved_ahead, total),
                disc.claimed_by_main, pct(disc.claimed_by_main, total),
                disc.busy_wait,       pct(disc.busy_wait, total),
            },
        );
        std.debug.print(
            "prof discovery (crit-path busy waits): busy_spec_owned={d}/{d} spec_wait_cy={d} total_wait_cy={d} ({d:.1}% of wait cycles is spec-owned = PROMOTION headroom)\n",
            .{
                disc.busy_spec_owned, disc.busy_wait,
                disc.busy_spec_cycles, disc.busy_cycles,
                pct(disc.busy_spec_cycles, disc.busy_cycles),
            },
        );
    }
}
