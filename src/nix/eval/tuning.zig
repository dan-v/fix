//! `FIX_*` scheduler/speculation env-knob resolver.
//!
//! Reads the tuning environment variables once at the start of each eval and
//! applies them to the scheduler / heap / force-path globals: the speculation
//! backlog policy, work-first fan-out, fiber-stack release mode, eager submit,
//! the scavenge family, and demand-sibling prefetch. Each knob's default and
//! measured rationale is documented inline. Runs before `scheduler.start`, off
//! the hot path; the import/readDir prefetch sink wiring stays in `evaluate()`
//! because it references evaluator-private callbacks.

const std = @import("std");
const scheduler_mod = @import("scheduler");
const heap_mod = @import("runtime").heap;
const worker_mod = @import("vm").worker;
const vm_closures = @import("vm").closures;
const vm_force = @import("vm").force;

/// Resolve and apply the scheduler/speculation tuning knobs. Takes exactly the
/// lower-layer state it touches — the scheduler, the heap's scavenge flag, the
/// environment, and the worker count — never the whole Evaluator.
pub fn apply(
    sched: *scheduler_mod.Scheduler,
    heap: *heap_mod.ObjectHeap,
    env: ?*const std.process.Environ.Map,
    worker_count: u8,
) void {
    // FIX_SPEC_BACKLOG: sweep the speculation backlog cap (peak-RSS↔wall knob).
    if (env) |em| if (em.get("FIX_SPEC_BACKLOG")) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |n| scheduler_mod.setSpecBacklog(n) else |_| {}
    };
    // FIX_SPEC_EVICT: ring semantics for the speculation backlog — at the
    // cap, drop the oldest queued spec task instead of rejecting the
    // newest submission (see scheduler.spec_evict).
    if (env) |em| if (em.get("FIX_SPEC_EVICT")) |s| {
        sched.spec_evict = !std.mem.eql(u8, s, "0");
    };
    // FIX_SPEC_LIFO: helpers steal the newest speculative task instead of
    // the oldest (see scheduler.spec_lifo).
    if (env) |em| if (em.get("FIX_SPEC_LIFO")) |s| {
        sched.spec_lifo = !std.mem.eql(u8, s, "0");
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
    sched.spec_novel = worker_count > 1;
    if (env) |em| if (em.get("FIX_SPEC_NOVEL")) |s| {
        sched.spec_novel = !std.mem.eql(u8, s, "0");
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
    sched.spec_helper_cap = 16;
    if (env) |em| if (em.get("FIX_SPEC_HELPERS")) |s| {
        if (std.fmt.parseInt(u8, s, 10)) |n| sched.spec_helper_cap = n else |_| {}
    };
    // FIX_MAX_SPINNERS: override the idle-spinner quota (0 = the default
    // formula max(7, workers/4); see scheduler.maxSpinners).
    scheduler_mod.max_spinners_override = 0;
    if (env) |em| if (em.get("FIX_MAX_SPINNERS")) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |n| scheduler_mod.max_spinners_override = n else |_| {}
    };
    // FIX_SPIN_ITERS: pre-park spin duration in parkAndAccount, in spin
    // iterations (default 1024, the historical value).
    worker_mod.spin_iterations = 1024;
    if (env) |em| if (em.get("FIX_SPIN_ITERS")) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |n| {
            if (n > 0) worker_mod.spin_iterations = n;
        } else |_| {}
    };
    // FIX_RESCUE: demand priority inheritance (see scheduler.spec_rescue) —
    // when a demand fiber blocks on a spec-owned thunk, promote the fiber
    // computing it (urgent sub-forces + no bail). Needs helpers; default off
    // pending A/B.
    if (env) |em| if (em.get("FIX_RESCUE")) |s| {
        sched.spec_rescue = worker_count > 1 and !std.mem.eql(u8, s, "0");
    };
    // FIX_FIBER_MADV=dontneed: eager (visible-RSS) comparator for the
    // overflow-fiber stack release; default is MADV_FREE (lazy reclaim).
    if (env) |em| if (em.get("FIX_FIBER_MADV")) |s| {
        worker_mod.stack_release_lazy = !std.mem.eql(u8, s, "dontneed");
    };
    // FIX_NO_EAGER: disable the strictness-driven eager thunk submit
    // (see closures.zig makeBytecodeThunkFromCapturesEager) — A/B knob.
    if (env) |em| if (em.get("FIX_NO_EAGER")) |s| {
        vm_closures.eager_submit_enabled = std.mem.eql(u8, s, "0");
    };
    // FIX_SPEC_CREATE_BUDGET: per-task thunk-creation budget for
    // spec-lane force_thunk tasks (0 = unbounded; e.g. 4096). On the
    // pre-scan-summary scheduler a 4096 budget past 16 workers cut
    // w=32 median max-RSS 4.1GB -> 2.5GB at wall-neutral (spec junk
    // reaches 10-13M thunks/eval there, ~49% never demanded). On the
    // scan-summary scheduler (413fc60/556af1a) the RSS win still
    // reproduces (median 2.95GB -> 2.47GB, spikes to 3.7GB gone) but
    // now costs ~+10% w=32 wall (interleaved n=8; budgets 16K/64K
    // don't recover it — the cheaper steal path converts those
    // cascades into demand hits), so the DEFAULT IS OFF at every
    // worker count. See Scheduler.spec_task_create_budget.
    sched.spec_task_create_budget = 0;
    if (env) |em| if (em.get("FIX_SPEC_CREATE_BUDGET")) |s| {
        if (std.fmt.parseInt(u64, s, 10)) |v| {
            sched.spec_task_create_budget = v;
        } else |_| {}
    };
    // FIX_SPEC_CLAIMS: per-task claimed-force budget for spec-lane
    // force_thunk tasks (0 = unbounded) — the claims analogue of
    // FIX_SPEC_CREATE_BUDGET (creations bound materialization-heavy
    // cascades; claims bound convergent re-force chains).
    sched.spec_task_claim_budget = 0;
    if (env) |em| if (em.get("FIX_SPEC_CLAIMS")) |s| {
        if (std.fmt.parseInt(u64, s, 10)) |v| {
            sched.spec_task_claim_budget = v;
        } else |_| {}
    };
    // FIX_SPEC_BAND_BUDGET: hard creation budget for spec tasks rooted
    // at untrusted-band (sub-256 effective size) chunks; default ON
    // (dormant while the admission gate == trusted threshold — see
    // Scheduler.spec_band_budget). 0 disables.
    if (env) |em| if (em.get("FIX_SPEC_BAND_BUDGET")) |s| {
        if (std.fmt.parseInt(u64, s, 10)) |v| {
            sched.spec_band_budget = v;
        } else |_| {}
    };
    // FIX_FANOUT_BATCH: items per force_list_range/force_attrs_range
    // task (default 16) — batch-size sweep knob.
    if (env) |em| if (em.get("FIX_FANOUT_BATCH")) |s| {
        if (std.fmt.parseInt(u8, s, 10)) |v| {
            if (v > 0) vm_force.fan_out_batch_items = v;
        } else |_| {}
    };
    // FIX_SCAVENGE: idle helpers pre-force old unresolved thunks from the
    // per-worker creation rings. FIX_SCAV_MARGIN tunes how many of the
    // newest entries stay reserved to their creator (default 4096).
    if (env) |em| {
        const scav_on = em.get("FIX_SCAVENGE") != null;
        var scav_margin: u64 = 4096;
        if (em.get("FIX_SCAV_MARGIN")) |s| {
            if (std.fmt.parseInt(u64, s, 10)) |n| scav_margin = n else |_| {}
        }
        if (em.get("FIX_SCAV_HOT")) |s| {
            if (std.fmt.parseInt(u64, s, 10)) |n| vm_force.scav_hot_threshold_cy = n else |_| {}
        }
        if (em.get("FIX_SCAV_WORKERS")) |s| {
            if (std.fmt.parseInt(u8, s, 10)) |n| sched.scav_workers = n else |_| {}
        }
        if (em.get("FIX_SCAV_MULT")) |s| {
            if (std.fmt.parseInt(u32, s, 10)) |n| vm_force.scav_take_mult = n else |_| {}
        }
        if (em.get("FIX_SCAV_SLACK")) |s| {
            if (std.fmt.parseInt(u32, s, 10)) |n| vm_force.scav_take_slack = n else |_| {}
        }
        if (em.get("FIX_SCAV_MINDEM")) |s| {
            if (std.fmt.parseInt(u32, s, 10)) |n| vm_force.scav_min_demand = n else |_| {}
        }
        sched.setScavenge(scav_on, scav_margin);
        heap.scav_record = scav_on;
    }
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
                    sched.sibling_budget = n;
                    sched.sibling_claim_budget = n;
                } else |_| {}
            }
            if (em.get("FIX_SIBLING_CLAIMS")) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |n| sched.sibling_claim_budget = n else |_| {}
            }
            if (em.get("FIX_SIBLING_URGENT")) |s| {
                sched.sibling_urgent = !std.mem.eql(u8, s, "0");
            }
            sched.sibling_log = em.get("FIX_SIBLING_LOG") != null;
            sched.touch_log = em.get("FIX_TOUCH_LOG");
        }
        sched.setSiblingPrefetch(sib_on, sib_min, sib_max);
    }
}
