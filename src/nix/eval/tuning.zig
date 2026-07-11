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
    // ON by default at 2-16 workers - it deterministically kills the
    // tail-chain lottery (w=8 slow tail 7/26 -> 0/26 interleaved runs,
    // RSS neutral-to-lower, w=16 within noise). At --workers=1 nothing
    // drains speculation, so it stays off; past 16 workers it stays
    // off too - the lane is exempt from the backlog cap, and 31 idle
    // helpers chase every novel root deep (measured w=32: median 1.06
    // -> 1.11, median RSS 2940 -> 3581MB). FIX_SPEC_NOVEL=0/1 overrides.
    sched.spec_novel = worker_count > 1 and worker_count <= 16;
    if (env) |em| if (em.get("FIX_SPEC_NOVEL")) |s| {
        sched.spec_novel = !std.mem.eql(u8, s, "0");
    };
    // FIX_SPEC_HELPERS: highest worker id allowed to take bulk-spec tasks
    // (255 = uncapped, the default at every worker count). Worker-count-
    // aware junk-containment probe for high worker counts: at w=32 the
    // bulk backlog cap stops binding (31 helpers drain everything, so
    // spec_ok runs 3.1x w=8's, thunks created +32%, busy_ms 2x) — capping
    // the DRAIN capacity restores the w=8-like admission economics that
    // the backlog cap alone cannot (FIX_SPEC_BACKLOG measured dead flat).
    sched.spec_helper_cap = 255;
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
    // FIX_WORK_FIRST: route strict collection-force acceleration through the
    // work-first split-and-steal primitive instead of the eager fan-out.
    if (env) |em| sched.setWorkFirst(em.get("FIX_WORK_FIRST") != null);
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
    // Demand-sibling prefetch is ON by default when helpers exist
    // (~15% wall win on the NixOS toplevel; junk bounded by the
    // entry-count gate + per-member force/creation budgets, RSS
    // neutral-to-lower). At --workers=1 there is nobody to run the
    // sweeps — worker 0 would drain them itself as pure overhead —
    // so it defaults off there. FIX_SIBLING=0 disables (=1 forces on,
    // including at w=1, for debugging); FIX_SIBLING_MIN/MAX tune the
    // entry-count gate (defaults 16/64, from the -Dprof-main sibling
    // census).
    {
        var sib_on = worker_count > 1;
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
