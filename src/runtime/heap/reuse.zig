//! Best-fit reclaimed-range storage and bitmap reconstruction.

const std = @import("std");

fn lowBitMask(count: usize) u64 {
    std.debug.assert(count <= 64);
    return if (count == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(count)) - 1;
}

fn setBitmapRange(bitmap: []u64, start_in: u32, end_in: u32) void {
    var start: usize = start_in;
    const end: usize = end_in;
    if (start >= end) return;
    const bit_offset = start & 63;
    if (bit_offset != 0) {
        const count = @min(64 - bit_offset, end - start);
        bitmap[start >> 6] |= lowBitMask(count) << @intCast(bit_offset);
        start += count;
    }
    while (end - start >= 64) : (start += 64)
        bitmap[start >> 6] = std.math.maxInt(u64);
    if (start < end) bitmap[start >> 6] |= lowBitMask(end - start);
}

pub fn nextSetBit(bitmap: []const u64, start: usize, end: usize) ?usize {
    if (start >= end) return null;
    var word_index = start >> 6;
    var word = bitmap[word_index] & (@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(start & 63)));
    while (true) {
        if (word != 0) {
            const bit = word_index * 64 + @ctz(word);
            return if (bit < end) bit else null;
        }
        word_index += 1;
        if (word_index >= bitmap.len or word_index * 64 >= end) return null;
        word = bitmap[word_index];
    }
}

pub fn nextClearBit(bitmap: []const u64, start: usize, end: usize) usize {
    if (start >= end) return end;
    var word_index = start >> 6;
    var word = ~bitmap[word_index] & (@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(start & 63)));
    while (true) {
        if (word != 0) return @min(word_index * 64 + @ctz(word), end);
        word_index += 1;
        if (word_index >= bitmap.len or word_index * 64 >= end) return end;
        word = ~bitmap[word_index];
    }
}

/// Length-classed best-fit free ranges. Mutation is caller-synchronized:
/// worker-local lists have one owner; the shared list is locked or at STW.
pub const RangeFreeList = struct {
    const ClassTree = std.Treap(u32, std.math.order);
    const Class = struct {
        ranges: std.ArrayListUnmanaged(u64) = .empty,
        node: ClassTree.Node,
        active: bool = false,
    };

    map: std.AutoHashMapUnmanaged(u32, *Class) = .empty,
    nonempty: ClassTree = .{},

    pub const Stats = struct {
        classes: u64 = 0,
        ranges: u64 = 0,
        capacity: u64 = 0,
        slots: u64 = 0,
        max_len: u32 = 0,

        pub fn add(self: *Stats, other: Stats) void {
            self.classes += other.classes;
            self.ranges += other.ranges;
            self.capacity += other.capacity;
            self.slots += other.slots;
            self.max_len = @max(self.max_len, other.max_len);
        }
    };

    pub const Loc = struct { segment: u32, offset: u32 };
    pub const Hit = struct { loc: Loc, split: bool };
    const Larger = struct { bits: u64, len: u32 };

    pub fn push(self: *RangeFreeList, allocator: std.mem.Allocator, segment: u32, offset: u32, len: u32) void {
        if (len == 0) return;
        const class = self.getOrCreateClass(allocator, len) orelse return;
        const was_empty = class.ranges.items.len == 0;
        class.ranges.append(allocator, (@as(u64, segment) << 32) | offset) catch return;
        if (was_empty) self.activateClass(class, len);
    }

    pub fn pop(self: *RangeFreeList, allocator: std.mem.Allocator, len: u32) ?Hit {
        if (len == 0) return null;
        if (self.map.get(len)) |class| {
            if (class.ranges.pop()) |bits| {
                if (class.ranges.items.len == 0) self.deactivateClass(class);
                return .{ .loc = unpack(bits), .split = false };
            }
        }
        const larger = self.popSmallestAtLeast(len) orelse return null;
        const loc = unpack(larger.bits);
        self.push(allocator, loc.segment, loc.offset + len, larger.len - len);
        return .{ .loc = loc, .split = true };
    }

    fn unpack(bits: u64) Loc {
        return .{
            .segment = @intCast(bits >> 32),
            .offset = @intCast(bits & 0xFFFF_FFFF),
        };
    }

    fn smallestClassAtLeast(self: *RangeFreeList, minimum: u32) ?*Class {
        var node = self.nonempty.root;
        var best: ?*ClassTree.Node = null;
        while (node) |current| {
            if (current.key >= minimum) {
                best = current;
                node = current.children[0];
            } else {
                node = current.children[1];
            }
        }
        return @fieldParentPtr("node", best orelse return null);
    }

    fn activateClass(self: *RangeFreeList, class: *Class, len: u32) void {
        var entry = self.nonempty.getEntryFor(len);
        std.debug.assert(entry.node == null);
        entry.set(&class.node);
        class.active = true;
    }

    fn deactivateClass(self: *RangeFreeList, class: *Class) void {
        var entry = self.nonempty.getEntryForExisting(&class.node);
        entry.set(null);
        class.active = false;
    }

    fn getOrCreateClass(self: *RangeFreeList, allocator: std.mem.Allocator, len: u32) ?*Class {
        if (self.map.get(len)) |class| return class;
        const class = allocator.create(Class) catch return null;
        class.* = .{ .node = .{ .key = len, .priority = 0, .parent = null, .children = .{ null, null } } };
        const gop = self.map.getOrPut(allocator, len) catch {
            allocator.destroy(class);
            return null;
        };
        if (gop.found_existing) {
            allocator.destroy(class);
            return gop.value_ptr.*;
        }
        gop.value_ptr.* = class;
        return class;
    }

    fn popSmallestAtLeast(self: *RangeFreeList, minimum: u32) ?Larger {
        const class = self.smallestClassAtLeast(minimum) orelse return null;
        const bits = class.ranges.pop().?;
        const len = class.node.key;
        if (class.ranges.items.len == 0) self.deactivateClass(class);
        return .{ .bits = bits, .len = len };
    }

    pub fn maxLen(self: *const RangeFreeList) u32 {
        return (self.nonempty.getMax() orelse return 0).key;
    }

    pub fn stats(self: *const RangeFreeList) Stats {
        var total: Stats = .{};
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const ranges = entry.value_ptr.*.ranges;
            total.capacity += ranges.capacity;
            const count = ranges.items.len;
            if (count == 0) continue;
            const len = entry.key_ptr.*;
            total.classes += 1;
            total.ranges += count;
            total.slots += @as(u64, len) * count;
            total.max_len = @max(total.max_len, len);
        }
        return total;
    }

    pub fn markBitmap(self: *const RangeFreeList, comptime StoreT: type, bitmap: []u64, slot_count: u32) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const len = entry.key_ptr.*;
            for (entry.value_ptr.*.ranges.items) |bits| {
                const loc = unpack(bits);
                const start = StoreT.globalIdOf(loc.segment, loc.offset);
                const end = @as(u64, start) + len;
                std.debug.assert(end <= slot_count);
                if (end <= slot_count) setBitmapRange(bitmap, start, @intCast(end));
            }
        }
    }

    pub fn clearRetainingCapacity(self: *RangeFreeList) void {
        var it = self.map.valueIterator();
        while (it.next()) |class_ptr| {
            const class = class_ptr.*;
            if (!class.active) continue;
            class.ranges.clearRetainingCapacity();
            self.deactivateClass(class);
        }
    }

    pub fn releaseEmptyCapacity(self: *RangeFreeList, allocator: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |class_ptr| {
            const class = class_ptr.*;
            if (class.ranges.items.len == 0 and class.ranges.capacity > 0)
                class.ranges.clearAndFree(allocator);
        }
    }

    pub fn moveClassTo(self: *RangeFreeList, dst: *RangeFreeList, allocator: std.mem.Allocator, len: u32, count: usize) bool {
        if (count == 0 or self == dst) return true;
        const src = self.map.get(len) orelse return false;
        const take = @min(count, src.ranges.items.len);
        if (take == 0) return false;
        const dst_class = dst.getOrCreateClass(allocator, len) orelse return false;
        dst_class.ranges.ensureUnusedCapacity(allocator, take) catch return false;
        const dst_was_empty = dst_class.ranges.items.len == 0;
        const start = src.ranges.items.len - take;
        dst_class.ranges.appendSliceAssumeCapacity(src.ranges.items[start..]);
        if (dst_was_empty) dst.activateClass(dst_class, len);
        src.ranges.items.len = start;
        if (start == 0) self.deactivateClass(src);
        return true;
    }

    /// Claim one range from the best-fit class and move the rest of the
    /// caller's fair-share batch to `dst`. The returned `Hit`, not a boolean
    /// transfer followed by a second pop, is the allocation claim.
    ///
    /// Caller synchronizes both lists. `dst` must be a worker-local list.
    pub fn moveBestFitBatchAndClaim(
        self: *RangeFreeList,
        dst: *RangeFreeList,
        allocator: std.mem.Allocator,
        minimum: u32,
        limit: usize,
        divisor: usize,
    ) ?Hit {
        if (limit == 0 or self == dst) return null;
        const class = self.smallestClassAtLeast(minimum) orelse return null;
        const available = class.ranges.items.len;
        const fair_share = (available + divisor - 1) / divisor;
        const take = @min(limit, fair_share);
        if (take == 0) return null;

        const bits = class.ranges.pop().?;
        const len = class.node.key;
        if (class.ranges.items.len == 0) self.deactivateClass(class);
        if (take > 1)
            _ = self.moveClassTo(dst, allocator, len, take - 1);

        const loc = unpack(bits);
        if (len > minimum)
            dst.push(allocator, loc.segment, loc.offset + minimum, len - minimum);
        return .{ .loc = loc, .split = len != minimum };
    }

    pub fn moveAllTo(self: *RangeFreeList, dst: *RangeFreeList, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const count = entry.value_ptr.*.ranges.items.len;
            if (count > 0) _ = self.moveClassTo(dst, allocator, entry.key_ptr.*, count);
        }
    }

    pub fn deinit(self: *RangeFreeList, allocator: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |class_ptr| {
            const class = class_ptr.*;
            class.ranges.deinit(allocator);
            allocator.destroy(class);
        }
        self.map.deinit(allocator);
    }
};
