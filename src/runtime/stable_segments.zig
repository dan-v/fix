//! Append-only segmented storage with lock-free reads.
//!
//! Storage is divided into segments of geometrically growing size. Once a
//! segment is allocated, its backing array is never relocated. Readers
//! resolve `(segment, offset)` to a stable pointer via a single atomic load.
//! Writers serialize on `write_mu`.
//!
//! Two complementary APIs share the same backing storage:
//!   - `append(value) → u32 global_id`, `get(id) → *const T` — for single-slot
//!     entities indexed by a flat u32 id (e.g. Object slots).
//!   - `reserve(len) → Range`, `slice(range) → []const T` — for contiguous
//!     multi-slot reservations (e.g. list contents, attrset entries).
//!
//! The `T == void` instantiation is rejected at comptime; callers wanting
//! a byte arena should use `T = u8` and the `Range` API directly.

const std = @import("std");
const builtin = @import("builtin");

/// Spinlock built on `std.atomic.Mutex`. Short critical sections only —
/// writers on the storage primitives below are O(allocator call) at most.
pub const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// Tri-state futex mutex. Uncontended lock/unlock is a single cmpxchg
/// plus a release store. Under contention, waiters park on a futex
/// (Linux) or yield (other platforms) instead of burning the core.
///
/// State encoding:
///   0 = unlocked
///   1 = locked, no waiters known
///   2 = locked, at least one waiter is parked or about to park
pub const BlockingMutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    const SPIN_ATTEMPTS: u32 = 40;

    pub fn lock(self: *BlockingMutex) void {
        if (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
        self.lockSlow();
    }

    fn lockSlow(self: *BlockingMutex) void {
        var i: u32 = 0;
        while (i < SPIN_ATTEMPTS) : (i += 1) {
            if (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
        while (true) {
            // Swap to "contended" so the unlocker knows to wake us. If the
            // mutex was unlocked between our spins and now, we've taken it
            // by virtue of swapping in 2.
            const prev = self.state.swap(2, .acquire);
            if (prev == 0) return;
            switch (builtin.os.tag) {
                .linux => {
                    _ = std.os.linux.futex_4arg(
                        @ptrCast(&self.state),
                        .{ .cmd = .WAIT, .private = true },
                        2,
                        null,
                    );
                },
                else => std.Thread.yield() catch {},
            }
        }
    }

    pub fn unlock(self: *BlockingMutex) void {
        const prev = self.state.swap(0, .release);
        if (prev == 2) {
            switch (builtin.os.tag) {
                .linux => {
                    _ = std.os.linux.futex_3arg(
                        @ptrCast(&self.state),
                        .{ .cmd = .WAKE, .private = true },
                        1,
                    );
                },
                else => {},
            }
        }
    }
};

pub const Params = struct {
    /// Size of segment 0 in slots. Must be a power of two ≥ 1.
    first_segment_size: u32,
    /// Cap on the number of segments. Total addressable slots is
    /// `first_segment_size * (2^segment_count - 1)`.
    segment_count: u6 = 28,
};

pub fn StableSegments(comptime T: type, comptime params: Params) type {
    comptime {
        if (T == void) @compileError("StableSegments(void) is unsupported");
        if (params.first_segment_size == 0) @compileError("first_segment_size must be > 0");
        if (!std.math.isPowerOfTwo(params.first_segment_size)) @compileError("first_segment_size must be a power of two");
        if (params.segment_count == 0 or params.segment_count > 32) @compileError("segment_count must be in 1..=32");
    }

    return struct {
        const Self = @This();

        pub const SEGMENT_COUNT = params.segment_count;
        pub const FIRST_SEGMENT_SIZE = params.first_segment_size;
        const FIRST_LOG2: u6 = std.math.log2_int(u32, params.first_segment_size);

        pub const Range = struct {
            segment: u32,
            offset: u32,
            len: u32,
        };

        /// Cursor packs (segment_index, used_in_segment) into one u64 so we can
        /// load it atomically. The writer mutex is the only mutator, so this
        /// could be plain u64; the atomic wrapper exists so opportunistic
        /// readers (e.g. `count()`) don't tear.
        cursor: std.atomic.Value(u64) = .init(0),
        segments: [SEGMENT_COUNT]std.atomic.Value(?[*]T) = blk: {
            var arr: [SEGMENT_COUNT]std.atomic.Value(?[*]T) = undefined;
            for (&arr) |*s| s.* = .init(null);
            break :blk arr;
        },
        write_mu: SpinMutex = .{},

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.segments, 0..) |*atom, i| {
                const ptr = atom.load(.monotonic) orelse continue;
                allocator.free(ptr[0..segmentCapacity(@intCast(i))]);
                atom.store(null, .monotonic);
            }
            self.cursor.store(0, .monotonic);
        }

        /// Reserve `len` consecutive slots. Caller initializes via `sliceMut`.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, len: u32) !Range {
            if (len == 0) return .{ .segment = 0, .offset = 0, .len = 0 };

            self.write_mu.lock();
            defer self.write_mu.unlock();

            const cur = self.cursor.load(.monotonic);
            var seg = segmentOf(cur);
            var used = usedOf(cur);

            // Skip segments that can't fit `len` contiguous slots. We require
            // a reservation to live in a single segment so `slice` doesn't
            // need to stitch across boundaries.
            while (true) {
                const cap = segmentCapacity(seg);
                if (len > cap) {
                    if (seg + 1 >= SEGMENT_COUNT) return error.OutOfMemory;
                    seg += 1;
                    used = 0;
                    continue;
                }
                if (used + len <= cap) break;
                if (seg + 1 >= SEGMENT_COUNT) return error.OutOfMemory;
                seg += 1;
                used = 0;
            }

            try self.ensureSegment(allocator, seg);

            const range: Range = .{ .segment = seg, .offset = used, .len = len };
            self.cursor.store(packCursor(seg, used + len), .release);
            return range;
        }

        /// Append a single value. Returns its global u32 id.
        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !u32 {
            const range = try self.reserve(allocator, 1);
            const slot = self.segments[range.segment].load(.acquire).?;
            slot[range.offset] = value;
            return globalIdOf(range.segment, range.offset);
        }

        /// Rollback the most recently reserved range. UB if `range` is not the
        /// tail of allocations — call sites should `errdefer` immediately
        /// after a reserve.
        pub fn rollback(self: *Self, range: Range) void {
            if (range.len == 0) return;
            self.write_mu.lock();
            defer self.write_mu.unlock();
            const cur = self.cursor.load(.monotonic);
            const seg = segmentOf(cur);
            const used = usedOf(cur);
            if (seg == range.segment and used == range.offset + range.len) {
                self.cursor.store(packCursor(seg, range.offset), .release);
            }
            // Not the tail — leave the slots stranded. They're unused, will
            // be overwritten only on the next reservation if it lands there
            // (it won't, since `used` already moved past).
        }

        pub fn slice(self: *const Self, range: Range) []const T {
            if (range.len == 0) return &.{};
            const seg_ptr = self.segments[range.segment].load(.acquire).?;
            return seg_ptr[range.offset .. range.offset + range.len];
        }

        pub fn sliceMut(self: *Self, range: Range) []T {
            if (range.len == 0) return &.{};
            const seg_ptr = self.segments[range.segment].load(.acquire).?;
            return seg_ptr[range.offset .. range.offset + range.len];
        }

        pub fn get(self: *const Self, id: u32) *const T {
            const loc = locationOf(id);
            const seg_ptr = self.segments[loc.segment].load(.acquire).?;
            return &seg_ptr[loc.offset];
        }

        pub fn getMut(self: *Self, id: u32) *T {
            const loc = locationOf(id);
            const seg_ptr = self.segments[loc.segment].load(.acquire).?;
            return &seg_ptr[loc.offset];
        }

        /// Total elements appended/reserved. Approximate under concurrent
        /// writers (writers serialize, but cursor moves at the end of each
        /// reserve so an in-progress reservation isn't reflected).
        pub fn count(self: *const Self) u32 {
            const cur = self.cursor.load(.acquire);
            const seg = segmentOf(cur);
            const used = usedOf(cur);
            return segmentStart(seg) + used;
        }

        /// Translate a global id to (segment, offset).
        pub fn locationOf(id: u32) Range {
            // segment_start(i) = FIRST * (2^i - 1), so the segment containing
            // id is the largest i with segment_start(i) ≤ id. Equivalent:
            //   i = floor(log2((id / FIRST) + 1))
            const shifted = (id >> FIRST_LOG2) + 1;
            const seg = 31 - @clz(shifted);
            const offset = id - segmentStart(@intCast(seg));
            return .{ .segment = @intCast(seg), .offset = offset, .len = 1 };
        }

        pub fn globalIdOf(segment: u32, offset: u32) u32 {
            return segmentStart(segment) + offset;
        }

        fn segmentCapacity(segment: u32) u32 {
            return params.first_segment_size << @intCast(segment);
        }

        fn segmentStart(segment: u32) u32 {
            // FIRST * (2^segment - 1)
            return (params.first_segment_size << @intCast(segment)) - params.first_segment_size;
        }

        fn ensureSegment(self: *Self, allocator: std.mem.Allocator, segment: u32) !void {
            if (self.segments[segment].load(.monotonic) != null) return;
            const cap = segmentCapacity(segment);
            const buf = try allocator.alloc(T, cap);
            self.segments[segment].store(buf.ptr, .release);
        }

        fn packCursor(seg: u32, used: u32) u64 {
            return (@as(u64, seg) << 32) | @as(u64, used);
        }
        fn segmentOf(cur: u64) u32 {
            return @intCast(cur >> 32);
        }
        fn usedOf(cur: u64) u32 {
            return @intCast(cur & std.math.maxInt(u32));
        }
    };
}

test "stable segments: append and get" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 4 }).empty;
    defer seg.deinit(allocator);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const id = try seg.append(allocator, i * 7);
        try std.testing.expectEqual(i, id);
    }
    i = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(i * 7, seg.get(i).*);
    }
    try std.testing.expectEqual(@as(u32, 100), seg.count());
}

test "stable segments: reserve spans multiple segments" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u8, .{ .first_segment_size = 4 }).empty;
    defer seg.deinit(allocator);

    const r1 = try seg.reserve(allocator, 3);
    try std.testing.expectEqual(@as(u32, 0), r1.segment);
    try std.testing.expectEqual(@as(u32, 0), r1.offset);
    try std.testing.expectEqual(@as(u32, 3), r1.len);

    // Segment 0 has 1 slot left; a reservation of len 2 must skip to segment 1.
    const r2 = try seg.reserve(allocator, 2);
    try std.testing.expectEqual(@as(u32, 1), r2.segment);
    try std.testing.expectEqual(@as(u32, 0), r2.offset);

    seg.sliceMut(r1)[0] = 0xAA;
    seg.sliceMut(r1)[1] = 0xBB;
    seg.sliceMut(r1)[2] = 0xCC;
    seg.sliceMut(r2)[0] = 0x11;
    seg.sliceMut(r2)[1] = 0x22;

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, seg.slice(r1));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22 }, seg.slice(r2));
}

test "stable segments: rollback within current segment" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 8 }).empty;
    defer seg.deinit(allocator);

    _ = try seg.append(allocator, 1);
    _ = try seg.append(allocator, 2);
    const r = try seg.reserve(allocator, 3);
    seg.sliceMut(r)[0] = 0xDEAD;
    try std.testing.expectEqual(@as(u32, 5), seg.count());

    seg.rollback(r);
    try std.testing.expectEqual(@as(u32, 2), seg.count());

    const id3 = try seg.append(allocator, 99);
    try std.testing.expectEqual(@as(u32, 2), id3);
    try std.testing.expectEqual(@as(u32, 99), seg.get(2).*);
}

test "stable segments: rollback after segment-skip leaves earlier slots stranded" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 4 }).empty;
    defer seg.deinit(allocator);

    _ = try seg.append(allocator, 1);
    _ = try seg.append(allocator, 2);
    // Segment 0 has 2 slots left; reserve(3) must skip to segment 1.
    const r = try seg.reserve(allocator, 3);
    try std.testing.expectEqual(@as(u32, 1), r.segment);

    // rollback rewinds within segment 1 but doesn't go back to segment 0.
    seg.rollback(r);
    const next = try seg.append(allocator, 7);
    // next id lands in segment 1 at offset 0 → global id 4.
    try std.testing.expectEqual(@as(u32, 4), next);
}

test "stable segments: locationOf round-trips" {
    const Seg = StableSegments(u32, .{ .first_segment_size = 4 });
    var id: u32 = 0;
    while (id < 200) : (id += 1) {
        const loc = Seg.locationOf(id);
        // FIRST * (2^seg - 1) <= id < FIRST * (2^(seg+1) - 1)
        const start: u32 = (@as(u32, 4) << @as(u5, @intCast(loc.segment))) - 4;
        const end: u32 = (@as(u32, 4) << @as(u5, @intCast(loc.segment + 1))) - 4;
        try std.testing.expect(start <= id);
        try std.testing.expect(id < end);
        try std.testing.expectEqual(id - start, loc.offset);
    }
}

test "stable segments: concurrent appends are race-free" {
    const Seg = StableSegments(u64, .{ .first_segment_size = 16 });
    const allocator = std.testing.allocator;
    var seg = Seg.empty;
    defer seg.deinit(allocator);

    const Worker = struct {
        fn run(s: *Seg, alloc: std.mem.Allocator, worker_id: u64, per_worker: u32) void {
            var i: u32 = 0;
            while (i < per_worker) : (i += 1) {
                _ = s.append(alloc, (worker_id << 32) | i) catch return;
            }
        }
    };

    const worker_count: u8 = 4;
    const per_worker: u32 = 250;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &seg, allocator, @as(u64, @intCast(i)), per_worker });
    }
    for (&threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, worker_count * per_worker), seg.count());

    // Every (worker, i) pair must be present exactly once.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var id: u32 = 0;
    while (id < seg.count()) : (id += 1) {
        const v = seg.get(id).*;
        try std.testing.expect(!seen.contains(v));
        try seen.put(v, {});
    }
    try std.testing.expectEqual(@as(usize, worker_count * per_worker), seen.count());
}
