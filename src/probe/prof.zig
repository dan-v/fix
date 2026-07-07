//! Lightweight rdtsc-based profiler for the main thread's hot
//! serial paths. Build-gated on `-Dprof-main`; off-build compiles
//! to no-ops with zero runtime footprint.
//!
//! Helpers don't update counters (we only care about main's serial
//! pathlength), so the per-call overhead on workers is one
//! thread-local load + branch. On main it's two `rdtsc`s plus
//! stack push/pop.
//!
//! **Exclusive time.** A per-thread call stack tracks the nested
//! instrumented scopes; at `end`, the inclusive delta is recorded
//! as the sample's exclusive cycles, *minus* time already attributed
//! to nested child scopes. The parent's `child_exclusion` then
//! absorbs the popped scope's inclusive delta. This means the
//! printed cycles for each path are wall-cycles spent *inside that
//! routine but not inside any inner instrumented routine* — what
//! you want for finding bottlenecks.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const worker_id = @import("runtime").worker_id;
const BuiltinId = @import("runtime").builtins.BuiltinId;

/// Compile-time switch. False when `-Dprof-main` wasn't passed.
/// `rdtsc` is x86_64-only, so we additionally gate on arch.
pub const enabled: bool = build_options.prof_main and builtin.cpu.arch == .x86_64;

/// Tag for every instrumented path. Keep names short — they appear
/// in the stats line as-is.
pub const Path = enum {
    /// `force.forceValue` end-to-end, including both fast and slow
    /// thunk paths. Covers explicit caller forces.
    force_value,
    /// `forceThunkImpl` slow path — the thunk was not already
    /// resolved when `forceValue` peeked.
    force_thunk_slow,
    /// `access.getAttrValue` — attr lookup (post-force on the
    /// attrs operand, post-cached-lookup, post-force on the result).
    get_attr_value,
    /// `closures.callValue` — helper-callable closure entry.
    call_value,
    /// `closures.doCall` — interpreter-side closure entry.
    do_call,
    /// `closures.doTailCall` — interpreter-side closure tail entry.
    do_tail_call,
    /// `closures.runIsolatedFrame` — bytecode runner for a
    /// freshly-pushed frame.
    run_isolated_frame,
    /// `closures.makeBytecodeThunkFromCaptures` — non-trivial path
    /// (when the trivial-body short-circuit didn't apply).
    make_bytecode_thunk,
    /// Time spent in `Fiber.yield()` when a force hits a `.busy`
    /// thunk — the fiber suspends until the resolver wakes it. While
    /// suspended, worker 0 may run other fibers / drain tasks; the
    /// TSC doesn't stop, so this cycles count is wall-clock cycles,
    /// not CPU-cycles. The exclusive-time accounting subtracts any
    /// instrumented work that happens *on the same OS thread* during
    /// the yield.
    wait_busy_thunk,
    /// Time spent in `parkAndAccount` on worker 0 (the OS thread
    /// running main) when its ready queue is empty. Pure idle time
    /// from main's perspective; if this is large, helpers aren't
    /// keeping main fed.
    park_main_worker,
    /// `builtins.applyBuiltin` outer dispatch — covers the entire
    /// inline body of whichever builtin matched. A large share of
    /// `do_call` exclusive time usually lands here when the callee
    /// is `.isBuiltin()` or `.isBuiltinClosure()`.
    apply_builtin,
    /// `//` attrset update (`opMergeAttrs` + `opMergeAttrsStrict`) —
    /// the sorted merge-walk over two attrsets. Hot on the overlay
    /// fixpoint (`prev // overlay final prev`).
    merge_attrs,
    /// `Parser.parse` — tokenize + build the AST for an imported file.
    parse,
    /// `Compiler.compileAndFinish` — AST → bytecode for an imported file.
    compile,
    /// `strictness.stampOnBuilder` — per-chunk strictness analysis (a
    /// second AST walk building NameSets). Sub-phase of `compile`; its
    /// exclusive cycles are carved out of the `compile` bucket.
    strictness,
};

pub const Sample = struct {
    calls: u64 = 0,
    /// Exclusive cycles — time spent in this routine but not inside
    /// any inner instrumented routine.
    cycles: u64 = 0,
    /// Inclusive cycles — time spent in this routine including
    /// nested instrumented routines. Useful as a sanity check.
    cycles_inclusive: u64 = 0,
};

const path_count = @typeInfo(Path).@"enum".fields.len;

/// Per-path counters. Main-thread-only writes; reads (for printing)
/// happen after the eval finishes.
pub var samples: [path_count]Sample = @splat(.{});

/// Per-builtin counters (indexed by `BuiltinId`). Populated by
/// `applyBuiltin` instrumentation when the path's outer scope is
/// active. Numerator is `apply_builtin` exclusive cycles; this
/// breakdown attributes that bucket to specific builtins.
pub const max_builtin_id: usize = 256;
pub var builtin_samples: [max_builtin_id]Sample = @splat(.{});

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

/// Attr inline-cache hit/miss census (piggybacks on `-Dprof-main`).
/// Main-thread-only writes (guarded at the call site); zero-cost off.
pub var attr_cache_hits: u64 = 0;
pub var attr_cache_misses: u64 = 0;

/// Thunk-result-memo census (piggybacks on `-Dprof-main`). Sizes whether
/// the per-claimed-force TLS probe still pays for its cache misses.
pub var memo_probes: u64 = 0;
pub var memo_hits: u64 = 0;

/// Fiber cost/benefit census (piggybacks on `-Dprof-main`). Sizes what
/// the fiber machinery costs (dispatch + swap cycles per task) and what
/// it buys (how many tasks ever suspend; how many fibers are live
/// concurrently). Workers accumulate locally (see `Worker`'s census
/// fields) and flush here via `fiberFlush`; `fib_live*` is the one
/// shared-atomic piece (a concurrent gauge can't be thread-local).
pub const FiberLocal = struct {
    /// Tasks started on a freshly-reset fiber (slot/cont/scavenge/top-level).
    tasks: u64 = 0,
    /// Tasks that ran to completion (fiber reached `.finished`).
    finished: u64 = 0,
    /// Of `finished`, tasks that suspended at least once mid-run.
    finished_suspended: u64 = 0,
    /// `runFiber` calls (first runs + resumes after wake).
    resumes: u64 = 0,
    /// Resumes that ended in another suspension.
    suspend_events: u64 = 0,
    /// Fresh fiber allocations vs free-list recycles.
    allocs: u64 = 0,
    free_hits: u64 = 0,
    /// rdtsc cycles: acquire+assign+`inner.reset` (task dispatch).
    cy_dispatch: u64 = 0,
    /// rdtsc cycles: runFiber entry → first instruction inside the fiber
    /// body (run_mu, timeline branch, spec-ctx refresh, swap-in).
    cy_in: u64 = 0,
    n_in: u64 = 0,
    /// rdtsc cycles: last instruction inside the fiber body → end of
    /// runFiber's bookkeeping (swap-out, state switch, free-list push,
    /// cross-worker nudge).
    cy_out: u64 = 0,
    n_out: u64 = 0,
    /// log2 histogram of suspend counts per suspending task
    /// (bucket i = task suspended in [2^i, 2^(i+1)) times).
    susp_hist: [16]u64 = @splat(0),
};

pub var fib_totals_mu: std.atomic.Value(u8) = .init(0); // spin flag
pub var fib_totals: FiberLocal = .{};
/// Worker 0's slice of the totals — the demand thread IS the wall clock,
/// so its overhead share bounds the fiber machinery's critical-path cost.
pub var fib_totals_w0: FiberLocal = .{};

/// Merge a worker's local fiber census into the global totals and zero
/// the local. Called on park (natural batching point) and at drain-loop
/// exit, always from the owning thread.
pub fn fiberFlush(local: *FiberLocal, is_worker0: bool) void {
    if (!enabled) return;
    while (fib_totals_mu.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer fib_totals_mu.store(0, .release);
    fiberMergeInto(&fib_totals, local);
    if (is_worker0) fiberMergeInto(&fib_totals_w0, local);
    local.* = .{};
}

fn fiberMergeInto(t: *FiberLocal, local: *const FiberLocal) void {
    t.tasks += local.tasks;
    t.finished += local.finished;
    t.finished_suspended += local.finished_suspended;
    t.resumes += local.resumes;
    t.suspend_events += local.suspend_events;
    t.allocs += local.allocs;
    t.free_hits += local.free_hits;
    t.cy_dispatch += local.cy_dispatch;
    t.cy_in += local.cy_in;
    t.n_in += local.n_in;
    t.cy_out += local.cy_out;
    t.n_out += local.n_out;
    for (&t.susp_hist, local.susp_hist) |*th, l| th.* += l;
}

/// Concurrent live-fiber gauge: fibers currently assigned to a task
/// (running or suspended). Incremented at every reset-for-task site,
/// decremented when the fiber finishes. Sampled into a linear histogram
/// at each increment — biased toward busy phases, which is exactly the
/// "does the live count spike past the worker count?" question.
pub const FIB_LIVE_BUCKETS = 129; // 0..127 exact, last bucket = >=128
pub var fib_live: std.atomic.Value(u32) = .init(0);
pub var fib_live_max: std.atomic.Value(u32) = .init(0);
pub var fib_live_hist: [FIB_LIVE_BUCKETS]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));

pub inline fn fiberLiveInc() void {
    if (!enabled) return;
    const now = fib_live.fetchAdd(1, .monotonic) + 1;
    const bucket: usize = @min(now, FIB_LIVE_BUCKETS - 1);
    _ = fib_live_hist[bucket].fetchAdd(1, .monotonic);
    var cur = fib_live_max.load(.monotonic);
    while (now > cur) {
        cur = fib_live_max.cmpxchgWeak(cur, now, .monotonic, .monotonic) orelse break;
    }
}

pub inline fn fiberLiveDec() void {
    if (!enabled) return;
    _ = fib_live.fetchSub(1, .monotonic);
}

/// Per-task-class census (piggybacks on `-Dprof-main`). Every SCHEDULED
/// work item pays a fixed dispatch cost (queue push + wake + steal +
/// fiber acquire/reset/swap) before any useful work; this census sizes
/// what each task CLASS actually delivers per item:
///   - counts per class (creation-spec / novel-lane / urgent fan-out
///     force_thunk, scavenged force_thunk, list ranges, attr sweeps,
///     work-first continuations);
///   - the no-op rate: tasks whose target was ALREADY fully resolved on
///     arrival (pure scheduling overhead);
///   - the useful-work cycle distribution (log2 buckets) for the rest.
/// Recorded at fiber entry (slotEntry/contEntry) from any worker —
/// shared atomics, monotonic; the write rate is one task, not one
/// force, so contention is negligible next to the work itself. Cycles
/// are wall-rdtsc across the task INCLUDING suspended time (98.4% of
/// tasks never suspend, so the tail barely smears the histogram).
pub const TaskClass = enum(u8) {
    /// Creation-time speculative `force_thunk` (bulk spec lane).
    spec_thunk,
    /// First-instance-of-chunk `force_thunk` (novel lane, FIX_SPEC_NOVEL).
    novel_thunk,
    /// Demand fan-out `force_thunk` (urgent lane: fanOutAttrsShallow,
    /// drv-attr fan-out, strictness-driven submits).
    urgent_thunk,
    /// Idle-scavenger `force_thunk` (FIX_SCAVENGE; default off).
    scav_thunk,
    /// `force_list_range` batch (urgent lane).
    list_range,
    /// `force_attrs_sweep` whole-set sweep (FIX_SIBLING).
    attrs_sweep,
    /// Stolen work-first continuation (FIX_WORK_FIRST).
    cont,
};
pub const TASK_CLASS_COUNT = @typeInfo(TaskClass).@"enum".fields.len;
pub const TC_CY_BUCKETS = 26; // bucket i = task cycles in [2^i, 2^(i+1))

const AtomicU64 = std.atomic.Value(u64);
const tc_zero: AtomicU64 = AtomicU64.init(0);
/// Tasks seen per class.
pub var tc_n: [TASK_CLASS_COUNT]AtomicU64 = @splat(tc_zero);
/// Of `tc_n`, tasks that found ZERO unresolved work on arrival.
pub var tc_noop: [TASK_CLASS_COUNT]AtomicU64 = @splat(tc_zero);
/// force_thunk tasks whose target arrived `.evaluating` (another fiber
/// owns it — the task can only spin/enroll, never compute).
pub var tc_busy: [TASK_CLASS_COUNT]AtomicU64 = @splat(tc_zero);
/// Items covered by range/sweep tasks (1 for force_thunk) and how many
/// of those were still unresolved thunks on arrival.
pub var tc_items: [TASK_CLASS_COUNT]AtomicU64 = @splat(tc_zero);
pub var tc_items_live: [TASK_CLASS_COUNT]AtomicU64 = @splat(tc_zero);
/// Task cycles, split by whether the task had any unresolved work.
pub var tc_cy_useful: [TASK_CLASS_COUNT]AtomicU64 = @splat(tc_zero);
pub var tc_cy_noop: [TASK_CLASS_COUNT]AtomicU64 = @splat(tc_zero);
/// log2 histogram of per-task cycles for tasks WITH work.
pub var tc_hist: [TASK_CLASS_COUNT][TC_CY_BUCKETS]AtomicU64 = @splat(@splat(tc_zero));

pub fn taskCensusRecord(class: TaskClass, live_items: u64, total_items: u64, arrived_busy: bool, cycles: u64) void {
    if (!enabled) return;
    const ci = @intFromEnum(class);
    _ = tc_n[ci].fetchAdd(1, .monotonic);
    _ = tc_items[ci].fetchAdd(total_items, .monotonic);
    _ = tc_items_live[ci].fetchAdd(live_items, .monotonic);
    if (arrived_busy) _ = tc_busy[ci].fetchAdd(1, .monotonic);
    if (live_items == 0) {
        _ = tc_noop[ci].fetchAdd(1, .monotonic);
        _ = tc_cy_noop[ci].fetchAdd(cycles, .monotonic);
        return;
    }
    _ = tc_cy_useful[ci].fetchAdd(cycles, .monotonic);
    const lg: usize = if (cycles == 0) 0 else @min(63 - @clz(cycles), TC_CY_BUCKETS - 1);
    _ = tc_hist[ci][lg].fetchAdd(1, .monotonic);
}

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

/// Read TSC unconditionally. Used by `recordBuiltin` to get an
/// inclusive timestamp without going through the prof stack.
pub inline fn tscMainOnly() u64 {
    if (!enabled) return 0;
    if (worker_id.current != 0) return 0;
    return rdtsc();
}

/// Record one call to `builtin_id`. `start` is the value returned
/// by `tscMainOnly()` at builtin entry; the inclusive delta is
/// recorded against `builtin_samples[builtin_id]`. No exclusive-
/// time bookkeeping — the breakdown is just to identify the few
/// builtins whose total wall share is biggest.
pub inline fn recordBuiltin(builtin_id: u16, t_start: u64) void {
    if (!enabled) return;
    if (t_start == 0) return;
    if (builtin_id >= max_builtin_id) return;
    const inclusive = rdtsc() - t_start;
    const s = &builtin_samples[builtin_id];
    s.calls += 1;
    s.cycles += inclusive;
    s.cycles_inclusive += inclusive;
}

const NO_BUILTIN: u16 = std.math.maxInt(u16);

const StackFrame = struct {
    path: Path,
    start_tsc: u64,
    /// Sum of inclusive deltas of nested instrumented calls that
    /// have already returned. Used to compute exclusive time at end.
    child_exclusion: u64,
    /// For an `apply_builtin` frame opened via `startBuiltin`, the
    /// builtin whose EXCLUSIVE time this frame should be attributed to
    /// (`builtin_samples`). `NO_BUILTIN` otherwise.
    builtin_id: u16 = NO_BUILTIN,
};

const stack_cap: usize = 256;

/// Per-thread instrumentation stack. Only worker 0 writes to it.
threadlocal var prof_stack: [stack_cap]StackFrame = undefined;
threadlocal var prof_stack_len: usize = 0;

/// Read the TSC. `rdtsc` returns a 64-bit counter formed from
/// edx:eax. We use it as a coarse time source — the TSC is
/// invariant on modern x86_64 so it doesn't pause across power
/// states; the ratio to wall time is constant within a run.
inline fn rdtsc() u64 {
    if (!enabled) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | @as(u64, low);
}

/// Start a measurement on the main thread. Returns a sentinel
/// (UINT64_MAX) on helpers and on disabled builds; the matching
/// `end` ignores that case. The real returned value is the
/// `prof_stack` index of the pushed frame (always < stack_cap).
pub inline fn start(comptime path: Path) u64 {
    if (!enabled) return std.math.maxInt(u64);
    if (worker_id.current != 0) return std.math.maxInt(u64);
    if (prof_stack_len >= stack_cap) return std.math.maxInt(u64);
    const idx = prof_stack_len;
    prof_stack[idx] = .{
        .path = path,
        .start_tsc = rdtsc(),
        .child_exclusion = 0,
    };
    prof_stack_len += 1;
    return idx;
}

/// Like `start(.apply_builtin)` but tags the frame so its EXCLUSIVE
/// cycles are also attributed to `builtin_samples[builtin_id]` at
/// `end` — giving a per-builtin breakdown of the `apply_builtin`
/// bucket that excludes nested instrumented work (force/call/etc.),
/// i.e. the builtin's own body cost. Pair with `end(.apply_builtin, _)`.
pub inline fn startBuiltin(builtin_id: u16) u64 {
    if (!enabled) return std.math.maxInt(u64);
    if (worker_id.current != 0) return std.math.maxInt(u64);
    if (prof_stack_len >= stack_cap) return std.math.maxInt(u64);
    const idx = prof_stack_len;
    prof_stack[idx] = .{
        .path = .apply_builtin,
        .start_tsc = rdtsc(),
        .child_exclusion = 0,
        .builtin_id = builtin_id,
    };
    prof_stack_len += 1;
    return idx;
}

/// End a measurement started by `start`. No-op on disabled builds
/// and helper threads.
pub inline fn end(comptime path: Path, t: u64) void {
    if (!enabled) return;
    if (t == std.math.maxInt(u64)) return;
    const now = rdtsc();
    // The expected stack invariant: `t` indexes the topmost frame
    // and its path matches what we pushed. Tolerate mismatches by
    // unwinding only if depth is consistent — defensive guard
    // against unexpected control-flow that bypasses defer.
    if (prof_stack_len == 0 or prof_stack_len - 1 != t) return;
    const frame = &prof_stack[t];
    if (frame.path != path) return;
    const inclusive = now - frame.start_tsc;
    const exclusive = inclusive - frame.child_exclusion;
    const s = &samples[@intFromEnum(path)];
    s.calls += 1;
    s.cycles += exclusive;
    s.cycles_inclusive += inclusive;
    if (frame.builtin_id != NO_BUILTIN and frame.builtin_id < max_builtin_id) {
        const b = &builtin_samples[frame.builtin_id];
        b.calls += 1;
        b.cycles += exclusive;
        b.cycles_inclusive += inclusive;
    }
    prof_stack_len -= 1;
    // Attribute the popped scope's inclusive delta to the parent's
    // child_exclusion so the parent's exclusive time skips it.
    if (prof_stack_len > 0) {
        prof_stack[prof_stack_len - 1].child_exclusion += inclusive;
    }
}

/// Dump the main-thread path + per-builtin cycle samples
/// (`--print-sched-stats`). Lives beside the counters it reads.
/// `registry`/`intern` resolve chunk keys to source locations for the
/// age-at-force per-body breakdown (same shapes as `prof_path.report`).
pub fn report(registry: anytype, intern: anytype) void {
    inline for (@typeInfo(Path).@"enum".fields) |f| {
        const samp = samples[f.value];
        if (samp.calls != 0) {
            std.debug.print("prof: {s}: excl_cy={d} incl_cy={d} calls={d} avg_excl={d}\n", .{
                f.name,
                samp.cycles,
                samp.cycles_inclusive,
                samp.calls,
                samp.cycles / samp.calls,
            });
        }
    }
    // Top builtins by inclusive cycles on main.
    const N = 20;
    const BSlot = struct { id: u16, cycles: u64, incl: u64, calls: u64 };
    var top_b: [N]BSlot = .{BSlot{ .id = 0, .cycles = 0, .incl = 0, .calls = 0 }} ** N;
    for (builtin_samples, 0..) |samp, id| {
        if (samp.calls == 0) continue;
        var slot: usize = N;
        for (top_b, 0..) |entry, i| {
            if (samp.cycles > entry.cycles) {
                slot = i;
                break;
            }
        }
        if (slot < N) {
            var j: usize = N - 1;
            while (j > slot) : (j -= 1) top_b[j] = top_b[j - 1];
            top_b[slot] = .{ .id = @intCast(id), .cycles = samp.cycles, .incl = samp.cycles_inclusive, .calls = samp.calls };
        }
    }
    std.debug.print("prof builtins (top-20 by EXCL cycles — own-body cost):\n", .{});
    for (top_b) |entry| {
        if (entry.cycles == 0) break;
        const name = @tagName(@as(BuiltinId, @enumFromInt(entry.id)));
        std.debug.print("  {s}: excl={d} incl={d} calls={d} avg_excl={d}\n", .{ name, entry.cycles, entry.incl, entry.calls, entry.cycles / entry.calls });
    }
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
            "prof thunk-memo: probes={d} hits={d} ({d:.1}%)\n",
            .{ memo_probes, memo_hits, pct(memo_hits, memo_probes) },
        );
    }
    // Fiber cost/benefit census.
    {
        const f = &fib_totals;
        if (f.tasks != 0) {
            const rtc = f.finished - f.finished_suspended;
            std.debug.print(
                "prof fibers: tasks={d} finished={d} run_to_completion={d} ({d:.2}%) ever_suspended={d} ({d:.2}%)\n",
                .{ f.tasks, f.finished, rtc, pct(rtc, f.finished), f.finished_suspended, pct(f.finished_suspended, f.finished) },
            );
            std.debug.print(
                "prof fibers: resumes={d} suspend_events={d} allocs={d} free_hits={d}\n",
                .{ f.resumes, f.suspend_events, f.allocs, f.free_hits },
            );
            const total_over = f.cy_dispatch + f.cy_in + f.cy_out;
            std.debug.print(
                "prof fibers: cy_dispatch={d} cy_in={d} (n={d} avg={d}) cy_out={d} (n={d} avg={d}) total_overhead_cy={d}\n",
                .{
                    f.cy_dispatch,
                    f.cy_in,  f.n_in,  if (f.n_in == 0) 0 else f.cy_in / f.n_in,
                    f.cy_out, f.n_out, if (f.n_out == 0) 0 else f.cy_out / f.n_out,
                    total_over,
                },
            );
            const w0 = &fib_totals_w0;
            std.debug.print(
                "prof fibers w0: tasks={d} resumes={d} suspend_events={d} cy_dispatch={d} cy_in={d} cy_out={d} total_overhead_cy={d}\n",
                .{ w0.tasks, w0.resumes, w0.suspend_events, w0.cy_dispatch, w0.cy_in, w0.cy_out, w0.cy_dispatch + w0.cy_in + w0.cy_out },
            );
            std.debug.print("prof fibers: suspends-per-suspending-task hist:", .{});
            for (f.susp_hist, 0..) |n, i| {
                if (n == 0) continue;
                std.debug.print(" [2^{d}]={d}", .{ i, n });
            }
            std.debug.print("\n", .{});
            std.debug.print("prof fibers: live-at-task-start hist:", .{});
            for (&fib_live_hist, 0..) |*n, i| {
                const v = n.load(.monotonic);
                if (v == 0) continue;
                if (i == FIB_LIVE_BUCKETS - 1) {
                    std.debug.print(" [>={d}]={d}", .{ i, v });
                } else {
                    std.debug.print(" [{d}]={d}", .{ i, v });
                }
            }
            std.debug.print(" (max={d})\n", .{fib_live_max.load(.monotonic)});
        }
    }
    // Per-task-class census: what each scheduled item delivered.
    {
        var any: u64 = 0;
        for (&tc_n) |*n| any += n.load(.monotonic);
        if (any != 0) {
            std.debug.print("prof task-census (per scheduled item; cycles incl. suspended wall):\n", .{});
            var ci: usize = 0;
            while (ci < TASK_CLASS_COUNT) : (ci += 1) {
                const n = tc_n[ci].load(.monotonic);
                if (n == 0) continue;
                const noop = tc_noop[ci].load(.monotonic);
                const busy = tc_busy[ci].load(.monotonic);
                const items = tc_items[ci].load(.monotonic);
                const live = tc_items_live[ci].load(.monotonic);
                const cy_u = tc_cy_useful[ci].load(.monotonic);
                const cy_n = tc_cy_noop[ci].load(.monotonic);
                const useful_n = n - noop;
                std.debug.print(
                    "  {s}: n={d} noop={d} ({d:.1}%) busy_arrival={d} items={d} live_items={d} ({d:.1}%) useful_cy={d} (avg={d}) noop_cy={d} (avg={d})\n",
                    .{
                        @tagName(@as(TaskClass, @enumFromInt(ci))),
                        n,    noop, pct(noop, n), busy, items, live, pct(live, items),
                        cy_u, if (useful_n == 0) 0 else cy_u / useful_n,
                        cy_n, if (noop == 0) 0 else cy_n / noop,
                    },
                );
                std.debug.print("    cy-hist:", .{});
                for (&tc_hist[ci], 0..) |*b, i| {
                    const v = b.load(.monotonic);
                    if (v == 0) continue;
                    std.debug.print(" [2^{d}]={d}", .{ i, v });
                }
                std.debug.print("\n", .{});
            }
        }
    }
    // Discovery-serialization breakdown of main's demand forces.
    {
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
    // Age-at-force breakdown of main's claimed demand-forces.
    {
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
            const prof_path_mod = @import("prof_path.zig");
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
}

fn pct(x: u64, total: u64) f64 {
    return if (total == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(total));
}
