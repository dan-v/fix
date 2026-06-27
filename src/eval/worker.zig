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
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const vm_force = @import("../vm/force.zig");
const fiber_mod = @import("parallel").fiber;
const InnerFiber = fiber_mod.Fiber;
const worker_id_mod = @import("runtime").worker_id;
const eval_trace = @import("../support/trace.zig");
const prof = @import("../probe/prof.zig");
const timeline = @import("../probe/timeline.zig");
// Used only by the test fixture below.
const bytecode = @import("../bytecode.zig");
const InternTable = @import("runtime").intern.InternTable;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
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
/// is reused via `Fiber.reset` across tasks. Post-F1.4 the fiber's
/// thread affinity is advisory: it wakes onto its allocator-worker's
/// ready queue by preference but any worker can steal it.
pub const Fiber = struct {
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
    /// Free-list link. Only the owning worker manipulates this.
    next_free: ?*Fiber,
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
        const self: *Fiber = @fieldParentPtr("waiter", w);
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
    fibers: std.ArrayList(*Fiber),

    /// LIFO of fibers that have finished their task and are ready to be
    /// reset for a new one. Producers: any worker (a stolen fiber that
    /// finishes routes its completion back to the owning worker's free
    /// list). Consumer: this worker only.
    free_head: ?*Fiber,
    free_mu: stable.SpinMutex,

    shutdown_requested: std.atomic.Value(u8),

    /// Accumulated time this worker spent parked waiting for work. Paired
    /// with `busy_ns` to compute utilisation; reported to the scheduler on
    /// `deinit` so `fix inspect` can show whether helpers are CPU-bound or
    /// starved.
    idle_ns: u64,
    /// Accumulated time this worker spent inside `runFiber` (i.e. inside
    /// `inner.resume_`). Excludes the brief pop-ready / pick-task probing
    /// — that bookkeeping is negligible relative to either fiber work or
    /// futex parks.
    busy_ns: u64,

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

    /// Helper main loop. Drains until shutdown.
    pub fn run(self: *Worker) void {
        worker_id_mod.current = self.worker_id;
        while (!self.shouldStop()) {
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
        const top = try self.acquireFreeFiber();
        top.current_task = null;
        top.inner.reset(entry, arg);
        top.state = .running;
        self.runFiber(top);

        while (top.state != .free or self.anyFiberSuspended()) {
            if (try self.drainStep()) continue;
            self.parkAndAccount();
        }
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
        if (self.pickTask()) |task| {
            const f = try self.acquireFreeFiber();
            f.current_task = task;
            f.inner.reset(slotEntry, @ptrCast(f));
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
    fn runFiber(self: *Worker, f: *Fiber) void {
        f.run_mu.lock();
        defer f.run_mu.unlock();

        const t0 = nanoMonotonic();
        timeline.begin(.run, "", f.fiber_id);
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
        var i: u32 = 0;
        while (i < SPIN_ITERATIONS) : (i += 1) {
            if (self.scheduler.pending_tasks.load(.monotonic) > 0) return;
            if (self.shouldStop()) return;
            std.atomic.spinLoopHint();
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

    fn pickTask(self: *Worker) ?Task {
        if (self.scheduler.pop(self.worker_id)) |t| return t;
        if (self.scheduler.stealAny(self.worker_id)) |t| return t;
        return null;
    }

    /// Pop a fiber from the free list (LIFO — best cache locality), or
    /// allocate a fresh one if the list is empty. The new fiber has its
    /// own stack + VM; the caller must `reset` it with the actual entry.
    fn acquireFreeFiber(self: *Worker) !*Fiber {
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

    fn allocateFiber(self: *Worker) !*Fiber {
        const fiber_id = self.scheduler.allocFiberId();
        const f = try self.allocator.create(Fiber);
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
            .next_free = null,
            .ready_node = .{},
            .waiter = .{ .wake_fn = Fiber.wakeImpl },
            .local_trace = eval_trace.Trace.init(self.allocator),
        };
        f.vm.claimer_id = thunk_mod.makeClaimer(fiber_id);
        // Speculative work captures only the throw message for sticky
        // caching; skip frame-stack allocation on the hot path.
        f.local_trace.frames_disabled = true;

        try self.fibers.append(self.allocator, f);
        return f;
    }

    fn pushFree(self: *Worker, f: *Fiber) void {
        self.free_mu.lock();
        defer self.free_mu.unlock();
        f.next_free = self.free_head;
        self.free_head = f;
    }

    /// Pop a fiber from this worker's ready queue, or steal one from
    /// another worker's queue if our own is empty.
    fn pickReady(self: *Worker) ?*Fiber {
        if (self.scheduler.popReady(self.worker_id)) |node| return readyNodeToFiber(node);
        if (self.scheduler.stealReady(self.worker_id)) |node| return readyNodeToFiber(node);
        return null;
    }

    fn readyNodeToFiber(node: *scheduler_mod.ReadyNode) *Fiber {
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
    const f: *Fiber = @ptrCast(@alignCast(arg));
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
            const items = f.vm.heap.getList(range.list_id) catch return;
            const end = @min(@as(usize, range.offset) + @as(usize, range.len), items.len);
            for (items[range.offset..end]) |item| {
                if (!item.isThunk()) continue;
                _ = vm_force.forceValueSpeculative(&f.vm, item) catch {};
            }
        },
    }
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
