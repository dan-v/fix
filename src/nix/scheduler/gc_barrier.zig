//! Stop-the-world and parallel-mark coordination owned by the scheduler.

const std = @import("std");

pub const MarkHook = struct {
    ctx: *anyopaque,
    help: *const fn (ctx: *anyopaque, worker_id: u8) void,
};

pub const Barrier = struct {
    stop_requested: std.atomic.Value(bool) = .init(false),
    worker_parked: []std.atomic.Value(bool),
    mark_open: std.atomic.Value(bool) = .init(false),
    mark_hook: ?MarkHook = null,

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Barrier {
        const parked = try allocator.alloc(std.atomic.Value(bool), worker_count);
        for (parked) |*flag| flag.* = .init(false);
        return .{ .worker_parked = parked };
    }

    pub fn deinit(self: *Barrier, allocator: std.mem.Allocator) void {
        allocator.free(self.worker_parked);
        self.worker_parked = &.{};
    }

    pub inline fn requested(self: *const Barrier) bool {
        return self.stop_requested.load(.acquire);
    }

    pub fn tryBegin(self: *Barrier) bool {
        return self.stop_requested.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null;
    }

    pub fn waitAllParked(self: *Barrier, collector_id: u8) void {
        for (self.worker_parked, 0..) |*flag, id| {
            if (id == collector_id) continue;
            while (!flag.load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    pub fn end(self: *Barrier, collector_id: u8) void {
        self.stop_requested.store(false, .release);
        for (self.worker_parked, 0..) |*flag, id| {
            if (id == collector_id) continue;
            while (flag.load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    pub fn setMarkHook(self: *Barrier, hook: MarkHook) void {
        self.mark_hook = hook;
    }

    pub fn openMark(self: *Barrier) void {
        self.mark_open.store(true, .release);
    }

    pub fn closeMark(self: *Barrier) void {
        self.mark_open.store(false, .release);
    }

    pub fn park(self: *Barrier, worker_id: u8) void {
        self.worker_parked[worker_id].store(true, .release);
        if (self.mark_hook) |hook| {
            while (self.stop_requested.load(.acquire) and
                !self.mark_open.load(.acquire)) std.atomic.spinLoopHint();
            if (self.mark_open.load(.acquire)) hook.help(hook.ctx, worker_id);
        }
        while (self.stop_requested.load(.acquire)) std.atomic.spinLoopHint();
        self.worker_parked[worker_id].store(false, .release);
    }
};
