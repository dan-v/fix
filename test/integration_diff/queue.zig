const std = @import("std");
const main = @import("../integration_diff.zig");
const Classification = main.Classification;

pub const JobResult = struct {
    index: usize,
    seed: u64,
    iteration: usize,
    expr: []u8,
    classification: ?Classification = null,
    err: ?anyerror = null,
    skipped: bool = false,

    pub fn deinit(self: *JobResult, allocator: std.mem.Allocator) void {
        if (self.classification) |classification| classification.deinit(allocator);
        allocator.free(self.expr);
    }
};

pub fn BlockingQueue(comptime T: type) type {
    return struct {
        queue: std.Io.TypeErasedQueue,

        const Self = @This();

        pub fn init(storage: []T) Self {
            return .{
                .queue = .init(std.mem.sliceAsBytes(storage)),
            };
        }

        pub fn put(self: *Self, io: std.Io, item: T) !void {
            var copy = item;
            const bytes = std.mem.asBytes(&copy);
            const written = try self.queue.putUncancelable(io, bytes, bytes.len);
            if (written != bytes.len) return error.ShortQueueWrite;
        }

        pub fn get(self: *Self, io: std.Io) !?T {
            var item: T = undefined;
            const bytes = std.mem.asBytes(&item);
            const read = self.queue.getUncancelable(io, bytes, bytes.len) catch |err| switch (err) {
                error.Closed => return null,
            };
            if (read != bytes.len) return error.ShortQueueRead;
            return item;
        }

        pub fn close(self: *Self, io: std.Io) void {
            self.queue.close(io);
        }
    };
}

pub const ResultQueue = BlockingQueue(JobResult);

pub fn queueCapacity(worker_count: usize, total_jobs: usize, per_worker: usize, minimum: usize) usize {
    const scaled = std.math.mul(usize, worker_count, per_worker) catch total_jobs;
    return @min(total_jobs, @max(@max(scaled, minimum), 1));
}
