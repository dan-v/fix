const std = @import("std");

/// Lock-free Chase-Lev work-stealing deque, generic over payload `T`.
/// Owner-only push/pop (LIFO); multi-consumer FIFO steal. Orderings and the
/// `mfence` are load-bearing — extracted verbatim from the scheduler's
/// TaskQueue. Fixed power-of-two capacity; full push returns false.
pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        mask: u64,
        /// Owner-only writes (push/pop). Stealers read with acquire.
        bottom: std.atomic.Value(u64),
        /// CAS by stealers (and the owner's last-element pop).
        top: std.atomic.Value(u64),

        pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
            const items = try allocator.alloc(T, capacity);
            @memset(items, undefined);
            return .{ .items = items, .mask = @as(u64, capacity) - 1, .bottom = .init(0), .top = .init(0) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        /// Owner-only. Returns false on full.
        pub fn push(self: *Self, item: T) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b - t > self.mask) return false; // full
            self.items[@intCast(b & self.mask)] = item;
            // Release: the slot write must be visible before stealers
            // see the updated bottom.
            self.bottom.store(b + 1, .release);
            return true;
        }

        /// Owner-only LIFO pop.
        pub fn pop(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) -% 1;
            self.bottom.store(b, .monotonic);
            // seq_cst fence: prevents reordering of the bottom write
            // above with the top load below. Without it, the owner
            // could observe a stale `top` and dequeue a slot a stealer
            // is concurrently taking.
            // x86_64-only — fix's fiber primitive already comptime-asserts the target.
            // `@fence` is gone in Zig 0.16; std.atomic doesn't expose a fence helper.
            asm volatile ("mfence" ::: .{ .memory = true });
            const t = self.top.load(.monotonic);
            if (@as(i64, @bitCast(b -% t)) < 0) {
                // Empty — restore bottom.
                self.bottom.store(t, .monotonic);
                return null;
            }
            const item = self.items[@intCast(b & self.mask)];
            if (b != t) return item; // not the last element, no race
            // Last element: race a concurrent steal for it.
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                // Lost the race — stealer took it. Restore bottom.
                self.bottom.store(t + 1, .monotonic);
                return null;
            }
            self.bottom.store(t + 1, .monotonic);
            return item;
        }

        /// Multi-consumer FIFO steal.
        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.acquire);
            // Acquire-acquire fence: see `bottom` after `top`. Without
            // this we could observe a `bottom` from before `top` was
            // bumped by another stealer, leading to phantom reads of
            // already-claimed slots.
            // x86_64-only — fix's fiber primitive already comptime-asserts the target.
            // `@fence` is gone in Zig 0.16; std.atomic doesn't expose a fence helper.
            asm volatile ("mfence" ::: .{ .memory = true });
            const b = self.bottom.load(.acquire);
            if (@as(i64, @bitCast(b -% t)) <= 0) return null;
            const item = self.items[@intCast(t & self.mask)];
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                return null; // lost the race
            }
            return item;
        }

        pub fn approxLen(self: *const Self) u64 {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.monotonic);
            return if (b -% t > 0 and (b -% t) < (self.mask + 1)) b -% t else 0;
        }
    };
}

test "Deque push/pop/steal work for a single owner" {
    var q = try Deque(u64).init(std.testing.allocator, 4);
    defer q.deinit(std.testing.allocator);

    try std.testing.expect(q.push(7));
    try std.testing.expect(q.push(13));

    // LIFO from owner.
    const popped = q.pop().?;
    try std.testing.expectEqual(@as(u64, 13), popped);

    // Steal sees the older one.
    const stolen = q.steal().?;
    try std.testing.expectEqual(@as(u64, 7), stolen);

    try std.testing.expectEqual(@as(?u64, null), q.pop());
}
