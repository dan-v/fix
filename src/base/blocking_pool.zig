//! Generic fixed worker pool for blocking work.

const std = @import("std");
const sync = @import("sync.zig");

pub const WorkFn = *const fn (context: *anyopaque) void;

pub const BlockingPool = struct {
    allocator: std.mem.Allocator,
    worker_count: usize,
    mu: sync.BlockingMutex = .{},
    seq: std.atomic.Value(u32) = .init(0),
    head: ?*Job = null,
    tail: ?*Job = null,
    threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    started: bool = false,
    shutdown: bool = false,

    pub const Job = struct {
        run: WorkFn,
        context: *anyopaque,
        next: ?*Job = null,
    };

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) BlockingPool {
        return .{ .allocator = allocator, .worker_count = @max(worker_count, 1) };
    }

    pub fn start(self: *BlockingPool) !void {
        self.shutdown = false;
        self.started = true;
        errdefer self.stop();
        for (0..self.worker_count) |_| try self.threads.append(self.allocator, try std.Thread.spawn(.{}, worker, .{self}));
    }

    pub fn submit(self: *BlockingPool, job: *Job) void {
        job.next = null;
        self.mu.lock();
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        self.mu.unlock();
        self.wake();
    }

    pub fn submitBlocking(self: *BlockingPool, work: WorkFn, context: *anyopaque) void {
        var cell = BlockingCell{ .work = work, .context = context };
        var job = Job{ .run = BlockingCell.run, .context = &cell };
        self.submit(&job);
        cell.done.acquire();
    }

    const BlockingCell = struct {
        work: WorkFn,
        context: *anyopaque,
        done: sync.Semaphore = sync.Semaphore.init(0),
        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.work(self.context);
            self.done.release();
        }
    };

    pub fn deinit(self: *BlockingPool) void {
        self.stop();
        self.threads.deinit(self.allocator);
    }

    fn stop(self: *BlockingPool) void {
        if (!self.started) return;
        self.mu.lock();
        self.shutdown = true;
        self.mu.unlock();
        self.wake();
        for (self.threads.items) |thread| thread.join();
        self.threads.clearRetainingCapacity();
        self.started = false;
    }

    fn wake(self: *BlockingPool) void {
        _ = self.seq.fetchAdd(1, .release);
        sync.Futex.wake(&self.seq, std.math.maxInt(u32));
    }

    fn worker(self: *BlockingPool) void {
        while (true) {
            self.mu.lock();
            while (self.head == null and !self.shutdown) {
                const sequence = self.seq.load(.acquire);
                self.mu.unlock();
                sync.Futex.wait(&self.seq, sequence);
                self.mu.lock();
            }
            if (self.head == null and self.shutdown) {
                self.mu.unlock();
                return;
            }
            const job = self.head.?;
            self.head = job.next;
            if (self.head == null) self.tail = null;
            self.mu.unlock();
            job.run(job.context);
        }
    }
};

test "blocking pool bounds active jobs to its worker count" {
    const testing = std.testing;
    const State = struct {
        active: std.atomic.Value(u32) = .init(0),
        peak: std.atomic.Value(u32) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),
        fn work(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            var peak = self.peak.load(.acquire);
            while (active > peak) {
                peak = self.peak.cmpxchgWeak(peak, active, .acq_rel, .acquire) orelse break;
            }
            sync.sleepNs(std.time.ns_per_ms);
            _ = self.active.fetchSub(1, .acq_rel);
            _ = self.completed.fetchAdd(1, .release);
        }
    };
    var pool = BlockingPool.init(testing.allocator, 3);
    try pool.start();
    var state: State = .{};
    var jobs: [60]BlockingPool.Job = undefined;
    for (&jobs) |*job| {
        job.* = .{ .run = State.work, .context = &state };
        pool.submit(job);
    }
    pool.deinit();
    try testing.expectEqual(@as(u32, jobs.len), state.completed.load(.acquire));
    try testing.expect(state.peak.load(.acquire) <= 3);
}
