//! Queue mechanisms used by the scheduler policy layer.

const std = @import("std");
const sync = @import("base").sync;

pub const ReadyNode = struct {
    next: ?*ReadyNode = null,
    queued: std.atomic.Value(u8) = .init(0),
};

pub const ReadyQueue = struct {
    mu: sync.SpinMutex align(std.atomic.cache_line),
    head: std.atomic.Value(?*ReadyNode),
    tail: ?*ReadyNode,

    comptime {
        std.debug.assert(@sizeOf(ReadyQueue) % std.atomic.cache_line == 0);
    }

    pub fn init() ReadyQueue {
        return .{ .mu = .{}, .head = .init(null), .tail = null };
    }

    pub fn push(self: *ReadyQueue, node: *ReadyNode) void {
        node.next = null;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head.store(node, .monotonic);
        }
        self.tail = node;
    }

    pub fn pop(self: *ReadyQueue) ?*ReadyNode {
        if (self.head.load(.monotonic) == null) return null;
        self.mu.lock();
        defer self.mu.unlock();
        const node = self.head.load(.monotonic) orelse return null;
        self.head.store(node.next, .monotonic);
        if (node.next == null) self.tail = null;
        node.next = null;
        node.queued.store(0, .release);
        return node;
    }
};

pub const WakeWord = struct {
    word: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    comptime {
        std.debug.assert(@sizeOf(WakeWord) % std.atomic.cache_line == 0);
    }
};

/// Bounded newest-owner/oldest-stealer ring. The scheduler chooses whether a
/// full push evicts; this type owns only synchronization and storage order.
pub fn SpecQueue(comptime Item: type) type {
    return struct {
        const Self = @This();

        mu: sync.SpinMutex align(std.atomic.cache_line),
        items: []Item,
        mask: u32,
        head: u32,
        tail: u32,
        idx: u8,

        comptime {
            std.debug.assert(@sizeOf(Self) % std.atomic.cache_line == 0);
        }

        pub const PushResult = enum { pushed, pushed_evicted, full };

        pub fn init(allocator: std.mem.Allocator, capacity: u32, idx: u8) !Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
            return .{
                .mu = .{},
                .items = try allocator.alloc(Item, capacity),
                .mask = capacity - 1,
                .head = 0,
                .tail = 0,
                .idx = idx,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        fn maskSet(self: *const Self, lane_mask: *std.atomic.Value(u64)) void {
            if (self.idx < 64)
                _ = lane_mask.fetchOr(@as(u64, 1) << @intCast(self.idx), .release);
        }

        fn maskClear(self: *const Self, lane_mask: *std.atomic.Value(u64)) void {
            if (self.idx < 64)
                _ = lane_mask.fetchAnd(~(@as(u64, 1) << @intCast(self.idx)), .release);
        }

        pub fn push(self: *Self, item: Item, evict: bool, lane_mask: *std.atomic.Value(u64)) PushResult {
            self.mu.lock();
            defer self.mu.unlock();
            var evicted = false;
            if (self.head -% self.tail > self.mask) {
                if (!evict) return .full;
                self.tail +%= 1;
                evicted = true;
            }
            if (self.head == self.tail) self.maskSet(lane_mask);
            self.items[self.head & self.mask] = item;
            self.head +%= 1;
            return if (evicted) .pushed_evicted else .pushed;
        }

        pub fn popNewest(self: *Self, lane_mask: *std.atomic.Value(u64)) ?Item {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.head == self.tail) return null;
            self.head -%= 1;
            if (self.head == self.tail) self.maskClear(lane_mask);
            return self.items[self.head & self.mask];
        }

        pub fn steal(self: *Self, lifo: bool, lane_mask: *std.atomic.Value(u64)) ?Item {
            if (lifo) return self.popNewest(lane_mask);
            self.mu.lock();
            defer self.mu.unlock();
            if (self.head == self.tail) return null;
            const item = self.items[self.tail & self.mask];
            self.tail +%= 1;
            if (self.head == self.tail) self.maskClear(lane_mask);
            return item;
        }

        pub fn evictOldest(self: *Self, lane_mask: *std.atomic.Value(u64)) bool {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.head == self.tail) return false;
            self.tail +%= 1;
            if (self.head == self.tail) self.maskClear(lane_mask);
            return true;
        }
    };
}
