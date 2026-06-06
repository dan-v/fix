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
    allocator: std.mem.Allocator,
    helper_count: u8,
    queues: []TaskQueue,
    threads: []std.Thread,
    wake_words: []std.atomic.Value(u32),
    shutdown_flag: std.atomic.Value(bool),
    next_victim: std.atomic.Value(u32),
    started: std.atomic.Value(bool),

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

        const wake_words = try allocator.alloc(std.atomic.Value(u32), helper_count);
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
        };
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

    /// Submit a task to the scheduler. Picks a victim helper round-robin.
    /// Returns false if all helper queues are full or no helpers exist.
    pub fn submit(self: *Scheduler, task: Task) bool {
        if (self.helper_count == 0) return false;
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.helper_count);
        var i: u8 = 0;
        while (i < self.helper_count) : (i += 1) {
            const idx = (start_idx + i) % self.helper_count;
            if (self.queues[idx].push(task)) {
                self.wakeHelper(idx);
                return true;
            }
        }
        return false;
    }

    /// Helper-side: pop from own queue.
    pub fn pop(self: *Scheduler, helper_idx: u8) ?Task {
        return self.queues[helper_idx].pop();
    }

    /// Helper-side: try to steal from any other helper.
    pub fn stealAny(self: *Scheduler, my_idx: u8) ?Task {
        if (self.helper_count < 2) return null;
        const start_idx: u8 = @intCast(self.next_victim.fetchAdd(1, .monotonic) % self.helper_count);
        var i: u8 = 0;
        while (i < self.helper_count) : (i += 1) {
            const idx = (start_idx + i) % self.helper_count;
            if (idx == my_idx) continue;
            if (self.queues[idx].steal()) |task| return task;
        }
        return null;
    }

    /// Helper-side: park on the wake word until awoken or shutdown.
    pub fn parkHelper(self: *Scheduler, helper_idx: u8) void {
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
