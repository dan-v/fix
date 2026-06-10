//! Work-stealing scheduler for parallel evaluation.
//!
//! Helper threads run alongside the calling ("main") thread:
//!   - worker_id 0 → main thread; never spawned, never holds a queue.
//!   - worker_id 1..N-1 → helper threads with their own task queue and VM.
//!
//! Each helper loops on:
//!   1. Pop from own queue (LIFO; best cache locality).
//!   2. Steal from a random victim helper (FIFO at the victim).
//!   3. Park on a per-helper futex until a submitter wakes us up.
//!
//! Tasks are produced by any worker (main or helper) and routed round-robin
//! to a victim helper. Submissions may fail (full queue) — callers treat
//! speculative submissions as best-effort.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("runtime/types.zig");
const stable = @import("runtime/stable_segments.zig");

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
};

pub const ForceListRange = struct {
    list_id: types.ObjectId,
    offset: u32,
    len: u8,
};

/// Embeddable linked-list node for the per-worker ready queue.
/// Each Fiber struct (in worker.zig) inlines one of these; the
/// scheduler holds queues of `*ReadyNode` and the worker recovers
/// the parent Fiber via `@fieldParentPtr`.
pub const ReadyNode = struct {
    next: ?*ReadyNode = null,
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
        return n;
    }
};

/// Bounded ring-buffer task queue protected by a `SpinMutex`.
///
/// Pushes can come from any thread (the main submitter or a helper round-
/// robining to a victim). Pops are LIFO (owner-hot end), steals are FIFO
/// (cold end), but with the mutex protecting both ends the LIFO/FIFO
/// distinction is only a locality hint.
const TaskQueue = struct {
    tasks: []Task,
    capacity: u32,
    head: u32,
    tail: u32,
    mu: stable.SpinMutex,

    fn init(allocator: std.mem.Allocator, capacity: u32) !TaskQueue {
        const tasks = try allocator.alloc(Task, capacity);
        @memset(tasks, undefined);
        return .{
            .tasks = tasks,
            .capacity = capacity,
            .head = 0,
            .tail = 0,
            .mu = .{},
        };
    }

    fn deinit(self: *TaskQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.tasks);
    }

    fn push(self: *TaskQueue, task: Task) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tail - self.head >= self.capacity) return false;
        self.tasks[self.tail % self.capacity] = task;
        self.tail +%= 1;
        return true;
    }

    fn pop(self: *TaskQueue) ?Task {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tail == self.head) return null;
        self.tail -%= 1;
        return self.tasks[self.tail % self.capacity];
    }

    fn steal(self: *TaskQueue) ?Task {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tail == self.head) return null;
        const task = self.tasks[self.head % self.capacity];
        self.head +%= 1;
        return task;
    }
};

pub const Scheduler = struct {
    /// Cumulative scheduler activity counters. Read via `stats()`.
    /// All values are advisory — monotonic loads are fine.
    pub const Stats = struct {
        speculative_submitted: u64,
        speculative_rejected: u64,
        urgent_submitted: u64,
        urgent_rejected: u64,
        pops: u64,
        steals: u64,
        parks: u64,
        /// Deepest fiber native stack high-water seen across all workers
        /// since startup. Use to size `Fiber.min_stack_bytes` against a
        /// representative workload.
        max_fiber_stack_used_bytes: u64,
        /// Deepest VM value-stack sp seen across all workers, in Values.
        /// Multiply by `@sizeOf(Value)` (= 16) for a byte count.
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
    queues: []TaskQueue,
    /// Per-worker ready-fiber queues. Producers are any thread waking a
    /// fiber (via thunk resolve → `Fiber.wakeImpl`); consumers are the
    /// owning worker (most often) or any worker stealing when its own
    /// queue is empty. Indexed by worker_id.
    ready_queues: []ReadyQueue,
    threads: []std.Thread,
    wake_words: []std.atomic.Value(u32),
    shutdown_flag: std.atomic.Value(bool),
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
    /// Activity counters. Monotonic adds — the only consumer is the
    /// stats report, which doesn't need strong ordering.
    n_speculative_ok: std.atomic.Value(u64),
    n_speculative_rej: std.atomic.Value(u64),
    n_urgent_ok: std.atomic.Value(u64),
    n_urgent_rej: std.atomic.Value(u64),
    n_pops: std.atomic.Value(u64),
    n_steals: std.atomic.Value(u64),
    n_parks: std.atomic.Value(u64),
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

    /// `worker_count` includes the main thread (worker 0). The
    /// scheduler spawns `worker_count - 1` helper threads in `start()`;
    /// worker 0 runs on the calling thread.
    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Scheduler {
        const safe_worker_count: u8 = if (worker_count == 0) 1 else worker_count;

        // One queue and one wake word per worker — including worker 0
        // (main). Symmetric task ownership; the only thing not
        // symmetric is who spawned which thread.
        const queues = try allocator.alloc(TaskQueue, safe_worker_count);
        errdefer allocator.free(queues);
        var initialized: usize = 0;
        errdefer for (queues[0..initialized]) |*q| q.deinit(allocator);
        for (queues) |*q| {
            q.* = try TaskQueue.init(allocator, 1024);
            initialized += 1;
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

        return .{
            .allocator = allocator,
            .worker_count = safe_worker_count,
            .queues = queues,
            .ready_queues = ready_queues,
            .threads = threads,
            .wake_words = wake_words,
            .shutdown_flag = .init(false),
            .next_victim = .init(0),
            .next_fiber_id = .init(0),
            .started = .init(false),
            .pending_tasks = .init(0),
            .n_speculative_ok = .init(0),
            .n_speculative_rej = .init(0),
            .n_urgent_ok = .init(0),
            .n_urgent_rej = .init(0),
            .n_pops = .init(0),
            .n_steals = .init(0),
            .n_parks = .init(0),
            .n_max_fiber_stack = .init(0),
            .n_max_vm_sp = .init(0),
            .n_idle_ns = .init(0),
            .n_busy_ns = .init(0),
            .disable_speculation = false,
            .disable_fanout = false,
        };
    }

    /// Allocate a fresh globally-unique fiber id. Called from
    /// `Worker.allocateFiber` so claimer identity doesn't depend on
    /// the worker that happened to create the fiber.
    pub fn allocFiberId(self: *Scheduler) u32 {
        return self.next_fiber_id.fetchAdd(1, .monotonic);
    }

    pub fn stats(self: *const Scheduler) Stats {
        return .{
            .speculative_submitted = self.n_speculative_ok.load(.monotonic),
            .speculative_rejected = self.n_speculative_rej.load(.monotonic),
            .urgent_submitted = self.n_urgent_ok.load(.monotonic),
            .urgent_rejected = self.n_urgent_rej.load(.monotonic),
            .pops = self.n_pops.load(.monotonic),
            .steals = self.n_steals.load(.monotonic),
            .parks = self.n_parks.load(.monotonic),
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

    pub fn deinit(self: *Scheduler) void {
        self.shutdown();
        self.allocator.free(self.wake_words);
        for (self.queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.queues);
        self.allocator.free(self.ready_queues);
        self.allocator.free(self.threads);
    }

    /// Push a woken fiber's ReadyNode onto the target worker's
    /// ready queue and nudge it.
    pub fn enqueueReady(self: *Scheduler, target_worker_id: u8, node: *ReadyNode) void {
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

    /// Signal helpers to exit and wait for them. Idempotent.
    pub fn shutdown(self: *Scheduler) void {
        if (!self.started.swap(false, .acq_rel)) return;
        self.shutdown_flag.store(true, .release);
        var i: u8 = 1;
        while (i < self.worker_count) : (i += 1) self.wakeWorker(i);
        for (self.threads) |t| t.join();
    }

    /// Submit a *speculative* task. The submitter passes its own
    /// `worker_id` so we can skip its queue — pushing to your own queue
    /// just sits there until you suspend, defeating the parallelism.
    pub fn submit(self: *Scheduler, task: Task, submitter_id: u8) bool {
        if (self.worker_count <= 1) return false;
        if (self.disable_speculation) return false;
        const cap: u32 = @as(u32, self.worker_count - 1) * 64;
        if (self.pending_tasks.load(.monotonic) >= cap) {
            _ = self.n_speculative_rej.fetchAdd(1, .monotonic);
            return false;
        }
        if (self.pushRoundRobin(task, submitter_id)) {
            _ = self.n_speculative_ok.fetchAdd(1, .monotonic);
            return true;
        }
        _ = self.n_speculative_rej.fetchAdd(1, .monotonic);
        return false;
    }

    /// Submit a *demand-driven* task. Same submitter-self-exclusion
    /// rule as `submit`.
    pub fn submitUrgent(self: *Scheduler, task: Task, submitter_id: u8) bool {
        if (self.worker_count <= 1) return false;
        if (self.disable_fanout) return false;
        if (self.pushRoundRobin(task, submitter_id)) {
            _ = self.n_urgent_ok.fetchAdd(1, .monotonic);
            return true;
        }
        _ = self.n_urgent_rej.fetchAdd(1, .monotonic);
        return false;
    }

    fn pushRoundRobin(self: *Scheduler, task: Task, submitter_id: u8) bool {
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == submitter_id) continue;
            if (self.queues[idx].push(task)) {
                // Wake only when the queue might have been idle.
                // `fetchAdd` returns the previous count; if it was zero,
                // helpers are likely parked and need a futex_wake. Past
                // zero, at least one helper is already draining work and
                // will pick up our task without a syscall.
                const prev = self.pending_tasks.fetchAdd(1, .release);
                if (prev == 0) self.wakeWorker(idx);
                return true;
            }
        }
        return false;
    }

    /// Pop a task from `worker_id`'s own queue. Every worker — main and
    /// helpers — owns a queue post-F1.
    pub fn pop(self: *Scheduler, worker_id: u8) ?Task {
        if (worker_id >= self.worker_count) return null;
        const task = self.queues[worker_id].pop() orelse return null;
        _ = self.pending_tasks.fetchSub(1, .monotonic);
        _ = self.n_pops.fetchAdd(1, .monotonic);
        return task;
    }

    /// Try to steal one task from any worker's queue, excluding the
    /// caller's own (`worker_id`). All workers participate in steal
    /// symmetrically now.
    pub fn stealForWorker(self: *Scheduler, worker_id: u8) ?Task {
        if (self.worker_count < 2) return null;
        return self.stealExcluding(worker_id);
    }

    /// Alias for `stealForWorker` — workers use this from their drain
    /// loop. Kept as a separate name so the call site reads as
    /// "steal anything I can find," not "steal for some specific id."
    pub fn stealAny(self: *Scheduler, worker_id: u8) ?Task {
        return self.stealForWorker(worker_id);
    }

    fn stealExcluding(self: *Scheduler, exclude: ?u8) ?Task {
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (exclude) |e| if (idx == e) continue;
            if (self.queues[idx].steal()) |task| {
                _ = self.pending_tasks.fetchSub(1, .monotonic);
                _ = self.n_steals.fetchAdd(1, .monotonic);
                return task;
            }
        }
        return null;
    }

    /// Park `worker_id`'s thread on its wake word until awoken or
    /// shutdown. Works for any worker, including worker 0.
    pub fn parkWorker(self: *Scheduler, worker_id: u8) void {
        _ = self.n_parks.fetchAdd(1, .monotonic);
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

    fn wakeWorker(self: *Scheduler, worker_id: u8) void {
        const word = &self.wake_words[worker_id];
        word.store(1, .release);
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

    const t1: Task = .{ .force_thunk = 7 };
    const t2: Task = .{ .force_thunk = 13 };
    // Push directly to worker 1's queue (helper).
    try std.testing.expect(sched.queues[1].push(t1));
    try std.testing.expect(sched.queues[1].push(t2));

    // LIFO from owner.
    const popped = sched.pop(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 13), popped.force_thunk);

    // Steal sees the older one.
    const stolen = sched.queues[1].steal().?;
    try std.testing.expectEqual(@as(types.ObjectId, 7), stolen.force_thunk);

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

    var total: u32 = 0;
    for (sched.queues) |*q| {
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

    // The speculation cap is (worker_count - 1) * 64 = 64. Fill it up
    // via `submit` and confirm the next `submit` is rejected.
    var i: types.ObjectId = 0;
    while (i < 64) : (i += 1) try std.testing.expect(sched.submit(.{ .force_thunk = i }, 0));
    try std.testing.expect(!sched.submit(.{ .force_thunk = 999 }, 0));

    // `submitUrgent` should still go through — the queue capacity is 1024.
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 100 }, 0));
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 101 }, 0));

    var drained: u32 = 0;
    for (sched.queues) |*q| while (q.steal()) |_| { drained += 1; };
    try std.testing.expectEqual(@as(u32, 66), drained);
}

test "stealForWorker: each worker excludes its own queue" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 3), sched.worker_count);

    // Put one task in each of worker 1 and worker 2's queues.
    try std.testing.expect(sched.queues[1].push(.{ .force_thunk = 100 }));
    try std.testing.expect(sched.queues[2].push(.{ .force_thunk = 200 }));
    sched.pending_tasks.store(2, .release);

    // Worker 1 must not steal from its own queue (queues[1]).
    const stolen_by_w1 = sched.stealForWorker(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 200), stolen_by_w1.force_thunk);

    // Worker 2 must not steal from its own queue (queues[2]).
    const stolen_by_w2 = sched.stealForWorker(2).?;
    try std.testing.expectEqual(@as(types.ObjectId, 100), stolen_by_w2.force_thunk);

    // No more tasks anywhere.
    try std.testing.expectEqual(@as(?Task, null), sched.stealForWorker(0));

    // Worker 0 (main) likewise excludes its own queue but can take
    // from any other.
    try std.testing.expect(sched.queues[1].push(.{ .force_thunk = 7 }));
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
                    .force_list_range => 0,
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
