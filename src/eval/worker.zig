//! Worker with a per-task fiber pool.
//!
//! Each helper thread (and the main thread, persistently for the
//! evaluator's lifetime) owns a Worker. The Worker owns:
//!   - A mutex-protected free list of `.finished` fibers ready to be
//!     reset for a new task. Foreign workers push onto this when a
//!     stolen fiber finishes — see F1.4.
//!   - The set of all fibers it has ever allocated, for teardown.
//!
//! The *ready* queue lives on the scheduler, not the worker — see
//! `scheduler.zig`'s `ready_queues`. Producers (any thread waking a
//! waiter) push there; the owning worker's drain loop pops there
//! preferentially, and other workers steal from it when their own is
//! empty. This is what unpins fiber execution from the allocator
//! worker.
//!
//! There is *no* fixed pool size. A fresh fiber is allocated on demand
//! when a task arrives and no free fiber is available. Recycled fibers
//! are reset (stack pointer rewound to top, new entry/arg installed)
//! rather than reallocated, so the per-task cost is just a memcpy of
//! the trampoline address.
//!
//! Each fiber has its own VM (the bytecode value stack + frames must be
//! per-fiber; sharing one VM across fibers would corrupt state). Shared
//! pointers (heap, registry, intern, scheduler) live on the VM but
//! point at evaluator-owned tables.
//!
//! Fiber execution is *not* pinned to the allocator worker post-F1.4.
//! Any worker may pop a ready fiber and resume it on its own thread;
//! the per-fiber `in_runfiber` atomic protects against tearing down
//! a stolen-and-currently-running fiber.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const thunk_mod = @import("runtime").thunk;
const stable = @import("runtime").stable_segments;
const scheduler_mod = @import("parallel").scheduler;
const Scheduler = scheduler_mod.Scheduler;
const Task = scheduler_mod.Task;
const Continuation = scheduler_mod.Continuation;
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const vm_force = @import("../vm/force.zig");
const vm_errors = @import("../vm/errors.zig");
const fiber_mod = @import("parallel").fiber;
const InnerFiber = fiber_mod.Fiber;
const worker_id_mod = @import("runtime").worker_id;
const gc = @import("runtime").gc;
const eval_trace = @import("../support/trace.zig");
const prof = @import("../probe/prof.zig");
const timeline = @import("../probe/timeline.zig");
// Used only by the test fixture below.
const bytecode = @import("../bytecode.zig");
const InternTable = @import("runtime").intern.InternTable;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const heap_ring_size = @import("runtime").heap.SCAV_RING_SIZE;
const FileCache = @import("runtime").file_cache.FileCache;
const FetchCache = @import("runtime").fetch_cache.FetchCache;
const DerivationStore = @import("derivation").DerivationStore;

/// VM constructor injected by the embedder (eval.zig). Returns a VM
/// initialised for the given (worker_id, fiber_id). The Worker patches
/// the VM's claimer_id to match the fiber id.
pub const InitVmFn = *const fn (ctx: *anyopaque, worker_id: u8, fiber_id: u32) anyerror!VM;

/// Number of fibers pre-allocated at Worker.init time. Keeps the
/// common-case task pickup off the malloc path; the free list still
/// grows on demand past this if a workload pushes more fibers in
/// flight than the prewarm count.
pub const prewarm_fiber_count: u8 = 4;

pub const FiberState = enum(u8) {
    /// Currently running on the CPU, or about to be resumed.
    running,
    /// Yielded mid-task because a sub-thunk was `.busy`; its waiter is
    /// enrolled on that thunk's list, awaiting a wake.
    suspended,
    /// Completed a task; on the free list, available to be reset for a
    /// new task.
    free,
};

/// One in-flight evaluation. Owns a stack, a Context (via InnerFiber),
/// and a VM. Lives until the Worker is torn down — once allocated, it
/// is reused via `WorkerFiber.reset` across tasks. Post-F1.4 the fiber's
/// thread affinity is advisory: it wakes onto its allocator-worker's
/// ready queue by preference but any worker can steal it.
pub const WorkerFiber = struct {
    /// The worker that allocated this fiber. Used as a hint for which
    /// ready queue to wake into; not a binding for execution (any
    /// worker may resume this fiber once it's on a ready queue).
    worker: *Worker,
    fiber_id: u32,
    inner: InnerFiber,
    vm: VM,
    state: FiberState,
    /// Set to 1 while some worker is inside `inner.resume_()` on this
    /// fiber. The owning worker's `deinit` spin-waits on this to drop
    /// to 0 before freeing — protects against a stolen fiber being
    /// freed mid-run.
    in_runfiber: std.atomic.Value(u8),
    /// Serializes concurrent `runFiber` calls on this fiber. A wake
    /// can enqueue the `ready_node` while the fiber is mid-`resume_`;
    /// a stealer that pops it would otherwise call `resume_` on the
    /// running fiber concurrently with the in-flight resumer,
    /// swapping into the same context from two threads → garbage
    /// RIP / crash. The mutex makes those calls strictly sequential.
    /// `ReadyNode.queued` independently prevents double-enqueue, so
    /// in normal flow the mutex is uncontended.
    run_mu: stable.SpinMutex,
    /// Task currently assigned to this fiber. Read by the fiber's entry
    /// on first run; nil'd before processing so a recycled fiber sees a
    /// fresh assignment on its next reset.
    current_task: ?Task,
    /// Work-first continuation assigned to this fiber (mutually exclusive with
    /// `current_task` — set only for a stolen continuation run via
    /// `contEntry`). Nil'd before processing, like `current_task`.
    current_cont: ?Continuation = null,
    /// Timeline (`--timeline`): flow-arrow id for a STOLEN task's quantum,
    /// so the run emits a `flowIn` matching the steal's `flowOut` (→ a
    /// victim→stealer arrow). Set by `drainStep` (0 = not stolen / no arrow);
    /// `flowIn` treats 0 as "no flow", so this is inert when tracing is off.
    flow_in_id: u64 = 0,
    /// Timeline: this is the top-level DEMAND fiber (set in `runTopLevel`,
    /// cleared when it finishes). Its blocking waits on busy thunks are the
    /// critical path — recorded on the dedicated crit track (see force.zig).
    is_demand: bool = false,
    /// Free-list link. Only the owning worker manipulates this.
    next_free: ?*WorkerFiber,
    /// Ready-queue node (scheduler-owned linked list). Set by
    /// `wakeImpl`; cleared by the ready-queue pop.
    ready_node: scheduler_mod.ReadyNode,
    /// Thunk waiter — `wake_fn` recovers the parent via `@fieldParentPtr`
    /// and enqueues the fiber onto its allocator-worker's ready queue.
    waiter: thunk_mod.Waiter,
    /// Scratch trace used during speculative `force_thunk` tasks. Lets
    /// the failing thunk's error message be captured (and copied onto the
    /// thunk's cached error info) without polluting the user's shared
    /// trace. Reset before each speculative task; never observed by the
    /// user-facing code path.
    local_trace: eval_trace.Trace,

    fn wakeImpl(w: *thunk_mod.Waiter) void {
        const self: *WorkerFiber = @fieldParentPtr("waiter", w);
        self.worker.scheduler.enqueueReady(self.worker.worker_id, &self.ready_node);
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    worker_id: u8,
    init_vm_ctx: *anyopaque,
    init_vm_fn: InitVmFn,

    /// Every fiber we have ever allocated. Owned by the Worker; freed in
    /// deinit. The list is used purely for ownership/teardown — fiber
    /// ids are now globally allocated by the scheduler and don't map
    /// to positions in this list.
    fibers: std.ArrayList(*WorkerFiber),

    /// LIFO of fibers that have finished their task and are ready to be
    /// reset for a new one. Producers: any worker (a stolen fiber that
    /// finishes routes its completion back to the owning worker's free
    /// list). Consumer: this worker only.
    free_head: ?*WorkerFiber,
    free_mu: stable.SpinMutex,

    shutdown_requested: std.atomic.Value(u8),

    /// Accumulated time this worker spent parked waiting for work. Paired
    /// with `busy_ns` to compute utilisation; reported to the scheduler on
    /// `deinit` so `fix inspect` can show whether helpers are CPU-bound or
    /// starved.
    idle_ns: u64,
    /// Accumulated time this worker spent inside `runFiber` (i.e. inside
    /// `inner.resume_`). Excludes the brief pop-ready / pick-task probing
    /// — that bookkeeping is negligible relative to either bucket.
    busy_ns: u64,

    /// Scavenger scan position within main's creation ring, and the
    /// ring head observed at the last completed lap (see scavengeStep).
    scav_pos: u64 = 0,
    scav_lap_head: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        scheduler: *Scheduler,
        worker_id: u8,
        init_vm_ctx: *anyopaque,
        init_vm_fn: InitVmFn,
    ) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .worker_id = worker_id,
            .init_vm_ctx = init_vm_ctx,
            .init_vm_fn = init_vm_fn,
            .fibers = .empty,
            .free_head = null,
            .free_mu = .{},
            .shutdown_requested = .init(0),
            .idle_ns = 0,
            .busy_ns = 0,
        };
        // Prewarm: allocate a handful of fibers up front so the
        // common-case task pickup hits the free list instead of the
        // allocator. Past this count, the free list still grows on
        // demand when blocking work increases the concurrent in-flight
        // count.
        var prewarmed: u8 = 0;
        errdefer {
            for (self.fibers.items) |f| {
                f.inner.deinit(allocator);
                f.vm.deinit();
                allocator.destroy(f);
            }
            self.fibers.deinit(allocator);
        }
        while (prewarmed < prewarm_fiber_count) : (prewarmed += 1) {
            const f = try self.allocateFiber();
            self.pushFree(f);
        }
        return self;
    }

    pub fn deinit(self: *Worker) void {
        // By the time we get here `scheduler.deinit()` has already
        // joined all helpers and freed `scheduler.ready_queues`, so
        // there's no one left to steal from us and nothing safe to
        // pop. Just spin-wait for any in-flight `runFiber` on our
        // fibers to drop `in_runfiber` (which it would have done
        // before the helper exited); the loop is bounded by however
        // much yield-and-finish was in flight at shutdown.
        for (self.fibers.items) |f| {
            while (f.in_runfiber.load(.acquire) != 0) std.atomic.spinLoopHint();
        }
        var max_fiber_stack: u64 = 0;
        var max_vm_sp: u64 = 0;
        for (self.fibers.items) |f| {
            const stack_used = f.inner.maxStackUsedBytes();
            if (stack_used > max_fiber_stack) max_fiber_stack = @intCast(stack_used);
            if (f.vm.sp_high_water > max_vm_sp) max_vm_sp = f.vm.sp_high_water;
            f.inner.deinit(self.allocator);
            f.vm.deinit();
            f.local_trace.deinit();
            self.allocator.destroy(f);
        }
        self.fibers.deinit(self.allocator);
        self.scheduler.reportFiberHighWater(max_fiber_stack, max_vm_sp);
        self.flushTimingToScheduler();
        self.allocator.destroy(self);
    }

    /// Push accumulated idle/busy counters into the scheduler. Called
    /// from `parkAndAccount` (helpers naturally flush on each park) and
    /// at the end of `runTopLevel` so the main thread's work is visible
    /// to `schedulerStats()` callers before the evaluator deinits.
    fn flushTimingToScheduler(self: *Worker) void {
        if (self.idle_ns == 0 and self.busy_ns == 0) return;
        self.scheduler.reportWorkerTiming(self.idle_ns, self.busy_ns);
        self.idle_ns = 0;
        self.busy_ns = 0;
    }

    pub fn requestShutdown(self: *Worker) void {
        self.shutdown_requested.store(1, .release);
        self.nudge();
    }

    /// Park-side counterpart: poke the worker's wake word so a parked
    /// thread will wake. Any thread may call this.
    fn nudge(self: *Worker) void {
        self.scheduler.wakeWorkerPublic(self.worker_id);
    }

    fn shouldStop(self: *Worker) bool {
        return self.scheduler.isShutdown() or self.shutdown_requested.load(.acquire) != 0;
    }

    /// GC (`-Dgc`): if a collection is in progress on another worker, park
    /// in the stop-the-world barrier. Called between fibers (depth 0), where
    /// this worker holds no in-flight allocation and its fibers are the only
    /// roots the collector needs from it.
    inline fn gcSafepoint(self: *Worker) void {
        if (comptime !gc.enabled) return;
        if (self.scheduler.gcStopRequested()) self.scheduler.gcSafepointPark(self.worker_id);
    }

    /// Helper main loop. Drains until shutdown.
    pub fn run(self: *Worker) void {
        worker_id_mod.current = self.worker_id;
        if (comptime gc.enabled) vm_force.gcRegisterWorkerCaches(self.worker_id);
        while (!self.shouldStop()) {
            self.gcSafepoint();
            if (self.drainStep() catch |err| {
                std.log.err("worker {d} failed to allocate fiber: {s}", .{ self.worker_id, @errorName(err) });
                continue;
            }) continue;
            if (self.shouldStop()) break;
            self.parkAndAccount();
        }
    }

    /// Drive a custom one-shot fiber to completion. Used by every
    /// public entry on the Evaluator — top-level eval, render, force.
    /// While the entry's fiber is suspended (waiting on a `.busy`
    /// thunk), we still drain ready fibers + scheduler tasks, so the
    /// owning OS thread participates in work-stealing the same way a
    /// helper does. After the entry retires, we keep draining until
    /// every fiber on this worker is back on the free list — leaving a
    /// suspended fiber with a dangling waiter on a thunk past `deinit`
    /// would corrupt the next caller.
    pub fn runTopLevel(
        self: *Worker,
        entry: fiber_mod.EntryFn,
        arg: *anyopaque,
    ) !void {
        worker_id_mod.current = self.worker_id;
        if (comptime gc.enabled) vm_force.gcRegisterWorkerCaches(self.worker_id);
        // Each top-level entry begins able to start background work.
        self.scheduler.setSuppressBackground(false);
        const top = try self.acquireFreeFiber();
        top.current_task = null;
        top.is_demand = true; // its blocking waits are the critical path
        top.inner.reset(entry, arg);
        top.state = .running;
        self.runFiber(top);

        while (top.state != .free or self.anyFiberSuspended()) {
            self.gcSafepoint();
            // The demanded result is ready; stop pulling new background
            // tasks and just drain the in-flight suspended fibers. Without
            // this, dead speculation in the backlog keeps running and
            // extends wall time past the answer.
            if (top.state == .free) self.scheduler.setSuppressBackground(true);
            if (try self.drainStep()) continue;
            self.parkAndAccount();
        }
        // Leave `suppress_background` as-is on exit: the next top-level
        // entry resets it to false, but until then (and through shutdown)
        // it keeps in-flight speculation from outliving the demanded
        // result. (Don't clear it here, or a helper mid-force never bails.)
        // runTopLevel may exit without ever parking (helpers handle
        // background work; this thread spins through ready fibers and
        // returns). Flush so its timing is visible to schedulerStats()
        // callers before the evaluator deinits.
        self.flushTimingToScheduler();
    }

    /// One iteration of the drain loop shared by `run` and
    /// `runTopLevel`. Returns true if it did anything; false if there's
    /// no work and the caller should park.
    fn drainStep(self: *Worker) !bool {
        if (self.pickReady()) |f| {
            self.runFiber(f);
            return true;
        }
        var victim: ?u8 = null;
        var push_ts: u64 = 0;
        if (self.pickTask(&victim, &push_ts)) |task| {
            const f = try self.acquireFreeFiber();
            f.current_task = task;
            // Timeline: a stolen task's run draws a victim→stealer arrow. Anchor
            // the producer end to `push_ts` — the moment the victim *pushed* this
            // task — so the arrow originates from the quantum that created the
            // work, not whatever the victim is running now. push_ts is nonzero
            // only when flow tracing is on and the task was stolen (not popped
            // locally). Unique id → no FLOW_DUPLICATE_ID; the ts lands inside the
            // producing quantum → binds cleanly. flow_in_id carries the id to the
            // consumer end; stays 0 (no arrow) when not traced.
            f.flow_in_id = 0;
            if (victim) |vtid| {
                if (timeline.on() and push_ts != 0) {
                    const fid = timeline.nextFlowId();
                    f.flow_in_id = fid;
                    timeline.flowOutAt(.steal, fid, vtid, push_ts);
                }
            }
            f.inner.reset(slotEntry, @ptrCast(f));
            f.state = .running;
            self.runFiber(f);
            return true;
        }
        if (self.pickCont()) |cont| {
            const f = try self.acquireFreeFiber();
            f.current_cont = cont;
            f.current_task = null;
            f.flow_in_id = 0;
            f.inner.reset(contEntry, @ptrCast(f));
            f.state = .running;
            self.runFiber(f);
            return true;
        }
        if (try self.scavengeStep()) return true;
        return false;
    }

    /// Lowest-priority idle work (`FIX_SCAVENGE`): pre-force old, still-
    /// unresolved thunks from MAIN's creation ring whose body chunk has
    /// PROVEN expensive on main's demand path (`vm_force.scavChunkHot`).
    /// Mechanizes the age-at-force probe finding (~half of main's
    /// on-chain cycles sit in thunks that existed ≥0.6ms before main
    /// demanded them) without evaluating the whole lazy graph: cheap and
    /// never-demanded thunks fail the hot-chunk filter. The scan re-laps
    /// the ring window as new chunks turn hot. Worker 0 never scavenges —
    /// a long speculative force there would add latency to the demand
    /// fiber's wakes.
    fn scavengeStep(self: *Worker) !bool {
        if (self.worker_id == 0) return false;
        const sched = self.scheduler;
        // Cap the scavenging helpers (FIX_SCAV_WORKERS): at w=16/32,
        // letting every idle helper scavenge amplifies wasted work and
        // allocator contention into a large regression; at w=8 all 7
        // helpers scavenging measured best.
        if (self.worker_id > sched.scav_workers) return false;
        if (!sched.scavengeEnabled()) return false;
        if (sched.backgroundSuppressed()) return false;
        if (self.fibers.items.len == 0) return false;
        const heap = self.fibers.items[0].vm.heap;
        const local = &heap.worker_locals[0];
        const head = local.scav_head.load(.acquire);
        const margin = sched.scav_margin;
        if (head <= margin) return false;
        const hi = head - margin;
        const window_lo = head -| (heap_ring_size - 1024);
        var pos = @max(self.scav_pos, window_lo);
        if (pos >= hi) {
            // Lap complete. Restart only after meaningful ring growth
            // (new thunks and possibly newly-hot chunks) — re-lapping on
            // every single creation would busy-spin the scan.
            if (head < self.scav_lap_head + 8192) return false;
            self.scav_lap_head = head;
            pos = window_lo;
        }
        // Bound the skip scan per drain step so a cold backlog can't
        // starve the park path.
        var budget: u32 = 2048;
        while (pos < hi and budget > 0) : ({
            pos += 1;
            budget -= 1;
        }) {
            const id = @atomicLoad(types.ObjectId, &local.scav_ring[@intCast(pos & (heap_ring_size - 1))], .acquire);
            const th = heap.getThunkAssumeValid(id);
            if (th.future.state.load(.monotonic) != @intFromEnum(thunk_mod.FutureState.unresolved)) continue;
            if (th.targetKind() != .bytecode) continue;
            // Racy read of the target union (the thunk may resolve
            // concurrently): a torn chunk_id at worst misclassifies
            // hotness; the claim CAS inside the force is authoritative.
            if (!vm_force.scavShouldTake(th.payload.target.bytecode.chunk_id)) continue;
            self.scav_pos = pos + 1;
            const f = try self.acquireFreeFiber();
            f.current_task = .{ .force_thunk = id };
            f.flow_in_id = 0;
            f.inner.reset(slotEntry, @ptrCast(f));
            f.state = .running;
            sched.bumpScavenges(self.worker_id);
            self.runFiber(f);
            return true;
        }
        self.scav_pos = pos;
        return false;
    }

    /// Resume the fiber and update bookkeeping based on what state it
    /// returned in. The fiber either yielded (still `.suspended`) or
    /// finished its work (entry returned → reset state to `.free` and
    /// push onto free list).
    ///
    /// `run_mu` serializes concurrent runners for this fiber. If a
    /// wake arrives mid-`resume_` and the wake-side enqueueReady
    /// pushes our `ready_node`, a stealer popping it ends up here
    /// too — the mutex blocks them until the current resume completes,
    /// so `resume_` never overlaps with another `resume_` on the same
    /// fiber. In normal (uncontended) execution the lock/unlock is
    /// two atomic ops.
    /// Timeline (`-Dtimeline`): open the run quantum labelled with the task it
    /// processes, so worker 0's track shows WHAT each quantum computes (not just
    /// "run"). Rich `args` carry the thunk/list id for click-through.
    fn timelineQuantumBegin(f: *WorkerFiber) void {
        var buf: [80]u8 = undefined;
        var locbuf: [128]u8 = undefined;
        if (f.current_task) |task| {
            // Label the quantum with the Nix source location it forces (so the
            // track reads "run: modules.nix:412", not just "force-thunk"), then
            // the thunk/list id as click-through args.
            const loc = timelineTaskLoc(f, &locbuf);
            switch (task) {
                .force_thunk => |id| timeline.beginSubj(.run, if (loc.isEmpty()) timeline.Subject.lit("force-thunk") else loc, f.fiber_id, std.fmt.bufPrint(&buf, "\"thunk\":{d}", .{id}) catch ""),
                .force_list_range => |r| timeline.beginArgs(.run, "force-list", f.fiber_id, std.fmt.bufPrint(&buf, "\"list\":{d},\"off\":{d},\"len\":{d}", .{ r.list_id, r.offset, r.len }) catch ""),
            }
            // Consumer end of the work-stealing arrow — inside this quantum so
            // the arrow lands on it. No-op unless this task was stolen (id != 0).
            timeline.flowIn(.steal, f.flow_in_id, worker_id_mod.current);
        } else {
            const loc = timelineResumeLoc(f);
            timeline.beginSubj(.run, if (loc.isEmpty()) timeline.Subject.lit("resume") else loc, f.fiber_id, "");
        }
    }

    /// Best-effort "basename:line" for the task this quantum forces. Returns ""
    /// when unresolvable — a non-bytecode thunk, a thunk already resolved (its
    /// bare target union is dead, guarded by the state check), a missing source
    /// map, or a list-range (no single chunk). Only called when tracing is on.
    fn timelineTaskLoc(f: *WorkerFiber, buf: []u8) timeline.Subject {
        const task = f.current_task orelse return .{};
        return switch (task) {
            // Shared rich label (source loc / mapAttrs / builtins.* / applied
            // fn / …); empty when unresolvable or already resolved → the quantum
            // keeps its generic "force-thunk" name.
            .force_thunk => |id| vm_force.thunkLabel(&f.vm, id, buf),
            .force_list_range => .{},
        };
    }

    /// Best-effort "basename:line" for the frame a resumed fiber re-enters.
    fn timelineResumeLoc(f: *WorkerFiber) timeline.Subject {
        if (f.vm.frames_len == 0) return .{};
        const span = vm_errors.sourceSpanForFrame(f.vm.frames[f.vm.frames_len - 1]) orelse return .{};
        const file_id = span.file orelse return .{};
        return timeline.Subject.src(file_id, span.line);
    }

    /// Timeline: sample heap cursors, RSS, and scheduler state as counter tracks
    /// (time-series graphs in Perfetto) so memory growth, the speculation flood,
    /// and steal activity are visible over the eval and correlatable with GC
    /// pauses. Throttled to ~1ms; RSS is a /proc read.
    fn sampleTimelineCounters(f: *WorkerFiber) void {
        if (!timeline.shouldSample(1_000_000)) return;
        const heap = f.vm.heap;
        var buf: [192]u8 = undefined;
        timeline.counter("heap_slots", std.fmt.bufPrint(&buf, "\"objects\":{d},\"values\":{d},\"attrs\":{d}", .{ heap.objects.count(), heap.values.count(), heap.attrs.count() }) catch return);
        // RSS (peak so far) + total bytes reserved across the object stores — the
        // memory-growth curve, correlatable with the speculation backlog below.
        var rbuf: [96]u8 = undefined;
        timeline.counter("rss_mb", std.fmt.bufPrint(&rbuf, "\"rss\":{d},\"reserved\":{d}", .{ gc.peakRssBytes() >> 20, heap.totalReservedBytes() >> 20 }) catch return);
        // Scheduler: live task backlog (the speculation flood as it happens) +
        // cumulative speculation submitted/rejected and steals. Together with
        // rss_mb this is the spec-flood-vs-RSS "money chart".
        const s = f.vm.scheduler;
        var sbuf: [96]u8 = undefined;
        timeline.counter("sched_backlog", std.fmt.bufPrint(&sbuf, "\"pending\":{d}", .{s.pending_tasks.load(.monotonic)}) catch return);
        var pbuf: [160]u8 = undefined;
        const st = s.stats();
        timeline.counter("spec", std.fmt.bufPrint(&pbuf, "\"submitted\":{d},\"rejected\":{d},\"steals\":{d}", .{ st.speculative_submitted, st.speculative_rejected, st.steals }) catch return);
    }

    fn runFiber(self: *Worker, f: *WorkerFiber) void {
        f.run_mu.lock();
        defer f.run_mu.unlock();

        const t0 = nanoMonotonic();
        // Runtime-gated: when tracing is off this is one predictable branch and
        // we open the cheap unlabelled quantum; when on, sample counters + label
        // the quantum with the task it runs (both do arg formatting / a /proc
        // read, so they stay behind `on()`).
        if (timeline.on()) {
            sampleTimelineCounters(f);
            timelineQuantumBegin(f);
        } else {
            timeline.begin(.run, "", f.fiber_id);
        }
        // Creation-context flag: creations during this quantum belong to
        // the resumed fiber's context (demand chain vs. speculative work).
        // `in_speculation` is fiber-state (saved on its VM across yields);
        // the heap flag is per worker THREAD, so refresh it on every
        // resume. `forceValueSpeculative` keeps it in sync mid-quantum.
        f.vm.heap.setSpecCtx(f.vm.in_speculation);
        f.in_runfiber.store(1, .release);
        f.inner.resume_();
        f.in_runfiber.store(0, .release);
        timeline.end(.run);
        const t1 = nanoMonotonic();
        if (t1 > t0) self.busy_ns += t1 - t0;
        switch (f.inner.state) {
            .finished => {
                // Entry returned cleanly. Recycle onto the fiber's
                // *owning* worker's free list — `f.worker` is the
                // allocator, which may differ from `self` if we
                // resumed a stolen fiber. Nudge the owning worker so
                // its `runTopLevel` loop observes the completion (it
                // may be parked waiting on this very fiber).
                f.is_demand = false; // clear before recycle (else a reused fiber mislabels)
                f.state = .free;
                f.worker.pushFree(f);
                if (f.worker != self) f.worker.nudge();
            },
            .suspended => {
                // Yielded inside the body (force.busy enrolled on a
                // waiter list). If the waiter has already resolved,
                // wake_fn will have enqueued our ready_node — the
                // `ReadyNode.queued` CAS gives us idempotent enqueue,
                // so it's fine if multiple paths try to push.
            },
            .ready, .running => unreachable,
        }
    }

    /// Park on the worker's wake word and account the time toward
    /// idle_ns. `parkWorker` is the only call that blocks the thread
    /// when there's no work; everything else (pop, pick, fiber resume)
    /// is counted as work-in-progress. Flushes local timing counters
    /// to the scheduler first — parking is the only voluntary CPU
    /// yield, so it's the natural batching point for the atomic add.
    ///
    /// Pre-park spin polls the shared `pending_tasks` counter — a
    /// single relaxed atomic load — so a submission burst landing in
    /// the next few µs catches helpers before they pay a futex pair.
    /// Polling drainStep directly would do per-queue CAS probes whose
    /// contention destroys cache coherence across 32 workers; reading
    /// one shared counter is much cheaper.
    fn parkAndAccount(self: *Worker) void {
        const SPIN_ITERATIONS: u32 = 1024;
        // Cap the concurrent idle spinners: at high worker counts the
        // spin-and-rescan churn from every idle helper (O(N) queue
        // probes per rescan) burns the SMT siblings of busy workers.
        // Helpers past the quota park immediately; submit-side wakes
        // re-engage them when work arrives. Worker 0 always spins —
        // it's the demand thread and its wake latency is critical.
        const spin_allowed = self.worker_id == 0 or self.scheduler.tryBeginSpin();
        if (spin_allowed) {
            defer if (self.worker_id != 0) self.scheduler.endSpin();
            var i: u32 = 0;
            while (i < SPIN_ITERATIONS) : (i += 1) {
                // When background work is suppressed (result ready, draining the
                // tail), the queued backlog won't be pulled — don't treat it as
                // available work and busy-spin on it.
                if (!self.scheduler.backgroundSuppressed() and
                    (self.scheduler.pending_tasks.load(.monotonic) > 0 or self.scheduler.contPending() > 0)) return;
                // Un-scanned scavengeable ring backlog counts as available
                // work for a scavenging helper (see scavengeStep's cap).
                if (self.worker_id != 0 and self.worker_id <= self.scheduler.scav_workers and self.scheduler.scavengeEnabled() and
                    !self.scheduler.backgroundSuppressed() and self.fibers.items.len > 0)
                {
                    const head = self.fibers.items[0].vm.heap.worker_locals[0].scav_head.load(.monotonic);
                    if (head > self.scheduler.scav_margin and
                        (self.scav_pos < head - self.scheduler.scav_margin or head >= self.scav_lap_head + 8192)) return;
                }
                if (self.shouldStop()) return;
                if (comptime gc.enabled) if (self.scheduler.gcStopRequested()) return; // park in GC barrier via run loop
                std.atomic.spinLoopHint();
            }
        }

        self.flushTimingToScheduler();
        const t0 = nanoMonotonic();
        const pt = prof.start(.park_main_worker);
        timeline.begin(.park, "", 0);
        self.scheduler.parkWorker(self.worker_id);
        timeline.end(.park);
        prof.end(.park_main_worker, pt);
        const t1 = nanoMonotonic();
        if (t1 > t0) self.idle_ns += t1 - t0;
    }

    /// Pick a task from own queues (not stolen → `victim` stays null) or steal
    /// one (→ `victim.*` = the victim worker id, for the timeline flow arrow).
    fn pickTask(self: *Worker, victim: *?u8, push_ts: *u64) ?Task {
        // Once a top-level result is ready, don't start new background
        // work — only drive already-suspended fibers to completion. Bounds
        // the dead-speculation tail (see Scheduler.suppress_background).
        if (self.scheduler.backgroundSuppressed()) return null;
        if (self.scheduler.pop(self.worker_id)) |t| return t;
        var v: u8 = 0;
        var pts: u64 = 0;
        if (self.scheduler.stealAnyVictim(self.worker_id, &v, &pts)) |t| {
            victim.* = v;
            push_ts.* = pts;
            return t;
        }
        return null;
    }

    /// Steal a work-first continuation from another worker (this worker's own
    /// continuations are reclaimed inline by `forceRangeWorkFirst`'s pop-back,
    /// never here). Suppressed once a top-level result is ready, like
    /// `pickTask` — no need to start new parallel collection work past the answer.
    fn pickCont(self: *Worker) ?Continuation {
        if (self.scheduler.backgroundSuppressed()) return null;
        return self.scheduler.stealCont(self.worker_id);
    }

    /// Pop a fiber from the free list (LIFO — best cache locality), or
    /// allocate a fresh one if the list is empty. The new fiber has its
    /// own stack + VM; the caller must `reset` it with the actual entry.
    fn acquireFreeFiber(self: *Worker) !*WorkerFiber {
        self.free_mu.lock();
        if (self.free_head) |head| {
            self.free_head = head.next_free;
            head.next_free = null;
            self.free_mu.unlock();
            return head;
        }
        self.free_mu.unlock();
        return self.allocateFiber();
    }

    fn allocateFiber(self: *Worker) !*WorkerFiber {
        const fiber_id = self.scheduler.allocFiberId();
        const f = try self.allocator.create(WorkerFiber);
        errdefer self.allocator.destroy(f);

        var vm = try self.init_vm_fn(self.init_vm_ctx, self.worker_id, fiber_id);
        errdefer vm.deinit();

        var inner = try InnerFiber.init(self.allocator, InnerFiber.min_stack_bytes, slotEntry, undefined);
        errdefer inner.deinit(self.allocator);

        f.* = .{
            .worker = self,
            .fiber_id = fiber_id,
            .inner = inner,
            .vm = vm,
            .state = .free,
            .in_runfiber = .init(0),
            .run_mu = .{},
            .current_task = null,
            .current_cont = null,
            .next_free = null,
            .ready_node = .{},
            .waiter = .{ .wake_fn = WorkerFiber.wakeImpl },
            .local_trace = eval_trace.Trace.init(self.allocator),
        };
        f.vm.claimer_id = thunk_mod.makeClaimer(fiber_id);
        // Speculative work captures only the throw message for sticky
        // caching; skip frame-stack allocation on the hot path.
        f.local_trace.frames_disabled = true;

        try self.fibers.append(self.allocator, f);
        return f;
    }

    fn pushFree(self: *Worker, f: *WorkerFiber) void {
        self.free_mu.lock();
        defer self.free_mu.unlock();
        f.next_free = self.free_head;
        self.free_head = f;
    }

    /// Pop a fiber from this worker's ready queue, or steal one from
    /// another worker's queue if our own is empty.
    fn pickReady(self: *Worker) ?*WorkerFiber {
        if (self.scheduler.popReady(self.worker_id)) |node| return readyNodeToFiber(node);
        if (self.scheduler.stealReady(self.worker_id)) |node| return readyNodeToFiber(node);
        return null;
    }

    fn readyNodeToFiber(node: *scheduler_mod.ReadyNode) *WorkerFiber {
        return @fieldParentPtr("ready_node", node);
    }

    fn countSuspended(self: *Worker) usize {
        var c: usize = 0;
        for (self.fibers.items) |f| if (f.state == .suspended) { c += 1; };
        return c;
    }

    fn anyFiberSuspended(self: *Worker) bool {
        for (self.fibers.items) |f| {
            if (f.state == .suspended) return true;
        }
        return false;
    }
};

/// CLOCK_MONOTONIC reading in nanoseconds. Used to bucket worker time
/// between fiber-resume and futex-park. Linux-only fast path (vDSO);
/// other platforms return 0, which makes the counters stay at 0 —
/// `fix inspect` will show 0s and the user can read off the platform
/// instead of getting bogus numbers.
fn nanoMonotonic() u64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
            const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
            const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
            return sec * std.time.ns_per_s + nsec;
        },
        else => return 0,
    }
}

/// Standard fiber entry: run one task to completion and return.
/// On entry, the worker has already set `current_task` and reset the
/// fiber. The fiber's claimer_id was set at allocation; VM stack/frame
/// state is from the previous task — reset before doing anything.
fn slotEntry(arg: *anyopaque) void {
    const f: *WorkerFiber = @ptrCast(@alignCast(arg));
    f.vm.sp = 0;
    f.vm.frames_len = 0;
    const task = f.current_task orelse return;
    f.current_task = null;
    // Speculative work must NOT touch the user-facing error trace. A
    // speculative `throw` (legitimate in a Nix expression's branch that
    // wouldn't have been selected by demand-driven eval) otherwise
    // pollutes the shared trace and surfaces as the user-visible error
    // message, masking the actual root cause.
    //
    // We still need a place to capture the error message so sticky-
    // error caching on the thunk preserves it. Point the VM trace at
    // this fiber's local scratch trace for the duration of the work;
    // `forceThunkImpl` reads from it on failure and copies the message
    // onto the thunk.
    const saved_trace = f.vm.trace;
    f.local_trace.clear();
    f.vm.trace = &f.local_trace;
    defer f.vm.trace = saved_trace;
    switch (task) {
        .force_thunk => |thunk_id| {
            const v = Value.thunk(thunk_id);
            _ = vm_force.forceValueSpeculative(&f.vm, v) catch {};
        },
        .force_list_range => |range| {
            // The list's value range is a RAW store slice held across
            // `forceValueSpeculative` — which can drive a GC collection. We
            // nulled `current_task` above, so nothing else roots this list.
            // Rooting keeps the list *object* live, but the copying nursery
            // collector EVACUATES (moves) its value range to to-space, so a
            // slice captured before the force dangles even though the object
            // survives. Re-fetch each element from the id per iteration
            // (`getListItem` re-derives the range from the moved object) so we
            // always read the live copy. Zero cost without -Dgc.
            // NON-MOVING GC: `rootKeep` keeps the list live and ranges never
            // relocate/are-swept while rooted, so the slice is stable across the
            // element forces — hold it, no per-element re-fetch.
            const gc_roots = vm_force.rootsBegin(&f.vm);
            defer vm_force.rootsEnd(&f.vm, gc_roots);
            vm_force.rootKeep(&f.vm, Value.list(range.list_id));
            const items = f.vm.heap.getList(range.list_id) catch return;
            const end = @min(@as(usize, range.offset) + @as(usize, range.len), items.len);
            var i: usize = range.offset;
            while (i < end) : (i += 1) {
                if (!items[i].isThunk()) continue;
                _ = vm_force.forceValueSpeculative(&f.vm, items[i]) catch {};
            }
        },
    }
}

/// Fiber entry for a STOLEN work-first continuation. Mirrors `slotEntry`'s
/// setup (reset VM stack, point at the local scratch trace so a speculative
/// throw can't pollute the user trace) then forces the continuation's range,
/// re-splitting onto this worker's own cont deque.
fn contEntry(arg: *anyopaque) void {
    const f: *WorkerFiber = @ptrCast(@alignCast(arg));
    f.vm.sp = 0;
    f.vm.frames_len = 0;
    const cont = f.current_cont orelse return;
    f.current_cont = null;
    const saved_trace = f.vm.trace;
    f.local_trace.clear();
    f.vm.trace = &f.local_trace;
    defer f.vm.trace = saved_trace;
    vm_force.forceContinuation(&f.vm, cont);
}

// ---- Tests ----

const testing = std.testing;

test "Worker basic init/deinit" {
    var sched = try Scheduler.init(testing.allocator, 2);
    defer sched.deinit();

    const TestCtx = struct {
        registry: bytecode.ChunkRegistry,
        intern: InternTable,
        heap: ObjectHeap,
        files: FileCache,
        fetchers: FetchCache,
        derivations: DerivationStore,
        sched: *Scheduler,
        arena: std.heap.ArenaAllocator,
        opcode_counts: if (vm_mod.opcode_profile_enabled) vm_mod.OpcodeCounts else void,

        fn initVm(ctx: *anyopaque, _: u8, _: u32) anyerror!VM {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return VM.init(
                self.arena.allocator(),
                &self.registry,
                &self.intern,
                &self.heap,
                &self.files,
                &self.fetchers,
                &self.derivations,
                self.sched,
                null,
                null,
                null,
                if (comptime vm_mod.thunks_log_enabled) null else {},
                null,
                Value.null_val,
                if (comptime vm_mod.opcode_profile_enabled) &self.opcode_counts else {},
            );
        }
    };

    var ctx: TestCtx = .{
        .registry = try bytecode.ChunkRegistry.init(testing.allocator),
        .intern = try InternTable.init(testing.allocator),
        .heap = try ObjectHeap.init(testing.allocator, 2),
        .files = FileCache.init(testing.allocator),
        .fetchers = FetchCache.init(testing.allocator),
        .derivations = DerivationStore.init(testing.allocator),
        .sched = &sched,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .opcode_counts = if (vm_mod.opcode_profile_enabled) [_]u64{0} ** bytecode.opcode.count else {},
    };
    defer {
        ctx.registry.deinit();
        ctx.intern.deinit();
        ctx.heap.deinit();
        ctx.files.deinit();
        ctx.fetchers.deinit();
        ctx.derivations.deinit();
        ctx.arena.deinit();
    }

    const worker = try Worker.init(testing.allocator, &sched, 1, &ctx, TestCtx.initVm);
    defer worker.deinit();

    try testing.expectEqual(@as(u8, 1), worker.worker_id);
    // Prewarmed fibers: all on the free list, none active yet.
    try testing.expectEqual(@as(usize, prewarm_fiber_count), worker.fibers.items.len);
    try testing.expect(worker.free_head != null);
    try testing.expect(sched.popReady(1) == null);
    // Fiber ids are now globally allocated by the scheduler — no fixed
    // mapping to position in the worker's fibers list. Each fiber's
    // claimer_id should equal `makeClaimer(fiber_id)`.
    for (worker.fibers.items) |f| {
        try testing.expectEqual(thunk_mod.makeClaimer(f.fiber_id), f.vm.claimer_id);
        try testing.expectEqual(FiberState.free, f.state);
    }
    // All fiber ids should be distinct.
    for (worker.fibers.items, 0..) |f, i| {
        for (worker.fibers.items[i + 1 ..]) |g| {
            try testing.expect(f.fiber_id != g.fiber_id);
        }
    }
}
