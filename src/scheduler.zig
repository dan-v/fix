//! Work-stealing scheduler for parallel evaluation.
//!
//! The scheduler maintains a pool of worker threads. Each worker has its own
//! task queue. When a worker runs out of work, it steals from another worker's
//! queue. This minimizes contention while keeping all cores busy.
//!
//! Tasks are small tagged values. Today the evaluator only submits thunks, but
//! async filesystem work needs a way to park and later resume evaluation
//! continuations without making worker queues depend on filesystem code.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Thunk = @import("thunk.zig").Thunk;

pub const Continuation = struct {
    context: *anyopaque,
    resume_fn: *const fn (*anyopaque) void,
};

/// A single entry in a worker's task queue.
pub const Task = union(enum) {
    thunk: *Thunk,
    continuation: Continuation,
};

/// Bounded multi-producer multi-consumer queue for tasks.
/// Workers push to their own queue (SPSC) and steal from others.
const TaskQueue = struct {
    tasks: []Task,
    capacity: u32,
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),

    fn init(capacity: u32) TaskQueue {
        const tasks = std.heap.page_allocator.alloc(Task, capacity) catch @panic("oom: task queue");
        @memset(tasks, undefined);
        return .{
            .tasks = tasks,
            .capacity = capacity,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
        };
    }

    fn deinit(self: *TaskQueue) void {
        std.heap.page_allocator.free(self.tasks);
    }

    /// Push a task to the back (called by the owner thread only — SPSC).
    fn push(self: *TaskQueue, task: Task) bool {
        const t = self.tail.load(.monotonic);
        const h = self.head.load(.acquire);
        if (t - h >= self.capacity) return false;
        self.tasks[t % self.capacity] = task;
        self.tail.store(t + 1, .release);
        return true;
    }

    /// Pop a task from the back (called by the owner thread).
    fn pop(self: *TaskQueue) ?Task {
        const t = self.tail.load(.monotonic);
        if (t == 0) return null;
        const new_t = t - 1;
        self.tail.store(new_t, .monotonic);

        if (self.head.load(.acquire) <= new_t) {
            return self.tasks[new_t % self.capacity];
        }

        // Empty race: restore.
        self.tail.store(t, .monotonic);
        return null;
    }

    /// Steal a task from the front (called by other threads).
    fn steal(self: *TaskQueue) ?Task {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        if (t <= h) return null;

        const task = self.tasks[h % self.capacity];

        // Try to claim this slot.
        const prev = self.head.cmpxchgStrong(h, h + 1, .release, .monotonic);
        if (prev == null) return task;
        return null;
    }

    fn empty(self: *const TaskQueue) bool {
        return self.tail.load(.acquire) <= self.head.load(.acquire);
    }
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    worker_count: u8,
    queues: []TaskQueue,
    threads: []std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Scheduler {
        const queues = try allocator.alloc(TaskQueue, worker_count);
        const threads = try allocator.alloc(std.Thread, worker_count);

        for (queues) |*q| {
            q.* = TaskQueue.init(1024);
        }

        return .{
            .allocator = allocator,
            .worker_count = worker_count,
            .queues = queues,
            .threads = threads,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.shutdown();
        for (self.queues) |*q| {
            q.deinit();
        }
        self.allocator.free(self.queues);
        self.allocator.free(self.threads);
    }

    pub fn start(self: *Scheduler, workerFn: anytype, ctx: anytype) !void {
        self.running.store(true, .release);
        const Worker = struct {
            fn run(idx: u8, sched: *Scheduler, fn_ptr: @TypeOf(workerFn), c: @TypeOf(ctx)) void {
                // Bind to a specific core for cache locality.
                if (!builtin.single_threaded) {
                    const cpu_set = std.os.linux.CPU_SET{};
                    // Simplified; real version sets affinity.
                    _ = cpu_set;
                }
                fn_ptr(idx, sched, c);
            }
        };

        for (0..self.worker_count) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, Worker.run, .{
                @as(u8, @intCast(i)),
                self,
                workerFn,
                ctx,
            });
        }
    }

    pub fn shutdown(self: *Scheduler) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);

        for (self.threads) |*t| {
            t.join();
        }
    }

    /// Submit a task to a specific worker's queue.
    pub fn submitTo(self: *Scheduler, worker_idx: u8, task: Task) bool {
        return self.queues[worker_idx].push(task);
    }

    pub fn submitThunkTo(self: *Scheduler, worker_idx: u8, thunk: *Thunk) bool {
        return self.submitTo(worker_idx, .{ .thunk = thunk });
    }

    pub fn submitContinuationTo(self: *Scheduler, worker_idx: u8, continuation: Continuation) bool {
        return self.submitTo(worker_idx, .{ .continuation = continuation });
    }

    /// Worker pops from its own queue.
    pub fn pop(self: *Scheduler, worker_idx: u8) ?Task {
        return self.queues[worker_idx].pop();
    }

    /// Worker steals from another worker's queue.
    pub fn steal(self: *Scheduler, worker_idx: u8) ?Task {
        const q = &self.queues[worker_idx];
        return q.steal();
    }

    /// Try to steal from any other worker.
    pub fn stealAny(self: *Scheduler, my_idx: u8) ?Task {
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            if (i == my_idx) continue;
            if (self.steal(i)) |task| return task;
        }
        return null;
    }
};

fn markResumed(context: *anyopaque) void {
    const resumed: *bool = @ptrCast(@alignCast(context));
    resumed.* = true;
}

test "scheduler queues thunk tasks" {
    var scheduler = try Scheduler.init(std.testing.allocator, 1);
    defer scheduler.deinit();

    var thunk = Thunk.init(@import("value.zig").Value.null_val);
    try std.testing.expect(scheduler.submitThunkTo(0, &thunk));

    const task = scheduler.pop(0).?;
    switch (task) {
        .thunk => |queued| try std.testing.expectEqual(&thunk, queued),
        .continuation => return error.UnexpectedContinuationTask,
    }
}

test "scheduler queues continuation tasks" {
    var scheduler = try Scheduler.init(std.testing.allocator, 1);
    defer scheduler.deinit();

    var resumed = false;
    try std.testing.expect(scheduler.submitContinuationTo(0, .{
        .context = &resumed,
        .resume_fn = markResumed,
    }));

    const task = scheduler.pop(0).?;
    switch (task) {
        .continuation => |continuation| continuation.resume_fn(continuation.context),
        .thunk => return error.UnexpectedThunkTask,
    }

    try std.testing.expect(resumed);
}
