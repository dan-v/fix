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
const future_mod = @import("runtime").future;
const sync = @import("base").sync;
const arena_mod = @import("base").arena;
const clock = @import("base").clock;
const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const Task = scheduler_mod.Task;
const vm_mod = @import("../../vm/context.zig");
const vm_driver = @import("../../vm/driver.zig").driver;
const VM = vm_mod.VM;
const exec_context = @import("context.zig");
const ExecutionContext = exec_context.ExecutionContext;
const vm_force = @import("../../vm/force.zig");
const vm_errors = @import("../../vm/errors.zig");
const fiber_mod = @import("base").fiber;
const InnerFiber = fiber_mod.Fiber;
const worker_id_mod = @import("base").worker_id;
const mem_tag = @import("runtime").mem_tag;
const gc = @import("runtime").gc;
const eval_trace = @import("../../observ.zig").trace;
const eval_progress = @import("../../observ.zig").progress;
const prof = @import("../../probe.zig").prof;
const timeline = @import("../../probe.zig").timeline;

/// VM constructor injected by the embedder (eval.zig). Returns a VM
/// initialised for the given (worker_id, fiber_id). The Worker repoints
/// the VM's `ctx` at the fiber's own ExecutionContext (which carries the
/// fiber's claim id). `scratch` is the fiber's
/// per-fiber arena — the VM's run-path allocations land there and are
/// swept wholesale when the fiber is recycled (see `recycleScratch`).
pub const InitVmFn = *const fn (ctx: *anyopaque, worker_id: u8, fiber_id: u32, scratch: std.mem.Allocator) anyerror!VM;

/// Number of fibers pre-allocated at Worker.init time. Keeps the
/// common-case task pickup off the malloc path; the free list still
/// grows on demand past this if a workload pushes more fibers in
/// flight than the prewarm count.
pub const prewarm_fiber_count: u8 = 4;

/// Pre-park spin duration in `parkAndAccount`. This is the measured production
/// value; keeping it fixed avoids turning a scheduler invariant into a runtime
/// experiment surface.
const spin_iterations: u32 = 1024;

/// Fiber cost/benefit census (piggybacks on `-Dprof-main`; see
/// `prof.FiberLocal`). Comptime-gated so the default build's structs
/// and hot paths are untouched.
const census_on = fiber_mod.census_enabled and prof.enabled;

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
    /// Fiber-scoped execution identity (see `eval/workers/context.zig`): the
    /// claim id (permanent, baked at allocation) plus the demand-role
    /// fields (`is_demand` + the demand-only progress handles — set by
    /// `runTopLevel` on the top fiber, reset when the fiber recycles).
    /// `vm.ctx` points here, and every nested VM created while running on
    /// this fiber shares the pointer — identity is structural, never
    /// re-dressed per VM.
    ctx: ExecutionContext,
    /// Per-fiber scratch arena backing `vm`'s run-path allocations
    /// (builtin temp buffers, drv hashing, equality scratch — ~490 MB of
    /// transient traffic per NixOS eval). Arena semantics are load-bearing:
    /// run paths free best-effort and error/suspend paths abandon
    /// allocations. Reset (bounded retention) each time the fiber is
    /// recycled onto the free list — a never-reset arena retained ~240 MB
    /// (w=1) / ~380 MB (w=8) of dead interleaved pages.
    scratch: arena_mod.ArenaAllocator,
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
    run_mu: sync.SpinMutex,
    /// Task currently assigned to this fiber. Read by the fiber's entry
    /// on first run; nil'd before processing so a recycled fiber sees a
    /// fresh assignment on its next reset.
    current_task: ?Task,
    /// Non-null only for a member of a multi-entry demand run. Published from
    /// `runFiber` after the entry has fully returned and the fiber is recycled,
    /// so the driver can safely tear evaluation state down at the count limit.
    top_completion: ?*std.atomic.Value(usize) = null,
    /// Timeline (`--timeline`): flow-arrow id for a STOLEN task's quantum,
    /// so the run emits a `flowIn` matching the steal's `flowOut` (→ a
    /// victim→stealer arrow). Set by `drainStep` (0 = not stolen / no arrow);
    /// `flowIn` treats 0 as "no flow", so this is inert when tracing is off.
    flow_in_id: u64 = 0,
    /// Fiber census: suspensions since the current task started. Updated
    /// and consumed under `run_mu` (runFiber's state switch), reset before
    /// the fiber is recycled.
    census_suspends: if (census_on) u32 else void = if (census_on) 0 else {},
    /// Task census: submission class of `current_task`/`current_cont`
    /// (spec/novel/urgent force_thunk, range, sweep, cont).
    /// Set alongside the task assignment; read by the fiber entry.
    census_class: if (census_on) prof.TaskClass else void = if (census_on) .spec_thunk else {},
    /// Which queue `current_task` came from. Set alongside the task
    /// assignment; the fiber entry uses it to arm the band-scoped creation
    /// budget — urgent tasks are never budgeted.
    current_lane: scheduler_mod.Lane = .spec,
    /// Free-list link. Only the owning worker manipulates this.
    next_free: ?*WorkerFiber,
    /// Stack pages were madvised away while parked on the free list
    /// (see Worker.sweepFreeStacks). Cleared on reuse. Guarded by the
    /// owning worker's `free_mu`.
    stack_released: bool = false,
    /// Ready-queue node (scheduler-owned linked list). Set by
    /// `wakeImpl`; cleared by the ready-queue pop.
    ready_node: scheduler_mod.ReadyNode,
    /// Thunk waiter — `wake_fn` recovers the parent via `@fieldParentPtr`
    /// and enqueues the fiber onto its allocator-worker's ready queue.
    /// Reused for IO waits too (a fiber never waits on a thunk and an IO
    /// completion at the same time).
    waiter: future_mod.Waiter,
    /// Completion cell for a daemon/fetch I/O offload (see `workers.zig`).
    /// Lives on the (stable) WorkerFiber rather than the fiber's stack because
    /// the IO thread touches it inside `publish()` *after* the woken fiber may
    /// have already resumed and reused its stack frame. Re-`initClaimed`ed
    /// before each offload; idle otherwise.
    io_future: future_mod.Future,
    /// Scratch trace used during speculative `force_thunk` tasks. Lets
    /// the failing thunk's error message be captured (and copied onto the
    /// thunk's cached error info) without polluting the user's shared
    /// trace. Reset before each speculative task; never observed by the
    /// user-facing code path.
    local_trace: eval_trace.Trace,

    fn wakeImpl(w: *future_mod.Waiter) void {
        const self: *WorkerFiber = @fieldParentPtr("waiter", w);
        self.worker.scheduler.enqueueReady(self.worker.worker_id, &self.ready_node);
    }

    fn yieldImpl(context: *anyopaque) void {
        const self: *WorkerFiber = @ptrCast(@alignCast(context));
        self.state = .suspended;
        fiber_mod.Fiber.yield();
        self.state = .running;
    }

    /// Sweep the per-fiber scratch arena when the fiber goes back on the
    /// free list. Safe exactly here: the fiber is `.finished` (its stack
    /// unwound — no pending defers reference scratch) and its VM is idle
    /// at depth 0. Retains one page-sized chunk so the next task's small
    /// scratch doesn't immediately re-alloc.
    fn recycleScratch(self: *WorkerFiber) void {
        self.vm.onScratchReset();
        _ = self.scratch.reset(.{ .retain_with_limit = 64 * 1024 });
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
    /// Depth of the `free_head` list. Drives the stack-release policy:
    /// fibers parked deeper than the prewarm count are spike overflow
    /// (a burst of blocking work grew the pool) and give their stack
    /// pages back to the OS — 8 MiB dirty reservations otherwise stay
    /// resident forever, and 99.9% of tasks are served by the first
    /// (still-warm) `prewarm_fiber_count` fibers.
    free_count: u32,
    free_mu: sync.SpinMutex,

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

    /// Fiber cost/benefit census accumulator (`-Dprof-main` only; see
    /// `prof.FiberLocal`). Owner-thread writes only; flushed to the
    /// global totals on park and at drain-loop exit.
    census: if (census_on) prof.FiberLocal else void = if (census_on) prof.FiberLocal{} else {},

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
            .free_count = 0,
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
                mem_tag.vma.unregisterRegion(f.inner.stack.ptr);
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
        vm_force.gcUnregisterWorkerCaches(self.worker_id);
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
        var max_vm_sp: u64 = 0;
        for (self.fibers.items) |f| {
            if (f.vm.sp_high_water > max_vm_sp) max_vm_sp = f.vm.sp_high_water;
            mem_tag.vma.unregisterRegion(f.inner.stack.ptr);
            f.inner.deinit(self.allocator);
            f.vm.deinit();
            f.scratch.deinit();
            f.local_trace.deinit();
            self.allocator.destroy(f);
        }
        self.fibers.deinit(self.allocator);
        self.scheduler.reportVmStackHighWater(max_vm_sp);
        self.flushTimingToScheduler();
        self.allocator.destroy(self);
    }

    /// Push accumulated idle/busy counters into the scheduler. Called
    /// from `parkAndAccount` (helpers naturally flush on each park) and
    /// at the end of `runTopLevel` so the main thread's work is visible
    /// to `schedulerStats()` callers before the evaluator deinits.
    fn flushTimingToScheduler(self: *Worker) void {
        if (comptime census_on) prof.fiberFlush(&self.census, self.worker_id == 0);
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

    /// GC: if a collection is in progress on another worker, park
    /// in the stop-the-world barrier. Called between fibers (depth 0), where
    /// this worker holds no in-flight allocation and its fibers are the only
    /// roots the collector needs from it.
    inline fn gcSafepoint(self: *Worker) void {
        if (self.scheduler.gcStopRequested()) self.scheduler.gcSafepointPark(self.worker_id);
    }

    /// Helper main loop. Drains until shutdown.
    pub fn run(self: *Worker) void {
        worker_id_mod.current = self.worker_id;
        worker_id_mod.is_worker = true;
        vm_force.gcRegisterWorkerCaches(self.worker_id);
        defer vm_force.gcUnregisterWorkerCaches(self.worker_id);
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
        /// The demand-only progress handles to dress the top fiber's
        /// execution context with (null fields when progress isn't drawn).
        /// Supplied fresh per entry by the embedder, so a sink installed
        /// between runs (the repl) needs no worker-side bookkeeping.
        demand: exec_context.DemandRole,
    ) !void {
        worker_id_mod.current = self.worker_id;
        worker_id_mod.is_worker = true;
        vm_force.gcRegisterWorkerCaches(self.worker_id);
        // Each top-level entry begins able to start background work.
        self.scheduler.setSuppressBackground(false);
        const tc: u64 = if (comptime census_on) fiber_mod.censusNow() else 0;
        const top = try self.acquireFreeFiber();
        top.current_task = null;
        // Dress the top fiber's execution context — the single-entry
        // demand-role write site. Its blocking waits are the critical path,
        // and the demand-only progress handles exist only here (helpers' ctxs stay
        // null, which is what makes an off-demand stage emit
        // inexpressible). `runFiber`'s finished arm resets the role.
        top.ctx.is_demand = true;
        top.ctx.progress_stage = demand.progress_stage;
        top.ctx.progress_wait = demand.progress_wait;
        top.inner.reset(entry, arg);
        if (comptime census_on) {
            self.census.cy_dispatch += fiber_mod.censusNow() -| tc;
            self.census.tasks += 1;
            prof.fiberLiveInc();
        }
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

    pub const TopLevelEntry = struct {
        entry: fiber_mod.EntryFn,
        arg: *anyopaque,
    };

    /// Drive several independent demanded entries at once. Each gets its own
    /// demand fiber and is queued onto a different worker when possible. The
    /// multi-entry path deliberately omits the single-writer stage/progress-wait
    /// handles; concurrent demand fibers still report through the thread-safe
    /// span channel.
    pub fn runTopLevels(self: *Worker, entries: []const TopLevelEntry) !void {
        if (entries.len == 0) return;
        worker_id_mod.current = self.worker_id;
        worker_id_mod.is_worker = true;
        vm_force.gcRegisterWorkerCaches(self.worker_id);
        self.scheduler.setSuppressBackground(false);

        var completed: std.atomic.Value(usize) = .init(0);
        const tops = try self.allocator.alloc(*WorkerFiber, entries.len);
        defer self.allocator.free(tops);

        var acquired: usize = 0;
        errdefer for (tops[0..acquired]) |top| self.pushFree(top);
        for (tops) |*slot| {
            slot.* = try self.acquireFreeFiber();
            acquired += 1;
        }

        for (entries, tops) |entry, top| {
            top.current_task = null;
            top.top_completion = &completed;
            top.ctx.is_demand = true;
            top.ctx.parallel_demand = true;
            top.ctx.progress_stage = null;
            top.ctx.progress_wait = null;
            top.inner.reset(entry.entry, entry.arg);
            if (comptime census_on) {
                self.census.tasks += 1;
                prof.fiberLiveInc();
            }
            top.state = .running;
        }

        // Publish only after every entry owns a fiber, so a very small first
        // input cannot recycle its fiber into a later slot before setup ends.
        for (tops, 0..) |top, i| {
            const target: u8 = @intCast(i % @as(usize, self.scheduler.worker_count));
            self.scheduler.enqueueReady(target, &top.ready_node);
        }

        while (completed.load(.acquire) != entries.len or self.anyFiberSuspended()) {
            self.gcSafepoint();
            if (completed.load(.acquire) == entries.len) self.scheduler.setSuppressBackground(true);
            if (self.drainStep() catch false) continue;
            self.parkAndAccount();
        }
        self.scheduler.setSuppressBackground(true);
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
        var lane: scheduler_mod.Lane = .spec;
        if (self.pickTask(&victim, &push_ts, &lane)) |task| {
            const tc: u64 = if (comptime census_on) fiber_mod.censusNow() else 0;
            const f = try self.acquireFreeFiber();
            f.current_task = task;
            f.current_lane = lane;
            if (comptime census_on) f.census_class = switch (task) {
                .force_thunk => switch (lane) {
                    .urgent => .urgent_thunk,
                    .novel => .novel_thunk,
                    .spec => .spec_thunk,
                },
                .force_list_range => .list_range,
                .force_attrs_sweep => .attrs_sweep,
                .force_attrs_range => .attrs_range,
                .import_prefetch => .import_prefetch,
                .readdir_prefetch => .readdir_prefetch,
            };
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
            if (comptime census_on) {
                self.census.cy_dispatch += fiber_mod.censusNow() -| tc;
                self.census.tasks += 1;
                prof.fiberLiveInc();
            }
            f.state = .running;
            self.runFiber(f);
            return true;
        }
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
    /// Timeline (`--timeline`): open the run quantum labelled with the task it
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
                .force_attrs_sweep => |id| timeline.beginArgs(.run, "sweep-attrs", f.fiber_id, std.fmt.bufPrint(&buf, "\"attrs\":{d}", .{id}) catch ""),
                .force_attrs_range => |r| timeline.beginArgs(.run, "force-attrs", f.fiber_id, std.fmt.bufPrint(&buf, "\"attrs\":{d},\"off\":{d},\"len\":{d}", .{ r.attrs_id, r.offset, r.len }) catch ""),
                .import_prefetch => |path_id| timeline.beginArgs(.run, "import-prefetch", f.fiber_id, std.fmt.bufPrint(&buf, "\"path\":{d}", .{path_id}) catch ""),
                .readdir_prefetch => |r| timeline.beginArgs(.run, "readdir-prefetch", f.fiber_id, std.fmt.bufPrint(&buf, "\"dir\":{d},\"off\":{d},\"len\":{d}", .{ r.dir, r.offset, r.len }) catch ""),
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
            .force_list_range, .force_attrs_sweep, .force_attrs_range, .import_prefetch, .readdir_prefetch => .{},
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
    /// pauses. Throttled to ~1ms; RSS is a /proc read. The progress indicator
    /// surfaces the same numbers via its own sampler (`Evaluator.readMetrics`).
    fn sampleTimelineCounters(f: *WorkerFiber) void {
        if (!timeline.shouldSample(1_000_000)) return;
        const heap = f.vm.heap;
        var buf: [192]u8 = undefined;
        timeline.counter("heap_slots", std.fmt.bufPrint(&buf, "\"objects\":{d},\"values\":{d},\"attrs\":{d}", .{ heap.objects.count(), heap.values.count(), heap.attrs.count() }) catch return);
        // RSS (peak so far) + total bytes reserved across the object stores — the
        // memory-growth curve, correlatable with the speculation backlog below.
        // Hugetlb-backed bytes are invisible to RSS (base/hugetlb.zig), so they
        // get their own series; rss + hugetlb ≈ the true footprint curve.
        var rbuf: [128]u8 = undefined;
        timeline.counter("rss_mb", std.fmt.bufPrint(&rbuf, "\"rss\":{d},\"reserved\":{d},\"hugetlb\":{d}", .{
            gc.peakRssBytes() >> 20,
            heap.totalReservedBytes() >> 20,
            @import("base").hugetlb.mappedBytes() >> 20,
        }) catch return);
        // Scheduler: live task backlog (the speculation flood as it happens) +
        // cumulative speculation submitted/rejected and steals. Together with
        // rss_mb this is the spec-flood-vs-RSS "money chart".
        const s = f.vm.scheduler;
        var sbuf: [96]u8 = undefined;
        timeline.counter("sched_backlog", std.fmt.bufPrint(&sbuf, "\"pending\":{d}", .{s.pending_tasks.v.load(.monotonic)}) catch return);
        var pbuf: [160]u8 = undefined;
        const st = s.stats();
        timeline.counter("spec", std.fmt.bufPrint(&pbuf, "\"submitted\":{d},\"rejected\":{d},\"steals\":{d}", .{ st.speculative_submitted, st.speculative_rejected, st.steals }) catch return);
    }

    fn runFiber(self: *Worker, f: *WorkerFiber) void {
        // Census: seed the swap-in origin BEFORE any per-resume machinery
        // (run_mu, timeline, spec-ctx) so `cy_in` covers the whole
        // dispatcher→body path; the fiber-side hook (trampoline / yield
        // return) closes the window. Symmetric `cy_out` closes at the end
        // of this function's bookkeeping.
        if (comptime census_on) fiber_mod.census_pre_swap = fiber_mod.censusNow();
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
        // Creation-budget re-base: the per-worker `thunks_created` counter
        // advanced while this fiber was parked (other fibers' creations)
        // and may belong to a different worker now (migration). Re-base
        // the snapshot so only creations made INSIDE this fiber's own run
        // slices are charged against its budget (see VM.spec_create_left).
        if (f.vm.spec_create_left != vm_mod.no_spec_budget)
            vm_force.specCreateArm(&f.vm, f.vm.spec_create_left);
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
                const top_completion = f.top_completion;
                f.top_completion = null;
                f.ctx.resetRole(); // clear the demand role before recycle (else a reused fiber mislabels)
                if (comptime census_on) {
                    self.census.finished += 1;
                    if (f.census_suspends > 0) {
                        self.census.finished_suspended += 1;
                        const lg: usize = 63 - @clz(@as(u64, f.census_suspends));
                        self.census.susp_hist[@min(lg, self.census.susp_hist.len - 1)] += 1;
                        f.census_suspends = 0;
                    }
                    prof.fiberLiveDec();
                }
                f.state = .free;
                f.recycleScratch();
                f.worker.pushFree(f);
                if (top_completion) |counter| _ = counter.fetchAdd(1, .release);
                if (f.worker != self) f.worker.nudge();
            },
            .suspended => {
                // Yielded inside the body (force.busy enrolled on a
                // waiter list). If the waiter has already resolved,
                // wake_fn will have enqueued our ready_node — the
                // `ReadyNode.queued` CAS gives us idempotent enqueue,
                // so it's fine if multiple paths try to push.
                if (comptime census_on) {
                    self.census.suspend_events += 1;
                    f.census_suspends += 1;
                }
            },
            .ready, .running => unreachable,
        }
        if (comptime census_on) {
            self.census.cy_out += fiber_mod.censusNow() -| fiber_mod.census_exit_swap;
            self.census.n_out += 1;
            self.census.cy_in += fiber_mod.census_in_cy;
            self.census.n_in += fiber_mod.census_in_n;
            fiber_mod.census_in_cy = 0;
            fiber_mod.census_in_n = 0;
            self.census.resumes += 1;
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
        const iterations = spin_iterations;
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
            while (i < iterations) : (i += 1) {
                // When background work is suppressed (result ready, draining the
                // tail), the queued backlog won't be pulled — don't treat it as
                // available work and busy-spin on it.
                if (!self.scheduler.backgroundSuppressed() and
                    self.scheduler.takableWork(self.worker_id)) return;
                if (self.shouldStop()) return;
                if (self.scheduler.gcStopRequested()) return; // park in GC barrier via run loop
                std.atomic.spinLoopHint();
            }
        }

        self.flushTimingToScheduler();
        // About to sleep: idle time is free — give parked overflow fibers'
        // dirty stacks back to the OS (never on the task-completion path;
        // measured ~107K madvise calls/eval there, ~2µs each).
        self.sweepFreeStacks();
        const t0 = nanoMonotonic();
        const pt = prof.start(.park_main_worker);
        timeline.begin(.park, "", 0);
        self.scheduler.parkWorker(self.worker_id);
        timeline.end(.park);
        prof.end(.park_main_worker, pt);
        const t1 = nanoMonotonic();
        if (t1 > t0) self.idle_ns += t1 - t0;
    }

    /// Release the stacks of free-list fibers beyond the prewarm depth
    /// (spike overflow, parked with dirty 8 MiB reservations — spikes
    /// reach ~196 live fibers, so up to ~1.5 GB of once-touched pages).
    /// Runs only when this worker is about to park. Candidates are
    /// collected under `free_mu` but madvised outside it — safe because
    /// the free list's consumer is THIS worker only (see `free_head`),
    /// and it is here, not popping; concurrent `pushFree` from other
    /// workers only prepends. The `stack_released` flag (cleared on
    /// reuse) makes each park-cycle release a fiber at most once.
    fn sweepFreeStacks(self: *Worker) void {
        var batch: [64]*WorkerFiber = undefined;
        var n: usize = 0;
        self.free_mu.lock();
        var cursor = self.free_head;
        var depth: u32 = 0;
        while (cursor) |f| : (cursor = f.next_free) {
            depth += 1;
            if (depth <= prewarm_fiber_count) continue; // keep the hot head warm
            if (f.stack_released) continue;
            f.stack_released = true;
            batch[n] = f;
            n += 1;
            if (n == batch.len) break;
        }
        self.free_mu.unlock();
        for (batch[0..n]) |f| {
            // MADV_FREE won the release-policy experiment: it avoids eagerly
            // faulting zero pages back in when an overflow fiber is reused.
            f.inner.releaseStackPages(retained_stack_bytes, true);
        }
    }

    /// Pick a task from own queues (not stolen → `victim` stays null) or steal
    /// one (→ `victim.*` = the victim worker id, for the timeline flow arrow).
    fn pickTask(self: *Worker, victim: *?u8, push_ts: *u64, lane: *scheduler_mod.Lane) ?Task {
        // Once a top-level result is ready, don't start new background
        // work — only drive already-suspended fibers to completion. Bounds
        // the dead-speculation tail (see Scheduler.suppress_background).
        if (self.scheduler.backgroundSuppressed()) return null;
        if (self.scheduler.popLane(self.worker_id, lane)) |t| return t;
        var v: u8 = 0;
        var pts: u64 = 0;
        if (self.scheduler.stealAnyVictimLane(self.worker_id, &v, &pts, lane)) |t| {
            victim.* = v;
            push_ts.* = pts;
            return t;
        }
        return null;
    }

    /// Pop a fiber from the free list (LIFO — best cache locality), or
    /// allocate a fresh one if the list is empty. The new fiber has its
    /// own stack + VM; the caller must `reset` it with the actual entry.
    fn acquireFreeFiber(self: *Worker) !*WorkerFiber {
        self.free_mu.lock();
        if (self.free_head) |head| {
            self.free_head = head.next_free;
            self.free_count -= 1;
            head.next_free = null;
            // Reused: its stack will re-dirty; a later idle sweep may
            // release it again.
            head.stack_released = false;
            self.free_mu.unlock();
            if (comptime census_on) self.census.free_hits += 1;
            return head;
        }
        self.free_mu.unlock();
        if (comptime census_on) self.census.allocs += 1;
        return self.allocateFiber();
    }

    fn allocateFiber(self: *Worker) !*WorkerFiber {
        const fiber_id = self.scheduler.allocFiberId();
        const f = try self.allocator.create(WorkerFiber);
        errdefer self.allocator.destroy(f);

        f.* = .{
            .worker = self,
            .fiber_id = fiber_id,
            .inner = undefined,
            .vm = undefined,
            // Claim identity is baked once, for the fiber's life; the
            // demand-role fields start (and recycle back to) cleared.
            .ctx = .{ .claimer_id = future_mod.makeClaimer(fiber_id) },
            .scratch = arena_mod.ArenaAllocator.init(self.allocator),
            .state = .free,
            .in_runfiber = .init(0),
            .run_mu = .{},
            .current_task = null,
            .top_completion = null,
            .next_free = null,
            .ready_node = .{},
            .waiter = .{ .wake_fn = WorkerFiber.wakeImpl },
            .io_future = future_mod.Future.initClaimed(future_mod.makeClaimer(fiber_id)),
            .local_trace = eval_trace.Trace.init(self.allocator),
        };
        f.ctx.park = .{ .waiter = &f.waiter, .context = f, .yield_fn = WorkerFiber.yieldImpl };
        errdefer f.scratch.deinit();
        errdefer f.local_trace.deinit();

        // The VM allocates through the fiber's arena, so the arena must
        // sit at its final address (`f.scratch`) before the VM captures it.
        f.vm = try self.init_vm_fn(self.init_vm_ctx, self.worker_id, fiber_id, f.scratch.allocator());
        errdefer f.vm.deinit();
        // Priority inheritance (`FIX_RESCUE`): expose this fiber's rescue flag
        // under its id so a peer blocking on its work can promote it.
        self.scheduler.registerRescue(fiber_id, &f.vm.demand_rescue);

        f.inner = try InnerFiber.init(self.allocator, InnerFiber.min_stack_bytes, slotEntry, undefined);
        // Bake the native-stack guard limit now that the fiber owns its stack.
        // The stack grows DOWN from the high end of `inner.stack`, so the guard
        // trips when the SP descends within `stack_guard_margin` of the low
        // (base) address. Permanent for the fiber's life (the stack never moves),
        // like `claimer_id`. See `exec_context.stack_limit` / `forceThunkImpl`.
        f.ctx.stack_limit = @intFromPtr(f.inner.stack.ptr) + exec_context.stack_guard_margin;
        // RSS attribution: the owner (this worker) registers the fiber stack —
        // fiber.zig no longer does it, keeping the primitive free of the tag
        // taxonomy. Registered when the stack is committed, unregistered when
        // it is munmapped (both teardown paths + this errdefer).
        mem_tag.vma.registerRegion(f.inner.stack.ptr, f.inner.stack.len, .fiber_stack);
        errdefer {
            mem_tag.vma.unregisterRegion(f.inner.stack.ptr);
            f.inner.deinit(self.allocator);
        }

        // Bind the VM to this fiber's identity: the constructor hands out
        // the neutral default; from here on the VM (and every nested VM
        // created while running on this fiber) reads through `f.ctx`.
        f.vm.ctx = &f.ctx;
        // Speculative work captures only the throw message for sticky
        // caching; skip frame-stack allocation on the hot path.
        f.local_trace.frames_disabled = true;

        try self.fibers.append(self.allocator, f);
        return f;
    }

    /// How much of a released fiber's stack stays resident: covers the
    /// dispatch machinery + a shallow task so a re-used overflow fiber
    /// rarely faults at all.
    const retained_stack_bytes: usize = 64 * 1024;

    fn pushFree(self: *Worker, f: *WorkerFiber) void {
        self.free_mu.lock();
        defer self.free_mu.unlock();
        f.next_free = self.free_head;
        self.free_head = f;
        self.free_count += 1;
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
        for (self.fibers.items) |f| if (f.state == .suspended) {
            c += 1;
        };
        return c;
    }

    fn anyFiberSuspended(self: *Worker) bool {
        for (self.fibers.items) |f| {
            if (f.state == .suspended) return true;
        }
        return false;
    }
};

/// CLOCK_MONOTONIC reading used to bucket worker run and park time.
const nanoMonotonic = clock.monotonicNs;

/// Standard fiber entry: run one task to completion and return.
/// On entry, the worker has already set `current_task` and reset the
/// fiber. The fiber's claimer_id was set at allocation; VM stack/frame
/// state is from the previous task — reset before doing anything.
fn slotEntry(arg: *anyopaque) void {
    const f: *WorkerFiber = @ptrCast(@alignCast(arg));
    f.vm.sp = 0;
    f.vm.frames_len = 0;
    // Priority inheritance (`FIX_RESCUE`): a rescue flag applies only to the
    // task it was granted for — clear it at each task boundary.
    f.vm.demand_rescue.store(0, .monotonic);
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
    if (comptime census_on) {
        var live: u64 = 0;
        var total: u64 = 0;
        var busy = false;
        censusScanTask(f, task, &live, &total, &busy);
        const t0 = fiber_mod.censusNow();
        runTask(f, task);
        prof.taskCensusRecord(f.census_class, live, total, busy, fiber_mod.censusNow() -| t0);
    } else {
        runTask(f, task);
    }
}

/// Task census pre-scan: how much unresolved work does this task find on
/// arrival? `total` = thunk-typed items it covers; `live` = those still
/// `.unresolved`; `busy` = a force_thunk target currently `.evaluating`
/// (owned by another fiber — this task can only spin/enroll). Racy-benign:
/// a state can flip between the scan and the force; the census is
/// approximate by design.
fn censusScanTask(f: *WorkerFiber, task: Task, live: *u64, total: *u64, busy: *bool) void {
    const heap = f.vm.heap;
    const unresolved = @intFromEnum(future_mod.FutureState.unresolved);
    switch (task) {
        .force_thunk => |thunk_id| {
            total.* = 1;
            const st = heap.getThunkAssumeValid(thunk_id).future.state.load(.monotonic);
            if (st == unresolved) live.* = 1;
            if (st == @intFromEnum(future_mod.FutureState.evaluating)) busy.* = true;
        },
        .force_list_range => |range| {
            const items = heap.getList(range.list_id) catch return;
            const end = @min(@as(usize, range.offset) + @as(usize, range.len), items.len);
            var i: usize = range.offset;
            while (i < end) : (i += 1) {
                if (!items[i].isThunk()) continue;
                total.* += 1;
                if (heap.getThunkAssumeValid(items[i].asObjectId()).future.state.load(.monotonic) == unresolved) live.* += 1;
            }
        },
        .force_attrs_sweep => |attrs_id| {
            const entries = heap.getAttrs(attrs_id) catch return;
            for (entries) |entry| {
                if (!entry.value.isThunk()) continue;
                total.* += 1;
                if (heap.getThunkAssumeValid(entry.value.asObjectId()).future.state.load(.monotonic) == unresolved) live.* += 1;
            }
        },
        .force_attrs_range => |range| {
            const entries = heap.getAttrs(range.attrs_id) catch return;
            const end = @min(@as(usize, range.offset) + @as(usize, range.len), entries.len);
            var i: usize = range.offset;
            while (i < end) : (i += 1) {
                if (!entries[i].value.isThunk()) continue;
                total.* += 1;
                if (heap.getThunkAssumeValid(entries[i].value.asObjectId()).future.state.load(.monotonic) == unresolved) live.* += 1;
            }
        },
        // Import registry / FileCache state isn't scanned here — count the
        // task itself.
        .import_prefetch, .readdir_prefetch => total.* = 1,
    }
}

/// Untrusted-band admission for the creation budget: true when this
/// speculative task's root thunk is an unresolved BYTECODE thunk whose
/// chunk sits below the trusted size (`ChunkSlot.spec_band_small`).
/// Racy-benign union read, same pattern as `force.sweepMemberAdmissible`:
/// the thunk may resolve concurrently; a torn read at worst arms (or
/// skips) a budget on a task whose force takes the resolved fast path
/// anyway. `registry.slot` is bounds-guarded, so a stale chunk id cannot
/// fault.
fn specRootBandSmall(f: *WorkerFiber, thunk_id: types.ObjectId) bool {
    const th = f.vm.heap.getThunkAssumeValid(thunk_id);
    if (th.future.state.load(.monotonic) != @intFromEnum(future_mod.FutureState.unresolved)) return false;
    if (th.targetKind() != .bytecode) return false;
    // Racy union read (see `Thunk.targetLeadingRacy`): a peer may resolve the
    // thunk between the state load above and here, flipping the payload to
    // `.result`. Reinterpret the raw storage so safe builds don't panic on the
    // torn arm; a stale chunk id is bounds-guarded by `registry.slot`.
    const slot = f.vm.registry.slot(th.targetLeadingRacy(types.ChunkId)) orelse return false;
    return slot.spec_band_small;
}

/// Run one scheduled task's body (the entry's dispatch switch, factored
/// out so the census wrapper can bracket it without duplicating arms).
fn runTask(f: *WorkerFiber, task: Task) void {
    switch (task) {
        .force_thunk => |thunk_id| {
            // Bounded spec-lane cascade: arm the per-task creation budget for
            // speculative/novel force_thunk tasks, so one wrong guess can't
            // evaluate an unbounded never-demanded subgraph (the sub-256-
            // combinator junk cascade). Bail is a transient thunk reset;
            // resolved sub-thunks are kept — same semantics the sibling
            // sweeps have shipped with. Urgent (demand-adjacent) tasks
            // stay unbounded. The band budget applies only to
            //    tasks whose ROOT chunk is below the trusted size
            //    (`spec_band_small`) — the family whose execution
            //    cascades. Trusted (≥256) roots run unbudgeted: bailing
            //    useful deep speculation discards its claim spine, and the
            //    demand-side redo measured +12% w=8 wall.
            if (f.current_lane != .urgent) {
                const band = f.vm.scheduler.config.spec_band_budget;
                if (band != 0 and specRootBandSmall(f, thunk_id))
                    vm_force.specCreateArm(&f.vm, band);
            }
            defer {
                f.vm.spec_create_left = vm_mod.no_spec_budget;
                f.vm.spec_budget = vm_mod.no_spec_budget;
            }
            const v = Value.thunk(thunk_id);
            _ = vm_force.forceValueSpeculative(&f.vm, v) catch |err| {
                if (err == error.SpeculativeBail)
                    f.vm.scheduler.noteSpecBail(worker_id_mod.current);
            };
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
            // always read the live copy.
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
        .force_attrs_sweep => |attrs_id| {
            // Demand-sibling prefetch (`FIX_SIBLING`): force every still-
            // unresolved thunk member of one attrset. Rooting mirrors the
            // list case above; the submitter only ever sweeps plain
            // `.attrs` objects, so `getAttrs` never flattens here. Members
            // resolved since submission fall through the resolved fast
            // path in `forceValueSpeculative` — the sweep is idempotent.
            const gc_roots = vm_force.rootsBegin(&f.vm);
            defer vm_force.rootsEnd(&f.vm, gc_roots);
            vm_force.rootKeep(&f.vm, Value.attrs(attrs_id));
            const entries = f.vm.heap.getAttrs(attrs_id) catch return;
            const log = f.vm.scheduler.config.sibling_log;
            const objs_before: u32 = if (log) f.vm.heap.objects.count() else 0;
            var lbuf: [160]u8 = undefined;
            var rbuf: [224]u8 = undefined;
            if (log) {
                // Identify the sweep target: first attr name + first
                // unresolved member's body label (best-effort).
                var label: []const u8 = "?";
                for (entries) |entry| {
                    if (!entry.value.isThunk()) continue;
                    const subj = vm_force.thunkLabel(&f.vm, entry.value.asObjectId(), &lbuf);
                    if (subj.isEmpty()) continue;
                    label = if (subj.file != 0)
                        (std.fmt.bufPrint(&rbuf, "{s}:{d}", .{ std.fs.path.basename(f.vm.intern.get(subj.file)), subj.line }) catch "?")
                    else
                        subj.text;
                    break;
                }
                std.debug.print("sweep attrs={d} n={d} t_us={d} worker={d} claimer={d} first_attr={s} member={s}\n", .{
                    attrs_id,             entries.len,
                    vm_force.diagNowUs(), worker_id_mod.current,
                    f.ctx.claimer_id,     f.vm.intern.get(entries[0].name),
                    label,
                });
            }
            // Arm the per-member cascade bounds (claimed forces AND thunk
            // creations); restore before the fiber is recycled for tasks
            // that must run unbounded.
            defer {
                f.vm.spec_budget = vm_mod.no_spec_budget;
                f.vm.spec_create_left = vm_mod.no_spec_budget;
            }
            for (entries) |entry| {
                if (!entry.value.isThunk()) continue;
                if (!vm_force.sweepMemberAdmissible(&f.vm, entry.value.asObjectId())) continue;
                f.vm.spec_budget = f.vm.scheduler.config.sibling_claim_budget;
                vm_force.specCreateArm(&f.vm, f.vm.scheduler.config.sibling_budget);
                if (log) {
                    // Per-member cascade attribution: this worker's own
                    // thunk-creation counter around the force. Best-effort —
                    // a mid-force fiber migration garbles one sample.
                    const before = f.vm.heap.currentLocal().thunks_created;
                    const subj = vm_force.thunkLabel(&f.vm, entry.value.asObjectId(), &lbuf);
                    _ = vm_force.forceValueSpeculative(&f.vm, entry.value) catch {};
                    const created = f.vm.heap.currentLocal().thunks_created -| before;
                    if (created > 2000) {
                        const mlabel: []const u8 = if (subj.file != 0)
                            (std.fmt.bufPrint(&rbuf, "{s}:{d}", .{ std.fs.path.basename(f.vm.intern.get(subj.file)), subj.line }) catch "?")
                        else if (subj.text.len != 0) subj.text else "?";
                        std.debug.print("sweep-member attrs={d} attr={s} member={s} created={d} t_us={d} claimer={d}\n", .{
                            attrs_id,             f.vm.intern.get(entry.name), mlabel, created,
                            vm_force.diagNowUs(), f.ctx.claimer_id,
                        });
                    }
                    continue;
                }
                _ = vm_force.forceValueSpeculative(&f.vm, entry.value) catch {};
            }
            if (log) {
                std.debug.print("sweep attrs={d} done: t_us={d} heap_growth={d}\n", .{
                    attrs_id, vm_force.diagNowUs(), f.vm.heap.objects.count() -| objs_before,
                });
            }
        },
        .force_attrs_range => |range| {
            // Batched attrs fan-out — the attrs analogue of
            // `force_list_range` above (attrs are a positional slice in
            // the heap, and the NON-MOVING GC note there applies
            // identically: rooting keeps the entry range stable).
            const gc_roots = vm_force.rootsBegin(&f.vm);
            defer vm_force.rootsEnd(&f.vm, gc_roots);
            vm_force.rootKeep(&f.vm, Value.attrs(range.attrs_id));
            const entries = f.vm.heap.getAttrs(range.attrs_id) catch return;
            const end = @min(@as(usize, range.offset) + @as(usize, range.len), entries.len);
            var i: usize = range.offset;
            while (i < end) : (i += 1) {
                if (!entries[i].value.isThunk()) continue;
                _ = vm_force.forceValueSpeculative(&f.vm, entries[i].value) catch {};
            }
        },
        .import_prefetch => |path_id| {
            // Speculative import prefetch (FIX_IMPORT_PREFETCH): resolve,
            // parse, compile, and top-level-eval the file, populating the
            // deduplicated import registry (imports.Registry) so the demand
            // fiber later hits `.already_resolved` (or joins the in-flight
            // Future) instead of paying parse+compile on the critical
            // chain. Errors are swallowed here; deterministic failures are
            // cached on the entry and replay identically on real demand.
            const host = f.vm.import_host orelse return;
            const path = f.vm.intern.get(path_id);
            _ = host.import_value(host.context, path, 1) catch {};
        },
        .readdir_prefetch => |r| {
            // Speculative readDir-children prefetch (FIX_READDIR_PREFETCH):
            // warm the FileCache with the directory-kind children in
            // [offset, offset+len) of the parent's listing. The parent
            // read is a warm cache hit (the submitter just populated it);
            // each child read is exactly the getdents the demand fiber
            // would do — errors are swallowed and NOT cached, so a real
            // demand read replays them identically.
            const files = f.vm.files;
            const parent = f.vm.intern.get(r.dir);
            const entries = files.readDir(parent) catch return;
            const end = @min(entries.len, @as(usize, r.offset) + r.len);
            if (r.offset >= end) return;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            for (entries[r.offset..end]) |ent| {
                if (ent.kind != .directory) continue;
                const child = std.fmt.bufPrint(&buf, "{s}/{s}", .{ parent, ent.name }) catch continue;
                const listing = files.readDir(child) catch continue;
                // Pre-intern the child's entry names: the demand-side
                // builtins.readDir interns every name it returns (~21K
                // for pkgs/by-name — measured as the residual chain cost
                // once the getdents itself is prefetched). Warm inserts
                // here turn those into read-mostly lookups. The intern
                // table is append-only and global, so this is invisible
                // beyond timing.
                for (listing) |le| _ = f.vm.intern.intern(le.name) catch break;
            }
        },
    }
}
