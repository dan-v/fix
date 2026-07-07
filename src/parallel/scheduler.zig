//! Work-stealing scheduler for parallel evaluation.
//!
//! Workers are symmetric (F1). Every `worker_id ∈ 0..worker_count-1`
//! owns:
//!   - A task queue (`queues[id]`), receiving speculative and urgent
//!     submissions from any worker.
//!   - A ready-fiber queue (`ready_queues[id]`), receiving fibers
//!     woken by thunk resolves (`wakeFiberWaiters`). Both task and
//!     ready queues are stealable across workers.
//!   - A wake word (`wake_words[id]`) for futex-based parking.
//!
//! Worker 0 runs on the calling OS thread (it's the one returning the
//! result to the user); worker_ids 1..N-1 are helper threads spawned
//! in `start()`. There is no behavioral asymmetry beyond who created
//! the thread — submissions, steals, wakes, and ready-fiber routing
//! all treat workers uniformly.
//!
//! Each worker's drain loop:
//!   1. Pop own ready fiber, or steal one from another worker.
//!   2. Pop own task, or steal one from another worker (FIFO at the
//!      victim).
//!   3. Park on its wake_word until a submitter / waker nudges.
//!
//! Submissions may fail (full queue). Speculative submissions are
//! best-effort and additionally gated by a backlog cap. Urgent
//! (demand-driven) submissions skip the cap.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("runtime").types;
const stable = @import("runtime").stable_segments;
const gc = @import("runtime").gc;
const heap_mod = @import("runtime").heap;
const containers = @import("containers");

pub const Task = union(enum) {
    /// Speculatively force a thunk to its result. The thunk lives in the
    /// shared ObjectHeap; ObjectId identifies it.
    force_thunk: types.ObjectId,
    /// Force a contiguous range of items from a list. Used by consumer-
    /// side fan-out so each scheduled task pays the queue + wake overhead
    /// once for a meaningful chunk of work instead of once per thunk.
    /// The helper looks up `list_id` in the heap, iterates
    /// `items[offset..offset+len]`, and forces each thunk-typed slot.
    /// `len` is u8 — batches are O(10s) of items; longer lists submit
    /// multiple batched tasks.
    force_list_range: ForceListRange,
    /// Demand-sibling prefetch (`FIX_SIBLING`): speculatively force every
    /// still-unresolved thunk member of one attrset. Submitted (once per
    /// attrset — see `AttrsObject.sibling_swept`) when a DEMAND fiber's
    /// attr lookup misses the inline cache and lands on an unresolved
    /// member of a mid-sized attrset: reading one member of such a set
    /// strongly predicts reading its siblings (measured junk ratio
    /// 17-29% at 16-63 entries vs 99% at >=256 — hence the size gate).
    force_attrs_sweep: types.ObjectId,
};

pub const ForceListRange = struct {
    list_id: types.ObjectId,
    offset: u32,
    len: u8,
};

/// Work-first (Cilk/sparks) split-and-steal continuation — a half-open range
/// `[lo, hi)` of a collection's items exposed on the per-worker continuation
/// deque (`cont_queues`). `kind` distinguishes a list slot walk from an attr
/// slot walk (the heap stores each as a positional slice, so the range is
/// index-based either way). Owner-pushed/popped LIFO on the fast (unstolen)
/// path; FIFO-stolen by an idle worker that re-splits it. See
/// `force.forceRangeWorkFirst`.
pub const ContKind = enum(u8) { list, attrs };
pub const Continuation = struct {
    id: types.ObjectId,
    lo: u32,
    hi: u32,
    kind: ContKind,
};

/// Embeddable linked-list node for the per-worker ready queue.
/// Each Fiber struct (in worker.zig) inlines one of these; the
/// scheduler holds queues of `*ReadyNode` and the worker recovers
/// the parent Fiber via `@fieldParentPtr`.
///
/// `queued` is a CAS-protected dedup flag: `enqueueReady` only
/// pushes when it can transition 0→1, and `pop` resets to 0. This
/// keeps the node from being on the queue more than once even when
/// multiple wakers and runner-tail paths race to enqueue.
pub const ReadyNode = struct {
    next: ?*ReadyNode = null,
    queued: std.atomic.Value(u8) = .init(0),
};

/// Mutex-protected FIFO of fibers ready to resume. Sits on the
/// scheduler so any worker can push (when waking a fiber) or steal
/// (when its own queue is empty). Treiber stacks would suffice if
/// only the owner consumed, but stealing needs MPMC pop and Treiber's
/// CAS pop has ABA hazards under concurrent consumers.
const ReadyQueue = struct {
    mu: stable.SpinMutex,
    head: ?*ReadyNode,
    tail: ?*ReadyNode,

    fn init() ReadyQueue {
        return .{ .mu = .{}, .head = null, .tail = null };
    }

    fn push(self: *ReadyQueue, node: *ReadyNode) void {
        node.next = null;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tail) |t| {
            t.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
    }

    fn pop(self: *ReadyQueue) ?*ReadyNode {
        self.mu.lock();
        defer self.mu.unlock();
        const n = self.head orelse return null;
        self.head = n.next;
        if (self.head == null) self.tail = null;
        n.next = null;
        // Mark off-queue so the next `enqueueReady` for this node can
        // win its CAS. Release-store so it's visible to the next
        // would-be enqueuer.
        n.queued.store(0, .release);
        return n;
    }
};

/// Lock-free Chase-Lev work-stealing deque, specialized to `Task`.
///
/// Owner-only `push` and `pop` (LIFO) — atomic stores on `bottom`
/// with no CAS on the hot path. `steal` is multi-consumer (FIFO),
/// CAS-on-`top` to claim a slot.
///
/// Memory ordering follows the standard Chase-Lev formulation
/// (Le-Pop-Cohen-Nardelli-Padua 2013 revision):
///   - `bottom` writes use release; reads in stealers use acquire.
///   - `top` writes use seq_cst (CAS) so the owner's `pop` race for
///     the last element synchronises with concurrent steals.
///   - The seq_cst fence in `pop` after writing `bottom` is what
///     prevents the owner from "seeing past" a stealer that has
///     already taken the slot.
///
/// Capacity is fixed power-of-two; full push returns false and the
/// caller drops the task (speculation is best-effort; urgent
/// submission's cap is enforced upstream by `pending_tasks`).
///
/// The generic engine lives in `containers.Deque` (extracted so GC mark
/// work can reuse the same lock-free ring for `Deque(ObjectId)`); this is a
/// thin alias plus the `Task`-specific `gcMark` helper.
/// A queued task plus the monotonic-ns timestamp of when it was pushed. The
/// timestamp is only populated when flow tracing is on (`trace_flows`) — it
/// costs one clock read per push and lets the timeline anchor the work-stealing
/// arrow's producer end to the quantum that actually *created* the task (see
/// `Worker.drainStep`). Off the tracing path it's a dead `0` (negligible: the
/// deque slot grows 8 bytes, no clock read).
pub const TracedTask = struct {
    task: Task,
    push_ts: u64 = 0,
};

const TaskQueue = containers.Deque(TracedTask);

/// Per-worker deque of work-first split-and-steal continuations (see
/// `Continuation`). Same Chase-Lev engine as `TaskQueue`, distinct payload.
const ContQueue = containers.Deque(Continuation);

/// GC (`-Dgc`): mark the objects referenced by pending tasks. A queued
/// `force_thunk`/`force_list_range` is a live reference (a helper — or,
/// after this collection, demand — may still force it). Called only at
/// the STW safepoint, so `top..bottom` is stable.
fn taskQueueGcMark(q: *const TaskQueue, tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
    const t = q.top.load(.monotonic);
    const b = q.bottom.load(.monotonic);
    var i = t;
    while (i != b) : (i +%= 1) {
        switch (q.items[@intCast(i & q.mask)].task) {
            .force_thunk => |id| tr.markObject(heap, id),
            .force_list_range => |r| tr.markObject(heap, r.list_id),
            .force_attrs_sweep => |id| tr.markObject(heap, id),
        }
    }
}

/// Monotonic-ns clock, matching `probe/timeline.zig`'s `nowNs` domain so the
/// push timestamps and the timeline's quantum spans share one time base. The
/// scheduler can't import the probe layer, so the formula is duplicated here.
fn monotonicNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * std.time.ns_per_s + nsec;
}

// Demand-driven fanout arrives in bursts: when the urgent queue rejects,
// the caller falls back to serially forcing the rest of the list/attrset.
// Keep enough room that a NixOS toplevel fanout wave does not collapse
// back onto the critical path at 32 workers.
const urgent_queue_capacity: u32 = 4096;
const spec_queue_capacity: u32 = 4096;
/// Work-first continuation deque capacity (power of two). A full push just
/// stops splitting (the range is forced inline), so this only bounds how much
/// parallelism is exposed at once, not correctness.
const cont_queue_capacity: u32 = 4096;
/// Per-helper speculation backlog cap. `var` (not `const`) so `FIX_SPEC_BACKLOG`
/// can sweep it — it's the primary control on how much speculative garbage runs
/// ahead of demand, i.e. the peak-RSS↔wall knob.
var spec_backlog_per_helper: u32 = 128;
pub fn setSpecBacklog(n: u32) void {
    spec_backlog_per_helper = n;
}
const burst_wake_budget: u32 = 4;

/// Cap on helpers concurrently in the idle spin-rescan loop (see
/// `Scheduler.spinners`). Never binds at w<=8 (7 helpers all spin, the
/// measured-optimal behavior there); past that, only a core's worth of
/// helpers keep scanning while the rest park until a submit wake.
inline fn maxSpinners(worker_count: u8) u32 {
    return @max(7, @as(u32, worker_count) / 4);
}

/// GC parallel-mark hook (`-Dgc`): the Evaluator installs this so a parked
/// peer can help drain the mark graph. Type-erased to keep `parallel` free of
/// an `eval`/`runtime.gc` import (mirrors the heap's `GcHook`).
pub const GcMarkHook = struct {
    ctx: *anyopaque,
    /// Run marker `worker_id`'s drain-and-steal loop to termination.
    help: *const fn (ctx: *anyopaque, worker_id: u8) void,
};

pub const Scheduler = struct {
    /// Per-worker, cache-line-padded activity counters. A worker only
    /// ever touches `worker_counters[its_own_id]`, so the adds need no
    /// atomics and generate no inter-core coherence traffic. 9 u64s =
    /// 72B; padded to 128B so two workers' hot counters can't land in
    /// the same 64B line.
    pub const Counters = struct {
        spec_ok: u64 = 0,
        spec_rej: u64 = 0,
        urgent_ok: u64 = 0,
        urgent_rej: u64 = 0,
        pops: u64 = 0,
        steals: u64 = 0,
        cont_steals: u64 = 0,
        cont_pushes: u64 = 0,
        parks: u64 = 0,
        scavenges: u64 = 0,
        sweeps: u64 = 0,
        _pad: [128 - 11 * @sizeOf(u64)]u8 = undefined,
    };

    /// Bump one field of worker `id`'s own counter slot. `field` is the
    /// `Counters` field name. Bounds-guarded so a stray id can never
    /// corrupt memory — a miscounted stat is harmless, an OOB write is
    /// not. Off the atomics entirely: single-writer per slot.
    inline fn bump(self: *Scheduler, id: u8, comptime field: []const u8) void {
        if (id >= self.worker_count) return;
        @field(self.worker_counters[id], field) += 1;
    }

    /// Cumulative scheduler activity counters. Read via `stats()`.
    /// All values are advisory — monotonic loads are fine.
    pub const Stats = struct {
        speculative_submitted: u64,
        speculative_rejected: u64,
        urgent_submitted: u64,
        urgent_rejected: u64,
        pops: u64,
        steals: u64,
        cont_steals: u64 = 0,
        cont_pushes: u64 = 0,
        parks: u64,
        /// Thunks pre-forced by the idle scavenger (FIX_SCAVENGE).
        scavenges: u64 = 0,
        /// Attrset sibling sweeps submitted (FIX_SIBLING).
        sweeps: u64 = 0,
        /// Deepest fiber native stack high-water seen across all workers
        /// since startup. Use to size `Fiber.min_stack_bytes` against a
        /// representative workload.
        max_fiber_stack_used_bytes: u64,
        /// Deepest VM value-stack sp seen across all workers, in Values.
        /// Multiply by `@sizeOf(Value)` (= 8) for a byte count.
        max_vm_sp: u64,
        /// Summed across all workers (main + helpers): time spent parked
        /// on the wake futex, in nanoseconds. Together with `busy_ns` and
        /// the wall-clock run time, this lets `fix inspect` show whether
        /// helpers were starved (idle ≫ busy ⇒ not enough parallel work)
        /// or saturated (busy ≈ wall × workers ⇒ CPU-bound).
        idle_ns: u64,
        /// Summed across all workers: time spent inside a fiber's
        /// `inner.resume_` (actual evaluation work). Excludes ready-queue
        /// pops and steal attempts — those are nanoseconds compared to
        /// either bucket and don't change the utilisation picture.
        busy_ns: u64,
    };

    allocator: std.mem.Allocator,
    /// Total number of workers, including worker 0 (main). After F1
    /// symmetrization there is no special main/helper split — every
    /// worker owns a queue, a wake word, and a ready-fiber stack. The
    /// only structural difference: worker 0 runs on the calling OS
    /// thread (it's the one delivering the result), so we spawn
    /// `worker_count - 1` helper threads in `start()`.
    worker_count: u8,
    /// Per-worker queue of *demand-driven* tasks — submitted via
    /// `submitUrgent`. Drained with priority over speculative tasks so
    /// fan-out and strictness-driven submissions don't sit behind a
    /// queued speculation backlog.
    // (GC hook defined below via gcMarkPendingTasks)
    urgent_queues: []TaskQueue,
    /// Per-worker queue of *speculative* tasks — submitted via
    /// `submit` when `makeThunk`'s heuristic suggests the body is
    /// substantial enough to pre-run. Drained only when there's no
    /// ready fiber or urgent task to handle.
    spec_queues: []TaskQueue,
    /// Per-worker deque of work-first split-and-steal continuations. Owner
    /// pushes/pops LIFO on the unstolen fast path; idle workers take FIFO.
    /// Separate from the eager task queues so the work-first pop-back never
    /// races the drain loop's task picks. Gated by `work_first`.
    cont_queues: []ContQueue,
    /// Per-worker ready-fiber queues. Producers are any thread waking a
    /// fiber (via thunk resolve → `Fiber.wakeImpl`); consumers are the
    /// owning worker (most often) or any worker stealing when its own
    /// queue is empty. Indexed by worker_id.
    ready_queues: []ReadyQueue,
    threads: []std.Thread,
    wake_words: []std.atomic.Value(u32),
    shutdown_flag: std.atomic.Value(bool),
    /// Count of helper threads that have stopped forcing (exited `run`)
    /// at shutdown. The quiescence barrier (`awaitHelpersQuiescent`) waits
    /// on this so no helper destroys its fibers while another could still
    /// resolve a thunk and wake a just-freed enrolled fiber.
    stopped_helpers: std.atomic.Value(u32) = .init(0),
    next_victim: std.atomic.Value(u32),
    /// Monotonic counter handing out fresh fiber ids at allocation.
    /// Fiber ids are scheduler-global so a fiber's identity doesn't
    /// change when it migrates across workers (F1 unpin). Used to
    /// construct `ClaimerId` and to label the fiber in traces.
    next_fiber_id: std.atomic.Value(u32),
    started: std.atomic.Value(bool),
    /// Total tasks currently pending across all helper queues. Used to
    /// (a) skip submissions when the backlog already saturates helpers
    /// and (b) skip futex_wake syscalls when at least one helper has
    /// work to do and is therefore not parked.
    pending_tasks: std.atomic.Value(u32),
    /// Number of helpers currently in the idle spin-rescan loop
    /// (parkAndAccount's pre-park spin + immediate rescan). Capped at
    /// `max_spinners` so at high worker counts the idle scan churn
    /// (O(N) queue probes per rescan, from every idle worker, burning
    /// the SMT siblings of busy workers) stays bounded: workers past
    /// the cap park on their futex immediately and are re-engaged by
    /// submit-side wakes. Worker 0 is exempt (it's the demand thread).
    spinners: std.atomic.Value(u32),
    /// Net work-first continuations currently sitting on all `cont_queues`
    /// (pushed − popped/stolen). A single shared counter the pre-park spin
    /// reads to decide whether to keep spinning for stealable continuation
    /// work, without per-queue CAS probes (same design as `pending_tasks`).
    cont_pending: std.atomic.Value(u32),
    /// Per-worker activity counters. Each worker writes ONLY its own
    /// slot — single-writer, plain non-atomic adds. This kills the
    /// cross-core cache-line contention that shared-atomic counters
    /// caused on the hot submit/pop/steal/park path: at high worker
    /// counts dozens of cores `fetchAdd`-ing the same lines was pure
    /// coherence traffic that scaled *against* us (slower past ~8).
    /// Summed at report time, after all workers have quiesced. Each
    /// slot is padded to a cache line so adjacent workers never share
    /// one (no false sharing).
    worker_counters: []Counters,
    n_max_fiber_stack: std.atomic.Value(u64),
    n_max_vm_sp: std.atomic.Value(u64),
    n_idle_ns: std.atomic.Value(u64),
    n_busy_ns: std.atomic.Value(u64),

    /// Measurement toggles. When set, the corresponding submission path
    /// short-circuits to false without touching the queues. Used by
    /// `--no-spec-thunks` / `--no-fanout` to A/B which kind of parallel
    /// work contributes how much to wall time.
    disable_speculation: bool,
    disable_fanout: bool,

    /// `FIX_WORK_FIRST`: route strict collection-force acceleration through the
    /// work-first split-and-steal primitive (`forceRangeWorkFirst`) instead of
    /// the eager `fanOut*Shallow`. Set once before helpers start, read-only
    /// during eval (plain bool — no atomic needed). Default off while landing.
    work_first: bool,

    /// `FIX_SCAVENGE`: idle helpers pre-force old unresolved thunks from
    /// the per-worker creation rings (`ObjectHeap.scavengeSteal`) —
    /// lowest-priority work, after ready fibers / tasks / continuations.
    /// Set once before helpers start, read-only during eval.
    scavenge_enabled: bool = false,
    /// Skip the newest N ring entries when scavenging (see
    /// `scavengeSteal`). `FIX_SCAV_MARGIN` overrides.
    scav_margin: u64 = 4096,
    /// Highest worker id allowed to scavenge. `FIX_SCAV_WORKERS` overrides.
    scav_workers: u8 = 7,

    /// `FIX_SIBLING`: demand-sibling prefetch. On a demand fiber's
    /// inline-cache MISS landing on a still-unresolved thunk member of a
    /// plain attrset with entry count in `[sibling_min, sibling_max)`,
    /// submit ONE speculative `force_attrs_sweep` task for the whole set
    /// (deduped by `AttrsObject.sibling_swept`). Set once before helpers
    /// start, read-only during eval.
    sibling_prefetch: bool = false,
    /// Attrset entry-count gate. Defaults from the `-Dprof-main` sibling
    /// census: 16-63 entries = 17-29% junk; >=64 grows to 51%, >=256 is
    /// 99% junk (pkgs-like sets — sweeping those evaluates all of
    /// nixpkgs). `FIX_SIBLING_MIN`/`FIX_SIBLING_MAX` override.
    sibling_min: u32 = 16,
    sibling_max: u32 = 64,
    /// Per-member claimed-force budget for sweep tasks (see
    /// `VM.spec_budget`): a wrongly-predicted member's cascade is
    /// abandoned after this many claimed forces. `FIX_SIBLING_BUDGET`
    /// overrides.
    sibling_budget: u64 = 4096,
    /// Submit sweeps to the urgent queue (drained before the speculative
    /// backlog) instead of the spec queue. Default ON — measured strictly
    /// better on the NixOS toplevel (w=8 median 1.24s→1.03s vs ~1.3s at
    /// spec priority, and LOWER RSS: urgent sweeps start early enough to
    /// win the race with main, and they displace never-demanded
    /// creation-time speculation). `FIX_SIBLING_URGENT=0` reverts to
    /// spec priority.
    sibling_urgent: bool = true,
    /// `FIX_SIBLING_LOG`: per-sweep stderr diagnostics (attrs id, size,
    /// member body locations, heap-growth delta). Debug-only.
    sibling_log: bool = false,

    /// When set (by `setTraceFlows`, driven by `--timeline`), `pushOwn` stamps
    /// each task with its push time so the timeline can anchor the steal arrow
    /// to the producing quantum. Off by default — one dead branch per push.
    trace_flows: bool = false,

    /// Set once a top-level demanded result is ready, to stop workers
    /// from *starting* new background (speculative / fan-out) tasks while
    /// the drain loop waits for already-suspended fibers to retire. Bounds
    /// the worst case where speculation guessed a large, never-demanded
    /// body: without it, helpers keep pulling the dead backlog and extend
    /// wall time past when the answer was computed (a self-inflicted
    /// pathology — see docs/plans/parallel-redesign-plan.md). In-flight fibers
    /// still drain to completion (a suspended fiber only waits on an
    /// already-claimed thunk, never on a queued task), so correctness is
    /// unaffected; only un-started backlog work is skipped.
    suppress_background: std.atomic.Value(bool),

    /// GC stop-the-world barrier (`-Dgc`). When a worker crosses the
    /// collection threshold at a safepoint it CASes `gc_stop_requested`
    /// true and becomes the sole collector. Every other worker, on seeing
    /// the flag at its own safepoint, sets its per-worker `gc_worker_parked`
    /// flag and spins until the flag clears. The collector waits for all
    /// peers' flags to be set, runs mark+sweep alone (no concurrent
    /// mutation), clears the stop flag, then waits for all peers' flags to
    /// clear before returning — a full two-phase barrier, so a slow peer can
    /// never carry a stale parked state into the next collection (which a
    /// shared counter + epoch could). `void`-free but inert in non-`-Dgc`.
    gc_stop_requested: if (gc.enabled) std.atomic.Value(bool) else void,
    gc_worker_parked: if (gc.enabled) []std.atomic.Value(bool) else void,

    /// Parallel-mark phase gate (`-Dgc`, `--workers>1`). Once every peer is
    /// parked (`gcWaitAllParked`), the collector seeds the roots and then
    /// opens this flag; each parked peer, seeing it, calls the mark hook to
    /// help drain the graph (marker slot == its worker id) instead of merely
    /// spinning. It stays open for the whole mark and is closed only AFTER
    /// termination (when every marker has provably entered and returned), so
    /// no peer can miss the mark and hang the work-stealing terminator.
    gc_mark_open: if (gc.enabled) std.atomic.Value(bool) else void,
    /// Installed by the Evaluator: runs `Tracer.drainParallel(worker_id)` to
    /// termination. Lets the scheduler drive the marker without importing
    /// `eval`/`gc` (same type-erasure as the heap's collect hook).
    gc_mark_hook: if (gc.enabled) ?GcMarkHook else void,

    /// `worker_count` includes the main thread (worker 0). The
    /// scheduler spawns `worker_count - 1` helper threads in `start()`;
    /// worker 0 runs on the calling thread.
    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Scheduler {
        const safe_worker_count: u8 = if (worker_count == 0) 1 else worker_count;

        // Two queues per worker — urgent (demand-driven) and speculative.
        // Plus one ready-fiber queue and one wake word. Symmetric task
        // ownership; the only thing not symmetric is who spawned which
        // thread.
        const urgent_queues = try allocator.alloc(TaskQueue, safe_worker_count);
        errdefer allocator.free(urgent_queues);
        var urgent_init: usize = 0;
        errdefer for (urgent_queues[0..urgent_init]) |*q| q.deinit(allocator);
        for (urgent_queues) |*q| {
            q.* = try TaskQueue.init(allocator, urgent_queue_capacity);
            urgent_init += 1;
        }

        const spec_queues = try allocator.alloc(TaskQueue, safe_worker_count);
        errdefer allocator.free(spec_queues);
        var spec_init: usize = 0;
        errdefer for (spec_queues[0..spec_init]) |*q| q.deinit(allocator);
        for (spec_queues) |*q| {
            q.* = try TaskQueue.init(allocator, spec_queue_capacity);
            spec_init += 1;
        }

        const cont_queues = try allocator.alloc(ContQueue, safe_worker_count);
        errdefer allocator.free(cont_queues);
        var cont_init: usize = 0;
        errdefer for (cont_queues[0..cont_init]) |*q| q.deinit(allocator);
        for (cont_queues) |*q| {
            q.* = try ContQueue.init(allocator, cont_queue_capacity);
            cont_init += 1;
        }

        const ready_queues = try allocator.alloc(ReadyQueue, safe_worker_count);
        errdefer allocator.free(ready_queues);
        for (ready_queues) |*r| r.* = ReadyQueue.init();

        const helper_thread_count: u8 = if (safe_worker_count > 1) safe_worker_count - 1 else 0;
        const threads = try allocator.alloc(std.Thread, helper_thread_count);
        errdefer allocator.free(threads);

        const wake_words = try allocator.alloc(std.atomic.Value(u32), safe_worker_count);
        errdefer allocator.free(wake_words);
        for (wake_words) |*w| w.* = .init(0);

        const worker_counters = try allocator.alloc(Counters, safe_worker_count);
        errdefer allocator.free(worker_counters);
        for (worker_counters) |*c| c.* = .{};

        const gc_worker_parked = if (gc.enabled) blk: {
            const ws = try allocator.alloc(std.atomic.Value(bool), safe_worker_count);
            for (ws) |*w| w.* = .init(false);
            break :blk ws;
        } else {};
        errdefer if (gc.enabled) allocator.free(gc_worker_parked);

        return .{
            .allocator = allocator,
            .worker_count = safe_worker_count,
            .urgent_queues = urgent_queues,
            .spec_queues = spec_queues,
            .cont_queues = cont_queues,
            .ready_queues = ready_queues,
            .threads = threads,
            .wake_words = wake_words,
            .shutdown_flag = .init(false),
            .next_victim = .init(0),
            .next_fiber_id = .init(0),
            .started = .init(false),
            .pending_tasks = .init(0),
            .spinners = .init(0),
            .cont_pending = .init(0),
            .worker_counters = worker_counters,
            .n_max_fiber_stack = .init(0),
            .n_max_vm_sp = .init(0),
            .n_idle_ns = .init(0),
            .n_busy_ns = .init(0),
            .disable_speculation = false,
            .disable_fanout = false,
            .work_first = false,
            .suppress_background = .init(false),
            .gc_stop_requested = if (gc.enabled) .init(false) else {},
            .gc_worker_parked = gc_worker_parked,
            .gc_mark_open = if (gc.enabled) .init(false) else {},
            .gc_mark_hook = if (gc.enabled) null else {},
        };
    }

    /// Toggle whether workers may start new background tasks. Set true
    /// once a demanded result is ready (see `suppress_background`); reset
    /// to false at the start of each top-level entry.
    pub inline fn setSuppressBackground(self: *Scheduler, v: bool) void {
        self.suppress_background.store(v, .release);
    }

    pub inline fn backgroundSuppressed(self: *const Scheduler) bool {
        return self.suppress_background.load(.acquire);
    }

    /// Allocate a fresh globally-unique fiber id. Called from
    /// `Worker.allocateFiber` so claimer identity doesn't depend on
    /// the worker that happened to create the fiber.
    pub fn allocFiberId(self: *Scheduler) u32 {
        return self.next_fiber_id.fetchAdd(1, .monotonic);
    }

    pub fn stats(self: *const Scheduler) Stats {
        // Sum the per-worker slots. Called at report time, after the
        // eval has quiesced, so plain loads are fine.
        var c: Counters = .{};
        for (self.worker_counters) |w| {
            c.spec_ok += w.spec_ok;
            c.spec_rej += w.spec_rej;
            c.urgent_ok += w.urgent_ok;
            c.urgent_rej += w.urgent_rej;
            c.pops += w.pops;
            c.steals += w.steals;
            c.cont_steals += w.cont_steals;
            c.cont_pushes += w.cont_pushes;
            c.parks += w.parks;
            c.scavenges += w.scavenges;
            c.sweeps += w.sweeps;
        }
        return .{
            .speculative_submitted = c.spec_ok,
            .speculative_rejected = c.spec_rej,
            .urgent_submitted = c.urgent_ok,
            .urgent_rejected = c.urgent_rej,
            .pops = c.pops,
            .steals = c.steals,
            .cont_steals = c.cont_steals,
            .cont_pushes = c.cont_pushes,
            .parks = c.parks,
            .scavenges = c.scavenges,
            .sweeps = c.sweeps,
            .max_fiber_stack_used_bytes = self.n_max_fiber_stack.load(.monotonic),
            .max_vm_sp = self.n_max_vm_sp.load(.monotonic),
            .idle_ns = self.n_idle_ns.load(.monotonic),
            .busy_ns = self.n_busy_ns.load(.monotonic),
        };
    }

    /// Worker shutdown reports the deepest fiber stack and VM sp it
    /// observed. We monotonically max into the scheduler counters so
    /// `fix inspect` can show the high-water across the whole eval.
    pub fn reportFiberHighWater(self: *Scheduler, max_fiber_stack: u64, max_vm_sp: u64) void {
        atomicMax(&self.n_max_fiber_stack, max_fiber_stack);
        atomicMax(&self.n_max_vm_sp, max_vm_sp);
    }

    /// Worker shutdown reports its accumulated idle (parked) and busy
    /// (fiber-resume) nanoseconds. Summed across all workers so the
    /// scheduler stats expose total CPU-time spent each way.
    pub fn reportWorkerTiming(self: *Scheduler, idle_ns: u64, busy_ns: u64) void {
        _ = self.n_idle_ns.fetchAdd(idle_ns, .monotonic);
        _ = self.n_busy_ns.fetchAdd(busy_ns, .monotonic);
    }

    fn atomicMax(slot: *std.atomic.Value(u64), value: u64) void {
        while (true) {
            const current = slot.load(.monotonic);
            if (value <= current) return;
            if (slot.cmpxchgWeak(current, value, .monotonic, .monotonic) == null) return;
        }
    }

    /// GC (`-Dgc`): mark all objects referenced by pending tasks across
    /// every worker's urgent + spec queues. Roots for the collector — a
    /// queued task will still be forced. STW-only.
    pub fn gcMarkPendingTasks(self: *const Scheduler, tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
        if (comptime !gc.enabled) return;
        for (self.urgent_queues) |*q| taskQueueGcMark(q, tr, heap);
        for (self.spec_queues) |*q| taskQueueGcMark(q, tr, heap);
        // Work-first continuations reference a live collection each; mark it
        // (the range's items are reachable through the list/attrs). STW-only.
        for (self.cont_queues) |*q| {
            const t = q.top.load(.monotonic);
            const b = q.bottom.load(.monotonic);
            var i = t;
            while (i != b) : (i +%= 1) tr.markObject(heap, q.items[@intCast(i & q.mask)].id);
        }
    }

    pub fn deinit(self: *Scheduler) void {
        self.shutdown();
        self.allocator.free(self.wake_words);
        for (self.urgent_queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.urgent_queues);
        for (self.spec_queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.spec_queues);
        for (self.cont_queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.cont_queues);
        self.allocator.free(self.ready_queues);
        self.allocator.free(self.threads);
        self.allocator.free(self.worker_counters);
        if (comptime gc.enabled) self.allocator.free(self.gc_worker_parked);
    }

    /// Push a woken fiber's ReadyNode onto the target worker's
    /// ready queue and nudge it. A no-op if the node is already
    /// queued — the CAS lets multiple racing wakers / runner tails
    /// safely call this for the same fiber; only the first push
    /// takes effect, the rest are dropped.
    pub fn enqueueReady(self: *Scheduler, target_worker_id: u8, node: *ReadyNode) void {
        if (node.queued.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {
            return;
        }
        self.ready_queues[target_worker_id].push(node);
        self.wakeWorker(target_worker_id);
    }

    /// Pop from the given worker's own ready queue.
    pub fn popReady(self: *Scheduler, worker_id: u8) ?*ReadyNode {
        return self.ready_queues[worker_id].pop();
    }

    /// Try to steal a ready fiber from any other worker's queue. Used
    /// when the caller's own ready + task queues are empty so a fiber
    /// woken on a busy worker still gets resumed promptly.
    pub fn stealReady(self: *Scheduler, my_worker_id: u8) ?*ReadyNode {
        if (self.worker_count < 2) return null;
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == my_worker_id) continue;
            if (self.ready_queues[idx].pop()) |n| return n;
        }
        return null;
    }

    /// Spawn helper threads. Each runs `workerFn(worker_id, sched, ctx)`
    /// where worker_id ∈ 1..worker_count-1. Worker 0 runs on the
    /// calling thread and is not spawned here.
    /// Idempotent: subsequent calls return immediately.
    pub fn start(self: *Scheduler, comptime workerFn: anytype, ctx: anytype) !void {
        if (self.started.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) return;
        if (self.threads.len == 0) return;

        var spawned: usize = 0;
        errdefer {
            self.shutdown_flag.store(true, .release);
            var i: usize = 0;
            while (i < spawned) : (i += 1) self.wakeWorker(@intCast(i + 1));
            for (self.threads[0..spawned]) |t| t.join();
            self.started.store(false, .release);
        }

        const Worker = struct {
            fn run(worker_id: u8, sched: *Scheduler, c: @TypeOf(ctx)) void {
                workerFn(worker_id, sched, c);
            }
        };

        for (self.threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{}, Worker.run, .{
                @as(u8, @intCast(i + 1)),
                self,
                ctx,
            });
            spawned += 1;
        }
    }

    /// Quiescence barrier for shutdown: each helper calls this AFTER its
    /// `run` loop exits and BEFORE it destroys its fibers, so all forcing
    /// has stopped before any fiber is freed. Without it, a helper could
    /// `Worker.deinit` (free) a still-enrolled speculative fiber while
    /// another helper, finishing its last quantum, resolves that fiber's
    /// thunk and wakes the freed fiber → use-after-free. Once every helper
    /// is past this point, no `wakeFiberWaiters` can run, so the orphaned
    /// dangling waiters are never walked.
    pub fn awaitHelpersQuiescent(self: *Scheduler) void {
        const helpers: u32 = self.worker_count - 1;
        if (helpers == 0) return;
        _ = self.stopped_helpers.fetchAdd(1, .acq_rel);
        while (self.stopped_helpers.load(.acquire) < helpers) std.atomic.spinLoopHint();
    }

    /// Signal helpers to exit and wait for them. Idempotent.
    pub fn shutdown(self: *Scheduler) void {
        if (!self.started.swap(false, .acq_rel)) return;
        // Tell any in-flight speculative force to bail at its next
        // checkpoint instead of running a possibly-huge body to completion
        // — otherwise shutdown blocks on a helper finishing dead work the
        // result never needed (see force.zig SpeculativeBail).
        self.setSuppressBackground(true);
        self.shutdown_flag.store(true, .release);
        var i: u8 = 1;
        while (i < self.worker_count) : (i += 1) self.wakeWorker(i);
        for (self.threads) |t| t.join();
    }

    /// Submit a *speculative* task. With Chase-Lev work-stealing the
    /// submitter pushes onto its own queue: lock-free SPMC `push` is
    /// the hot path. Idle helpers will steal when their own queue is
    /// empty. The previous "push to a peer" model required a MPMC
    /// mutex on the hot path; this trades that for a steal
    /// round-trip on the cold path, which has been hidden by spin-
    /// before-park (project-tier1-perf-session).
    /// Enable push-time stamping for the work-stealing flow arrows. Called
    /// once at startup when `--timeline` is active.
    pub fn setTraceFlows(self: *Scheduler, on: bool) void {
        self.trace_flows = on;
    }

    /// Enable/disable the work-first collection-force path. Set once before
    /// helpers start (from `FIX_WORK_FIRST`); read-only during eval.
    pub fn setWorkFirst(self: *Scheduler, v: bool) void {
        self.work_first = v;
    }
    pub inline fn workFirst(self: *const Scheduler) bool {
        return self.work_first;
    }

    /// Enable/configure the idle-helper thunk scavenger. Set once before
    /// helpers start (from `FIX_SCAVENGE` / `FIX_SCAV_MARGIN`).
    pub fn setScavenge(self: *Scheduler, on: bool, margin: u64) void {
        self.scavenge_enabled = on;
        self.scav_margin = margin;
    }
    pub inline fn scavengeEnabled(self: *const Scheduler) bool {
        return self.scavenge_enabled;
    }
    pub inline fn bumpScavenges(self: *Scheduler, id: u8) void {
        self.bump(id, "scavenges");
    }

    /// Enable/configure demand-sibling prefetch. Set once before helpers
    /// start (from `FIX_SIBLING` / `FIX_SIBLING_MIN` / `FIX_SIBLING_MAX`).
    pub fn setSiblingPrefetch(self: *Scheduler, on: bool, min: u32, max: u32) void {
        self.sibling_prefetch = on;
        self.sibling_min = min;
        self.sibling_max = max;
    }
    pub inline fn bumpSweeps(self: *Scheduler, id: u8) void {
        self.bump(id, "sweeps");
    }

    /// Push a work-first continuation onto `worker_id`'s own continuation deque
    /// (owner-only). Returns false when full — the caller then forces the range
    /// inline. Bumps `cont_pending` and, at the start of a burst, wakes one
    /// worker so a parked helper picks up continuation work even without other
    /// traffic (bounded, like `pushOwn`).
    pub fn pushCont(self: *Scheduler, worker_id: u8, cont: Continuation) bool {
        if (worker_id >= self.worker_count) return false;
        if (!self.cont_queues[worker_id].push(cont)) return false;
        self.bump(worker_id, "cont_pushes");
        const prev = self.cont_pending.fetchAdd(1, .release);
        if (self.worker_count > 1) {
            const wake_budget = @min(@as(u32, self.worker_count - 1), burst_wake_budget);
            if (prev < wake_budget) {
                const wake_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.worker_count);
                const target = if (wake_idx == worker_id) (wake_idx + 1) % self.worker_count else wake_idx;
                self.wakeWorker(target);
            }
        }
        return true;
    }

    /// Pop the newest continuation from `worker_id`'s own deque (LIFO), or null
    /// if empty (all were stolen / never pushed).
    pub fn popCont(self: *Scheduler, worker_id: u8) ?Continuation {
        if (worker_id >= self.worker_count) return null;
        const c = self.cont_queues[worker_id].pop() orelse return null;
        _ = self.cont_pending.fetchSub(1, .monotonic);
        return c;
    }

    /// Steal one continuation from another worker's deque (FIFO — takes the
    /// oldest/biggest exposed range for best load balancing), excluding the
    /// caller's own. Null if none available.
    pub fn stealCont(self: *Scheduler, worker_id: u8) ?Continuation {
        if (self.worker_count < 2) return null;
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == worker_id) continue;
            if (self.cont_queues[idx].steal()) |c| {
                _ = self.cont_pending.fetchSub(1, .monotonic);
                self.bump(worker_id, "cont_steals");
                return c;
            }
        }
        return null;
    }

    /// Pre-park spin probe: is there stealable continuation work outstanding?
    pub inline fn contPending(self: *const Scheduler) u32 {
        return self.cont_pending.load(.monotonic);
    }

    /// Try to become one of the `max_spinners` idle spinners. Returns
    /// false when the quota is taken — the caller should park directly
    /// instead of spin-rescanning.
    pub fn tryBeginSpin(self: *Scheduler) bool {
        const cap = maxSpinners(self.worker_count);
        var cur = self.spinners.load(.monotonic);
        while (cur < cap) {
            if (self.spinners.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic)) |actual| {
                cur = actual;
            } else return true;
        }
        return false;
    }

    pub fn endSpin(self: *Scheduler) void {
        _ = self.spinners.fetchSub(1, .release);
    }

    pub fn submit(self: *Scheduler, task: Task, submitter_id: u8) bool {
        if (self.worker_count <= 1) return false;
        if (self.disable_speculation) return false;
        const cap: u32 = @as(u32, self.worker_count - 1) * spec_backlog_per_helper;
        if (self.pending_tasks.load(.monotonic) >= cap) {
            self.bump(submitter_id, "spec_rej");
            return false;
        }
        if (self.pushOwn(self.spec_queues, task, submitter_id)) {
            self.bump(submitter_id, "spec_ok");
            return true;
        }
        self.bump(submitter_id, "spec_rej");
        return false;
    }

    /// Submit a *demand-driven* task. Goes to the urgent queue —
    /// drained before any speculative backlog so fan-out work
    /// bypasses queued speculation.
    pub fn submitUrgent(self: *Scheduler, task: Task, submitter_id: u8) bool {
        if (self.worker_count <= 1) return false;
        if (self.disable_fanout) return false;
        if (self.pushOwn(self.urgent_queues, task, submitter_id)) {
            self.bump(submitter_id, "urgent_ok");
            return true;
        }
        self.bump(submitter_id, "urgent_rej");
        return false;
    }

    fn pushOwn(self: *Scheduler, queues: []TaskQueue, task: Task, submitter_id: u8) bool {
        // Chase-Lev `push` is owner-only — submitter must own its
        // queue. Helpers always set their threadlocal worker_id;
        // non-worker callers (none today) would need their own
        // submission path.
        if (submitter_id >= self.worker_count) return false;
        // Stamp the push time only when tracing flows — the timeline anchors
        // the steal arrow's producer end here (the creating quantum). Submits
        // always happen inside a fiber quantum, so this ts falls within the
        // submitter's open span and the arrow binds cleanly.
        const push_ts: u64 = if (self.trace_flows) monotonicNs() else 0;
        if (!queues[submitter_id].push(.{ .task = task, .push_ts = push_ts })) return false;
        // Ramp worker wakeups at the start of a burst. A single submit
        // only needs one wake, but fanout submits dozens or thousands of
        // tasks back-to-back; waking only on 0 -> 1 leaves the burst at
        // the mercy of whichever helpers happened to be awake already.
        //
        // Bound this so steady backlog does not turn every submit into
        // a futex wake. These wake words also pre-signal workers that
        // are between the pre-park spin and the futex call.
        const prev = self.pending_tasks.fetchAdd(1, .release);
        const wake_budget = @min(@as(u32, self.worker_count - 1), burst_wake_budget);
        // Burst ramp (prev < budget) plus a periodic re-wake under steady
        // backlog: once prev >= budget the ramp alone never wakes anyone,
        // so a helper whose pre-park spin expired during a lull would stay
        // parked for the rest of the eval no matter how much stealable
        // work piles up (measured: helper utilization FALLS as workers
        // rise). Every 64th submit into a standing backlog re-nudges one
        // worker — bounded futex traffic, keeps parked helpers engaged.
        if (prev < wake_budget or (prev & 63) == 0) {
            const wake_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.worker_count);
            const target = if (wake_idx == submitter_id) (wake_idx + 1) % self.worker_count else wake_idx;
            self.wakeWorker(target);
        }
        return true;
    }

    /// Pop a task from `worker_id`'s own queues — urgent first, then
    /// speculative. Every worker — main and helpers — owns both
    /// queues post-F1.
    pub fn pop(self: *Scheduler, worker_id: u8) ?Task {
        if (worker_id >= self.worker_count) return null;
        const traced = self.urgent_queues[worker_id].pop() orelse
            self.spec_queues[worker_id].pop() orelse
            return null;
        _ = self.pending_tasks.fetchSub(1, .monotonic);
        self.bump(worker_id, "pops");
        return traced.task;
    }

    /// Try to steal one task from any worker's queues, urgent first
    /// then speculative, excluding the caller's own (`worker_id`).
    pub fn stealForWorker(self: *Scheduler, worker_id: u8) ?Task {
        return self.stealAnyVictimOpt(worker_id, null, null);
    }

    /// Alias for `stealForWorker` — workers use this from their drain
    /// loop. Kept as a separate name so the call site reads as
    /// "steal anything I can find," not "steal for some specific id."
    pub fn stealAny(self: *Scheduler, worker_id: u8) ?Task {
        return self.stealForWorker(worker_id);
    }

    /// Like `stealForWorker`, but reports the victim worker id and the stolen
    /// task's push timestamp so a timeline-capable caller can draw the work-
    /// stealing flow arrow anchored to the producing quantum. The scheduler
    /// stays free of the probe layer (it returns data, not events).
    pub fn stealAnyVictim(self: *Scheduler, worker_id: u8, victim: *u8, push_ts: *u64) ?Task {
        return self.stealAnyVictimOpt(worker_id, victim, push_ts);
    }

    fn stealAnyVictimOpt(self: *Scheduler, worker_id: u8, victim: ?*u8, push_ts: ?*u64) ?Task {
        if (self.worker_count < 2) return null;
        if (self.stealExcluding(self.urgent_queues, worker_id, victim, push_ts)) |t| return t;
        return self.stealExcluding(self.spec_queues, worker_id, victim, push_ts);
    }

    fn stealExcluding(self: *Scheduler, queues: []TaskQueue, exclude: u8, victim: ?*u8, push_ts: ?*u64) ?Task {
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == exclude) continue;
            if (queues[idx].steal()) |traced| {
                _ = self.pending_tasks.fetchSub(1, .monotonic);
                self.bump(exclude, "steals");
                if (victim) |v| v.* = idx;
                if (push_ts) |p| p.* = traced.push_ts;
                return traced.task;
            }
        }
        return null;
    }

    /// Park `worker_id`'s thread on its wake word until awoken or
    /// shutdown. Works for any worker, including worker 0.
    pub fn parkWorker(self: *Scheduler, worker_id: u8) void {
        self.bump(worker_id, "parks");
        const word = &self.wake_words[worker_id];
        // Try to atomically transition 0 → "waiting" (still 0; we just check
        // before sleeping). The futex syscall's "expected" param is the safe
        // way to avoid lost wakeups: if a wake arrives between our check and
        // the syscall, the syscall returns immediately.
        if (word.load(.acquire) != 0) {
            word.store(0, .release);
            return;
        }
        if (self.shutdown_flag.load(.acquire)) return;
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(
                    @ptrCast(word),
                    .{ .cmd = .WAIT, .private = true },
                    0,
                    null,
                );
            },
            else => {
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            },
        }
        // Drain any wake signal that arrived.
        word.store(0, .release);
    }

    pub fn isShutdown(self: *const Scheduler) bool {
        return self.shutdown_flag.load(.acquire);
    }

    /// Wake the given worker's wake_word and futex_wake it. Public so
    /// remote thunk-resolvers (in worker.zig's wake_fn) can nudge a
    /// worker whose suspended fiber just became resumable.
    pub fn wakeWorkerPublic(self: *Scheduler, worker_id: u8) void {
        self.wakeWorker(worker_id);
    }

    // --- GC stop-the-world barrier (`-Dgc`) ---

    /// Fast check: has a collection been requested? Called at safepoints.
    pub inline fn gcStopRequested(self: *const Scheduler) bool {
        if (comptime !gc.enabled) return false;
        return self.gc_stop_requested.load(.acquire);
    }

    /// Try to become the sole collector for this cycle. Returns true to
    /// exactly one worker (the CAS winner); losers should `gcSafepointPark`.
    pub fn gcTryBeginCollection(self: *Scheduler) bool {
        if (comptime !gc.enabled) return false;
        return self.gc_stop_requested.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null;
    }

    /// Collector (worker `collector_id`): wake every worker so parked ones
    /// loop to a safepoint, then spin until every *peer* has set its parked
    /// flag. On return the caller is the only running mutator — safe to mark
    /// and sweep.
    pub fn gcWaitAllParked(self: *Scheduler, collector_id: u8) void {
        if (comptime !gc.enabled) return;
        var id: u8 = 0;
        while (id < self.worker_count) : (id += 1) self.wakeWorker(id);
        id = 0;
        while (id < self.worker_count) : (id += 1) {
            if (id == collector_id) continue;
            while (!self.gc_worker_parked[id].load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    /// Collector: release the peers, then wait until every peer has observed
    /// the release and cleared its parked flag. The second wait is what makes
    /// this robust across back-to-back collections — no peer can still be
    /// parked (or about to re-park with a stale flag) when the next
    /// collection begins.
    pub fn gcEndCollection(self: *Scheduler, collector_id: u8) void {
        if (comptime !gc.enabled) return;
        self.gc_stop_requested.store(false, .release);
        var id: u8 = 0;
        while (id < self.worker_count) : (id += 1) {
            if (id == collector_id) continue;
            while (self.gc_worker_parked[id].load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    /// Evaluator installs the parallel-mark hook (see `GcMarkHook`) once, at
    /// startup, so parked peers can help drain the mark.
    pub fn gcSetMarkHook(self: *Scheduler, hook: GcMarkHook) void {
        if (comptime !gc.enabled) return;
        self.gc_mark_hook = hook;
    }

    /// Collector: the roots are seeded — release the parked peers to help
    /// mark. Paired with `gcCloseMark` after the mark terminates.
    pub fn gcOpenMark(self: *Scheduler) void {
        if (comptime !gc.enabled) return;
        self.gc_mark_open.store(true, .release);
    }

    /// Collector: the mark has terminated (every marker entered and returned).
    /// Close the phase so the next collection starts from a clean gate — must
    /// happen before `gcEndCollection` releases the peers.
    pub fn gcCloseMark(self: *Scheduler) void {
        if (comptime !gc.enabled) return;
        self.gc_mark_open.store(false, .release);
    }

    /// Peer (worker `worker_id`): park in the barrier until the collector
    /// finishes this cycle. Must be called only at a safepoint (native_depth
    /// 0, no un-rooted in-flight allocation) — the collector scans this
    /// worker's fibers for roots. Once the collector opens the mark, this peer
    /// helps drain the graph (marker slot == `worker_id`) instead of spinning
    /// idle; the mark stays open until termination so no peer can miss it (a
    /// missed marker would hang the work-stealing terminator).
    pub fn gcSafepointPark(self: *Scheduler, worker_id: u8) void {
        if (comptime !gc.enabled) return;
        self.gc_worker_parked[worker_id].store(true, .release);
        if (self.gc_mark_hook) |hook| {
            while (self.gc_stop_requested.load(.acquire) and
                !self.gc_mark_open.load(.acquire)) std.atomic.spinLoopHint();
            if (self.gc_mark_open.load(.acquire)) hook.help(hook.ctx, worker_id);
        }
        while (self.gc_stop_requested.load(.acquire)) std.atomic.spinLoopHint();
        self.gc_worker_parked[worker_id].store(false, .release);
    }

    fn wakeWorker(self: *Scheduler, worker_id: u8) void {
        const word = &self.wake_words[worker_id];
        // Already signalled → a prior waker's futex_wake is still in
        // flight for this word; skip the redundant syscall. (If the
        // sleeper consumed the old signal it also cleared the word, so
        // this swap would see 0 and we fall through to the wake.)
        if (word.swap(1, .release) == 1) return;
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_3arg(
                    @ptrCast(word),
                    .{ .cmd = .WAKE, .private = true },
                    1,
                );
            },
            else => {},
        }
    }
};

test "scheduler push/pop/steal work for a single worker" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 2), sched.worker_count);

    const t1: TracedTask = .{ .task = .{ .force_thunk = 7 } };
    const t2: TracedTask = .{ .task = .{ .force_thunk = 13 } };
    // Push directly to worker 1's urgent queue.
    try std.testing.expect(sched.urgent_queues[1].push(t1));
    try std.testing.expect(sched.urgent_queues[1].push(t2));

    // LIFO from owner.
    const popped = sched.pop(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 13), popped.force_thunk);

    // Steal sees the older one.
    const stolen = sched.urgent_queues[1].steal().?;
    try std.testing.expectEqual(@as(types.ObjectId, 7), stolen.task.force_thunk);

    try std.testing.expectEqual(@as(?Task, null), sched.pop(1));
}

test "scheduler.submit round-robins across workers" {
    var sched = try Scheduler.init(std.testing.allocator, 4);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 4), sched.worker_count);

    var i: types.ObjectId = 0;
    while (i < 6) : (i += 1) {
        try std.testing.expect(sched.submit(.{ .force_thunk = i }, 0));
    }

    // submit pushes to spec_queues.
    var total: u32 = 0;
    for (sched.spec_queues) |*q| {
        var count: u32 = 0;
        while (q.steal()) |_| count += 1;
        total += count;
    }
    try std.testing.expectEqual(@as(u32, 6), total);
}

test "submitUrgent bypasses the speculation backlog cap" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 2), sched.worker_count);

    // Fill the speculation cap via `submit` and confirm the next
    // speculative task is rejected.
    var i: types.ObjectId = 0;
    while (i < spec_backlog_per_helper) : (i += 1) try std.testing.expect(sched.submit(.{ .force_thunk = i }, 0));
    try std.testing.expect(!sched.submit(.{ .force_thunk = 999 }, 0));

    // `submitUrgent` should still go through — it lives on a separate
    // queue with its own capacity (`urgent_queue_capacity`).
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 100 }, 0));
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 101 }, 0));

    var drained: u32 = 0;
    for (sched.urgent_queues) |*q| while (q.steal()) |_| { drained += 1; };
    for (sched.spec_queues) |*q| while (q.steal()) |_| { drained += 1; };
    // spec_backlog_per_helper (128) speculative tasks + 2 urgent tasks
    // that bypassed the cap. This was 66 (64 + 2) back when the cap was
    // helper_count * 64; when the cap was raised to 128 (commit
    // 7ad94c5, "Raise scheduler burst headroom") the fill loop bound was
    // updated to the new `spec_backlog_per_helper` constant but this
    // expected total was left stale at the old value.
    try std.testing.expectEqual(spec_backlog_per_helper + 2, drained);
}

test "stealForWorker: each worker excludes its own queue" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 3), sched.worker_count);

    // Put one task in each of worker 1 and worker 2's urgent queues.
    try std.testing.expect(sched.urgent_queues[1].push(.{ .task = .{ .force_thunk = 100 } }));
    try std.testing.expect(sched.urgent_queues[2].push(.{ .task = .{ .force_thunk = 200 } }));
    sched.pending_tasks.store(2, .release);

    // Worker 1 must not steal from its own queue.
    const stolen_by_w1 = sched.stealForWorker(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 200), stolen_by_w1.force_thunk);

    // Worker 2 must not steal from its own queue.
    const stolen_by_w2 = sched.stealForWorker(2).?;
    try std.testing.expectEqual(@as(types.ObjectId, 100), stolen_by_w2.force_thunk);

    // No more tasks anywhere.
    try std.testing.expectEqual(@as(?Task, null), sched.stealForWorker(0));

    // Worker 0 (main) likewise excludes its own queue but can take
    // from any other.
    try std.testing.expect(sched.urgent_queues[1].push(.{ .task = .{ .force_thunk = 7 } }));
    sched.pending_tasks.store(1, .release);
    const stolen_by_main = sched.stealForWorker(0).?;
    try std.testing.expectEqual(@as(types.ObjectId, 7), stolen_by_main.force_thunk);
}

test "scheduler helpers run their loop and shut down cleanly" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();

    const Ctx = struct {
        // Indexed by worker_id; entry 0 unused since main doesn't run
        // this loop in the test (no caller is driving worker 0).
        observed: [3]std.atomic.Value(u32) = [_]std.atomic.Value(u32){ .init(0), .init(0), .init(0) },
    };
    var ctx: Ctx = .{};

    const Worker = struct {
        fn run(worker_id: u8, s: *Scheduler, c: *Ctx) void {
            while (!s.isShutdown()) {
                const task = s.pop(worker_id) orelse s.stealAny(worker_id) orelse {
                    s.parkWorker(worker_id);
                    continue;
                };
                _ = c.observed[worker_id].fetchAdd(switch (task) {
                    .force_thunk => |id| @as(u32, @intCast(id)),
                    .force_list_range, .force_attrs_sweep => 0,
                }, .acq_rel);
            }
        }
    };

    try sched.start(Worker.run, &ctx);

    try std.testing.expect(sched.submit(.{ .force_thunk = 5 }, 0));
    try std.testing.expect(sched.submit(.{ .force_thunk = 7 }, 0));

    // Spin until the total is observed. Futex wake latency can easily
    // dominate a tight spin loop, so we yield to the OS on every probe.
    var spins: u32 = 0;
    while (true) : (spins += 1) {
        const total = ctx.observed[1].load(.acquire) + ctx.observed[2].load(.acquire);
        if (total == 12) break;
        if (spins > 100_000) return error.HelpersDidNotProcess;
        std.Thread.yield() catch {};
    }

    // shutdown via deinit join
}

test "ReadyNode.queued CAS guard makes a second enqueue a no-op" {
    // Regression coverage for the double-resume race: multiple racing
    // wakers (or a waker racing a runner-tail path) may call
    // `enqueueReady` for the same node. Only the first should land the
    // node on the queue; the rest must be dropped so the same fiber is
    // never resumable from two places at once.
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(1, &node);
    try std.testing.expectEqual(@as(u8, 1), node.queued.load(.monotonic));

    // A second enqueue for the still-queued node must not push it again
    // (which would corrupt the singly-linked `next` pointer and/or hand
    // the same node to two poppers).
    sched.enqueueReady(1, &node);

    const first = sched.popReady(1);
    try std.testing.expectEqual(@as(?*ReadyNode, &node), first);
    // Queue is empty — proof there was only ever one entry.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.popReady(1));
}

test "popReady resets queued so the node can be re-enqueued later" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(1, &node);
    _ = sched.popReady(1);
    try std.testing.expectEqual(@as(u8, 0), node.queued.load(.monotonic));

    // Now that it's off-queue, a fresh enqueue must succeed again.
    sched.enqueueReady(1, &node);
    try std.testing.expectEqual(@as(u8, 1), node.queued.load(.monotonic));
    try std.testing.expectEqual(@as(?*ReadyNode, &node), sched.popReady(1));
}

test "ready queue is FIFO" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var a: ReadyNode = .{};
    var b: ReadyNode = .{};
    var c: ReadyNode = .{};
    sched.enqueueReady(1, &a);
    sched.enqueueReady(1, &b);
    sched.enqueueReady(1, &c);

    try std.testing.expectEqual(@as(?*ReadyNode, &a), sched.popReady(1));
    try std.testing.expectEqual(@as(?*ReadyNode, &b), sched.popReady(1));
    try std.testing.expectEqual(@as(?*ReadyNode, &c), sched.popReady(1));
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.popReady(1));
}

test "stealReady finds a ready fiber on another worker's queue" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(2, &node);

    // Worker 1 has no ready work of its own but can steal worker 2's.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.popReady(1));
    const stolen = sched.stealReady(1);
    try std.testing.expectEqual(@as(?*ReadyNode, &node), stolen);

    // Gone now — nothing left to steal.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.stealReady(1));
}

test "stealReady never returns the caller's own queue" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(0, &node);

    // Only worker 0 has ready work, and worker 0 is asking — must not
    // steal from itself.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.stealReady(0));

    // A worker that isn't 0 can still steal it.
    try std.testing.expectEqual(@as(?*ReadyNode, &node), sched.stealReady(1));
}

test "pop drains urgent tasks before speculative ones" {
    // Documented priority: "Pop a task from `worker_id`'s own queues —
    // urgent first, then speculative." Fan-out (demand-driven) work must
    // not sit behind a queued speculation backlog.
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    try std.testing.expect(sched.submit(.{ .force_thunk = 1 }, 1));
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 2 }, 1));

    const first = sched.pop(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 2), first.force_thunk);
    const second = sched.pop(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 1), second.force_thunk);
    try std.testing.expectEqual(@as(?Task, null), sched.pop(1));
}

test "parkWorker returns immediately when already woken" {
    // Single-threaded regression for the lost-wakeup guard: if a wake
    // arrives (word set to 1) before the worker parks, `parkWorker` must
    // observe it and return without blocking on the futex syscall.
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    sched.wakeWorkerPublic(1);
    try std.testing.expectEqual(@as(u32, 1), sched.wake_words[1].load(.monotonic));

    // Must return promptly (no real wait to service) and drain the word.
    sched.parkWorker(1);
    try std.testing.expectEqual(@as(u32, 0), sched.wake_words[1].load(.monotonic));
}

test "parkWorker returns immediately once shutdown is flagged" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    sched.shutdown_flag.store(true, .release);
    // No wake pending and shutdown is set — parkWorker must not block
    // waiting for a wake that will never come.
    sched.parkWorker(1);
}
