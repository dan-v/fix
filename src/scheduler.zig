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
    helper_count: u8,
    queues: []TaskQueue,
    threads: []std.Thread,
    wake_words: []std.atomic.Value(u32),
    shutdown_flag: std.atomic.Value(bool),
    next_victim: std.atomic.Value(u32),
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

    /// `total_worker_count` includes the main thread (worker 0). The
    /// scheduler manages `total_worker_count - 1` helpers.
    pub fn init(allocator: std.mem.Allocator, total_worker_count: u8) !Scheduler {
        const helper_count: u8 = if (total_worker_count > 1) total_worker_count - 1 else 0;

        const queues = try allocator.alloc(TaskQueue, helper_count);
        errdefer allocator.free(queues);
        var initialized: usize = 0;
        errdefer for (queues[0..initialized]) |*q| q.deinit(allocator);
        for (queues) |*q| {
            q.* = try TaskQueue.init(allocator, 1024);
            initialized += 1;
        }

        const threads = try allocator.alloc(std.Thread, helper_count);
        errdefer allocator.free(threads);

        // wake_words has helper_count + 1 entries: indices 0..helper_count-1
        // are owned by helper threads (same as before), index helper_count is
        // reserved for the main thread's Worker. This keeps the wake/park
        // mechanism uniform for everyone — helpers and main both park on a
        // wake_word, and slot wake_fn signals can route to either by
        // worker_idx (== helper_idx for helpers, == helper_count for main).
        const wake_words = try allocator.alloc(std.atomic.Value(u32), helper_count + 1);
        errdefer allocator.free(wake_words);
        for (wake_words) |*w| w.* = .init(0);

        return .{
            .allocator = allocator,
            .helper_count = helper_count,
            .queues = queues,
            .threads = threads,
            .wake_words = wake_words,
            .shutdown_flag = .init(false),
            .next_victim = .init(0),
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
        };
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
        self.allocator.free(self.threads);
    }

    /// Spawn helper threads. Each runs `workerFn(helper_idx, sched, ctx)`.
    /// helper_idx is 0..helper_count-1 (corresponding to worker_id 1..N-1).
    /// Idempotent: subsequent calls return immediately.
    pub fn start(self: *Scheduler, comptime workerFn: anytype, ctx: anytype) !void {
        if (self.started.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) return;
        if (self.helper_count == 0) return;

        var spawned: usize = 0;
        errdefer {
            self.shutdown_flag.store(true, .release);
            for (0..spawned) |i| self.wakeHelper(@intCast(i));
            for (self.threads[0..spawned]) |t| t.join();
            self.started.store(false, .release);
        }

        const Worker = struct {
            fn run(helper_idx: u8, sched: *Scheduler, c: @TypeOf(ctx)) void {
                workerFn(helper_idx, sched, c);
            }
        };

        for (0..self.helper_count) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, Worker.run, .{
                @as(u8, @intCast(i)),
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
        var i: u8 = 0;
        while (i < self.helper_count) : (i += 1) self.wakeHelper(i);
        for (self.threads) |t| t.join();
    }

    /// Submit a *speculative* task. Picks a victim helper round-robin and
    /// skips the push if the backlog already saturates helpers — past that,
    /// the cost of pushing/waking exceeds the speculative win.
    /// Returns false if all helper queues are full, no helpers exist, or
    /// the speculation backlog cap was hit.
    ///
    /// Cap of `helper_count * 64`: with average task ~20µs, that's ~1.3ms
    /// of queued work per helper. Smaller caps (we used 16 previously)
    /// dropped most submissions from a NixOS toplevel because consumer
    /// fan-out can submit hundreds of items in a tight loop; the bounded
    /// cascade (`vm.in_speculation`) means a deep queue can't run away.
    pub fn submit(self: *Scheduler, task: Task) bool {
        if (self.helper_count == 0) return false;
        const cap: u32 = @as(u32, self.helper_count) * 64;
        if (self.pending_tasks.load(.monotonic) >= cap) {
            _ = self.n_speculative_rej.fetchAdd(1, .monotonic);
            return false;
        }
        if (self.pushRoundRobin(task)) {
            _ = self.n_speculative_ok.fetchAdd(1, .monotonic);
            return true;
        }
        _ = self.n_speculative_rej.fetchAdd(1, .monotonic);
        return false;
    }

    /// Submit a *demand-driven* task. The caller knows it will need the
    /// result, so we skip the speculation backlog cap and only fail when
    /// every helper queue is genuinely full. Used by strict barriers
    /// (e.g., `forceDeep`, `builtins.map`) that fan out known-required
    /// work to helpers.
    pub fn submitUrgent(self: *Scheduler, task: Task) bool {
        if (self.helper_count == 0) return false;
        if (self.pushRoundRobin(task)) {
            _ = self.n_urgent_ok.fetchAdd(1, .monotonic);
            return true;
        }
        _ = self.n_urgent_rej.fetchAdd(1, .monotonic);
        return false;
    }

    fn pushRoundRobin(self: *Scheduler, task: Task) bool {
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.helper_count);
        var i: u8 = 0;
        while (i < self.helper_count) : (i += 1) {
            const idx = (start_idx + i) % self.helper_count;
            if (self.queues[idx].push(task)) {
                // Wake only when the queue might have been idle.
                // `fetchAdd` returns the previous count; if it was zero,
                // helpers are likely parked and need a futex_wake. Past
                // zero, at least one helper is already draining work and
                // will pick up our task without a syscall.
                const prev = self.pending_tasks.fetchAdd(1, .release);
                if (prev == 0) self.wakeHelper(idx);
                return true;
            }
        }
        return false;
    }

    /// Helper-side: pop from own queue. Main worker (helper_idx ==
    /// helper_count) doesn't own a queue — it pops nothing and steals
    /// instead.
    pub fn pop(self: *Scheduler, helper_idx: u8) ?Task {
        if (helper_idx >= self.helper_count) return null;
        const task = self.queues[helper_idx].pop() orelse return null;
        _ = self.pending_tasks.fetchSub(1, .monotonic);
        _ = self.n_pops.fetchAdd(1, .monotonic);
        return task;
    }

    /// Helper-side: try to steal from any other helper.
    pub fn stealAny(self: *Scheduler, my_idx: u8) ?Task {
        if (self.helper_count < 2) return null;
        return self.stealExcluding(my_idx);
    }

    /// Try to steal one task from any helper queue on behalf of `worker_id`.
    /// Excludes the caller's own queue if they own one. worker_id 0 is the
    /// main thread (no queue, excludes nothing). Used by callers that are
    /// blocked waiting for fan-out work to complete and want to contribute
    /// to throughput instead of parking.
    pub fn stealForWorker(self: *Scheduler, worker_id: u8) ?Task {
        if (self.helper_count == 0) return null;
        if (worker_id == 0) return self.stealExcluding(null);
        return self.stealExcluding(worker_id - 1);
    }

    fn stealExcluding(self: *Scheduler, exclude: ?u8) ?Task {
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.helper_count);
        var i: u8 = 0;
        while (i < self.helper_count) : (i += 1) {
            const idx = (start_idx + i) % self.helper_count;
            if (exclude) |e| if (idx == e) continue;
            if (self.queues[idx].steal()) |task| {
                _ = self.pending_tasks.fetchSub(1, .monotonic);
                _ = self.n_steals.fetchAdd(1, .monotonic);
                return task;
            }
        }
        return null;
    }

    /// Helper-side: park on the wake word until awoken or shutdown.
    pub fn parkHelper(self: *Scheduler, helper_idx: u8) void {
        _ = self.n_parks.fetchAdd(1, .monotonic);
        const word = &self.wake_words[helper_idx];
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

    /// Wake the given helper's wake_word and futex_wake it. Public so
    /// remote thunk-resolvers (in worker.zig's wake_fn) can nudge a
    /// helper whose suspended fiber just became resumable.
    pub fn wakeHelperPublic(self: *Scheduler, helper_idx: u8) void {
        self.wakeHelper(helper_idx);
    }

    fn wakeHelper(self: *Scheduler, helper_idx: u8) void {
        const word = &self.wake_words[helper_idx];
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

test "scheduler push/pop/steal work for a single helper" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 1), sched.helper_count);

    const t1: Task = .{ .force_thunk = 7 };
    const t2: Task = .{ .force_thunk = 13 };
    try std.testing.expect(sched.queues[0].push(t1));
    try std.testing.expect(sched.queues[0].push(t2));

    // LIFO from owner.
    const popped = sched.pop(0).?;
    try std.testing.expectEqual(@as(types.ObjectId, 13), popped.force_thunk);

    // Steal sees the older one.
    const stolen = sched.queues[0].steal().?;
    try std.testing.expectEqual(@as(types.ObjectId, 7), stolen.force_thunk);

    try std.testing.expectEqual(@as(?Task, null), sched.pop(0));
}

test "scheduler.submit round-robins across helpers" {
    var sched = try Scheduler.init(std.testing.allocator, 4);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 3), sched.helper_count);

    var i: types.ObjectId = 0;
    while (i < 6) : (i += 1) {
        try std.testing.expect(sched.submit(.{ .force_thunk = i }));
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
    try std.testing.expectEqual(@as(u8, 1), sched.helper_count);

    // The speculation cap is helper_count * 64 = 64. Fill it up via
    // `submit` and confirm the next `submit` is rejected.
    var i: types.ObjectId = 0;
    while (i < 64) : (i += 1) try std.testing.expect(sched.submit(.{ .force_thunk = i }));
    try std.testing.expect(!sched.submit(.{ .force_thunk = 999 }));

    // `submitUrgent` should still go through — the queue capacity is 1024.
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 100 }));
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 101 }));

    var drained: u32 = 0;
    while (sched.queues[0].steal()) |_| drained += 1;
    try std.testing.expectEqual(@as(u32, 66), drained);
}

test "stealForWorker: main (worker 0) excludes nothing; helper N excludes its own queue" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 2), sched.helper_count);

    // Put one task in each helper queue.
    try std.testing.expect(sched.queues[0].push(.{ .force_thunk = 100 }));
    try std.testing.expect(sched.queues[1].push(.{ .force_thunk = 200 }));
    sched.pending_tasks.store(2, .release);

    // Helper at worker_id 1 (helper_idx 0) must not steal from queue 0.
    const stolen_by_h1 = sched.stealForWorker(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 200), stolen_by_h1.force_thunk);

    // Helper at worker_id 2 (helper_idx 1) must not steal from queue 1.
    const stolen_by_h2 = sched.stealForWorker(2).?;
    try std.testing.expectEqual(@as(types.ObjectId, 100), stolen_by_h2.force_thunk);

    // No more tasks anywhere.
    try std.testing.expectEqual(@as(?Task, null), sched.stealForWorker(0));

    // Refill and confirm main (worker 0) will take from any queue.
    try std.testing.expect(sched.queues[0].push(.{ .force_thunk = 7 }));
    sched.pending_tasks.store(1, .release);
    const stolen_by_main = sched.stealForWorker(0).?;
    try std.testing.expectEqual(@as(types.ObjectId, 7), stolen_by_main.force_thunk);
}

test "scheduler helpers run their loop and shut down cleanly" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();

    const Ctx = struct {
        observed: [2]std.atomic.Value(u32) = [_]std.atomic.Value(u32){ .init(0), .init(0) },
    };
    var ctx: Ctx = .{};

    const Worker = struct {
        fn run(helper_idx: u8, s: *Scheduler, c: *Ctx) void {
            while (!s.isShutdown()) {
                const task = s.pop(helper_idx) orelse s.stealAny(helper_idx) orelse {
                    s.parkHelper(helper_idx);
                    continue;
                };
                _ = c.observed[helper_idx].fetchAdd(switch (task) {
                    .force_thunk => |id| @as(u32, @intCast(id)),
                    .force_list_range => 0,
                }, .acq_rel);
            }
        }
    };

    try sched.start(Worker.run, &ctx);

    try std.testing.expect(sched.submit(.{ .force_thunk = 5 }));
    try std.testing.expect(sched.submit(.{ .force_thunk = 7 }));

    // Spin until the total is observed. Futex wake latency can easily
    // dominate a tight spin loop, so we yield to the OS on every probe.
    var spins: u32 = 0;
    while (true) : (spins += 1) {
        const total = ctx.observed[0].load(.acquire) + ctx.observed[1].load(.acquire);
        if (total == 12) break;
        if (spins > 100_000) return error.HelpersDidNotProcess;
        std.Thread.yield() catch {};
    }

    // shutdown via deinit join
}
