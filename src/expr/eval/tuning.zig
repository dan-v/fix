//! `FIX_*` scheduler/speculation env-knob resolver.
//!
//! Reads the tuning environment variables once at the start of each eval and
//! applies them to the scheduler: speculation policy and demand-sibling
//! prefetch. Each knob's default and
//! measured rationale is documented inline. Runs before `scheduler.start`, off
//! the hot path; the import/readDir prefetch sink wiring stays in `evaluate()`
//! because it references evaluator-private callbacks.

const std = @import("std");
const scheduler_mod = @import("workers/scheduler.zig");

/// Resolve scheduler/speculation tuning into one immutable policy value.
pub fn resolve(
    base: scheduler_mod.Config,
    env: ?*const std.process.Environ.Map,
    worker_count: u8,
) scheduler_mod.Config {
    var config = base;
    // FIX_SPEC_BACKLOG: sweep the speculation backlog cap (peak-RSS↔wall knob).
    if (env) |em| if (em.get("FIX_SPEC_BACKLOG")) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |n| config.spec_backlog_per_helper = n else |_| {}
    };
    // Novel-chunk priority lane: first-ever speculation of each chunk
    // goes to the high-priority novel lane (see scheduler.spec_novel).
    // ON by default whenever helpers exist - it deterministically kills
    // the tail-chain lottery (w=8 slow tail 7/26 -> 0/26 interleaved
    // runs, RSS neutral-to-lower, w=16 within noise). At --workers=1
    // nothing drains speculation, so it stays off. The old w>16 gate
    // (wave-7: w=32 median 1.06 -> 1.11, RSS +640MB) was re-measured
    // 2026-07-11 on the post-hugetlb/post-dedup-shard scheduler WITH the
    // bulk-spec drain cap below: novel is now neutral-to-winning at w=32
    // (-2..-5% median across 6 interleaved rounds, footprint flat), so
    // the gate is gone. FIX_SPEC_NOVEL=0/1 overrides.
    config.spec_novel = worker_count > 1;
    if (env) |em| if (em.get("FIX_SPEC_NOVEL")) |s| {
        config.spec_novel = !std.mem.eql(u8, s, "0");
    };
    // FIX_SPEC_HELPERS: highest worker id allowed to take bulk-spec tasks.
    // Default 16 — inert through w=17 (worker ids run 0..w-1, so every
    // worker of a <=17-worker pool is within the cap; w<=16 behavior is
    // byte-identical by construction) and binding above it. Measured
    // motivation (2026-07-11, w=32): with 31 unrestricted drainers the
    // per-helper backlog cap stops binding — spec_ok runs 3.1x w=8's,
    // thunks created +32% (11.1M vs 8.4M), busy_ms 2x — and that junk
    // volume is what forced the old w>16 gates on the novel/prefetch
    // lanes. Capping DRAIN capacity at a w=16-sized crew restores w=8-
    // like admission economics (thunks back to 8.6-9.3M, parks halved)
    // where the backlog knob alone measured dead flat; with the cap in
    // place the novel/prefetch/sibling gates could be re-tuned on their
    // own merits. FIX_SPEC_HELPERS=255 restores uncapped.
    config.spec_helper_cap = 16;
    if (env) |em| if (em.get("FIX_SPEC_HELPERS")) |s| {
        if (std.fmt.parseInt(u8, s, 10)) |n| config.spec_helper_cap = n else |_| {}
    };
    // FIX_RESCUE: demand priority inheritance (see scheduler.spec_rescue) —
    // when a demand fiber blocks on a spec-owned thunk, promote the fiber
    // computing it (urgent sub-forces + no bail). Needs helpers; default off
    // pending A/B.
    if (env) |em| if (em.get("FIX_RESCUE")) |s| {
        config.spec_rescue = worker_count > 1 and !std.mem.eql(u8, s, "0");
    };
    // FIX_SPEC_BAND_BUDGET: hard creation budget for spec tasks rooted
    // at untrusted-band (sub-256 effective size) chunks; default ON
    // (dormant while the admission gate == trusted threshold — see
    // Scheduler.spec_band_budget). 0 disables.
    if (env) |em| if (em.get("FIX_SPEC_BAND_BUDGET")) |s| {
        if (std.fmt.parseInt(u64, s, 10)) |v| {
            config.spec_band_budget = v;
        } else |_| {}
    };
    // Demand-sibling prefetch is ON by default at 2-16 workers
    // (~15% wall win on the NixOS toplevel; junk bounded by the
    // entry-count gate + per-member force/creation budgets, RSS
    // neutral-to-lower). At --workers=1 there is nobody to run the
    // sweeps — worker 0 would drain them itself as pure overhead —
    // so it defaults off there. Past 16 workers it defaults off too:
    // the urgent-lane whole-set sweeps fan across every helper, and at
    // w=32 disabling them measured a consistent win (2026-07-11, six
    // interleaved rounds: sib-off arms -2..-5% median; the deciding
    // n=12 round: gates+cap 0.712, +sib-off 0.693, control 0.731) —
    // at that width the sweeps mostly duplicate work the spec lanes
    // already cover, at urgent priority. FIX_SIBLING=0/1 overrides
    // (=1 forces on at any worker count, including w=1, for
    // debugging); FIX_SIBLING_MIN/MAX tune the entry-count gate
    // (defaults 16/64, from the -Dprof-main sibling census).
    {
        var sib_on = worker_count > 1 and worker_count <= 16;
        var sib_min: u32 = 16;
        var sib_max: u32 = 64;
        if (env) |em| {
            if (em.get("FIX_SIBLING")) |s| sib_on = !std.mem.eql(u8, s, "0");
            if (em.get("FIX_SIBLING_MIN")) |s| {
                if (std.fmt.parseInt(u32, s, 10)) |n| sib_min = n else |_| {}
            }
            if (em.get("FIX_SIBLING_MAX")) |s| {
                if (std.fmt.parseInt(u32, s, 10)) |n| sib_max = n else |_| {}
            }
            if (em.get("FIX_SIBLING_BUDGET")) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |n| {
                    config.sibling_budget = n;
                    config.sibling_claim_budget = n;
                } else |_| {}
            }
            if (em.get("FIX_SIBLING_CLAIMS")) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |n| config.sibling_claim_budget = n else |_| {}
            }
            if (em.get("FIX_SIBLING_URGENT")) |s| {
                config.sibling_urgent = !std.mem.eql(u8, s, "0");
            }
            config.sibling_log = em.get("FIX_SIBLING_LOG") != null;
        }
        config.sibling_prefetch = sib_on;
        config.sibling_min = sib_min;
        config.sibling_max = sib_max;
    }
    return config;
}
