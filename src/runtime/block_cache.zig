//! Bounded reuse cache for large allocations.
//!
//! `SmpAllocator` (the release-mode process gpa) sends every allocation of
//! 64 KB or more straight to `PageAllocator` — a fresh `mmap` whose pages
//! are minor-faulted (and kernel-zeroed) on first touch, then `munmap`ed on
//! free. An eval-heavy run cycles ~9K such blocks (~2 GB of first-touch:
//! per-file parse/compile arenas, builtin temp buffers), costing ~0.5 s of
//! fault handling per NixOS toplevel at w=1 — >20% of wall.
//!
//! This wrapper rounds cacheable sizes up to power-of-two classes and keeps
//! freed blocks on a per-class free stack for reuse, so repeated large
//! temporaries stop re-faulting. Bounds: classes 64 KB..64 MB, per-class
//! block caps sized so the worst-case retained set is ~220 MB (blocks are
//! only retained if the workload actually allocated them). Anything outside
//! the cacheable range (or over-aligned) passes through untouched.
//!
//! Invariant: every user block whose `len` falls in the cacheable range was
//! allocated with its full class capacity from the backing allocator, so
//! `free`/`resize` can reconstruct the true capacity from `len` alone.
//! In-place resizes are allowed exactly within one class; small (backing-
//! owned) blocks may never grow in place into the cacheable range.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const SpinMutex = @import("stable_segments.zig").SpinMutex;

const MIN_LOG2: u6 = 16; // 64 KB — SmpAllocator's direct-map threshold
const CLASS_COUNT: usize = 11; // 64 KB .. 64 MB
/// Per-class retained-block caps (index = class); bigger classes keep fewer.
const class_caps: [CLASS_COUNT]u8 = .{ 8, 8, 8, 8, 8, 8, 8, 4, 2, 1, 1 };
const MAX_PER_CLASS = 8;

fn classSize(class: usize) usize {
    return @as(usize, 1) << (MIN_LOG2 + @as(u6, @intCast(class)));
}

/// Class index for `len`, or null when `len` is outside the cacheable range.
fn classOf(len: usize) ?usize {
    if (len < (@as(usize, 1) << MIN_LOG2)) return null;
    const log = std.math.log2_int_ceil(usize, len);
    if (log < MIN_LOG2 or log >= MIN_LOG2 + CLASS_COUNT) return null;
    return log - MIN_LOG2;
}

pub const BlockCacheAllocator = struct {
    backing: Allocator,
    mu: SpinMutex = .{},
    blocks: [CLASS_COUNT][MAX_PER_CLASS][*]u8 = undefined,
    counts: [CLASS_COUNT]u8 = @splat(0),

    pub fn init(backing: Allocator) BlockCacheAllocator {
        return .{ .backing = backing };
    }

    /// Release every retained block back to the backing allocator.
    pub fn deinit(self: *BlockCacheAllocator) void {
        for (0..CLASS_COUNT) |class| {
            const size = classSize(class);
            for (self.blocks[class][0..self.counts[class]]) |ptr| {
                self.backing.rawFree(ptr[0..size], block_alignment, @returnAddress());
            }
            self.counts[class] = 0;
        }
    }

    pub fn allocator(self: *BlockCacheAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Class blocks come from the backing allocator's large path
    /// (PageAllocator), which returns page-aligned memory; any request
    /// with alignment above this passes through uncached.
    const block_alignment: Alignment = .fromByteUnits(std.heap.page_size_min);

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BlockCacheAllocator = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() > std.heap.page_size_min) {
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }
        const class = classOf(len) orelse return self.backing.rawAlloc(len, alignment, ret_addr);
        self.mu.lock();
        if (self.counts[class] > 0) {
            self.counts[class] -= 1;
            const ptr = self.blocks[class][self.counts[class]];
            self.mu.unlock();
            return ptr;
        }
        self.mu.unlock();
        return self.backing.rawAlloc(classSize(class), block_alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *BlockCacheAllocator = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() > std.heap.page_size_min) {
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }
        const old_class = classOf(memory.len);
        const new_class = classOf(new_len);
        if (old_class != null or new_class != null) {
            // In place iff the block's class capacity already covers the new
            // length. A backing-owned block (null old class) must never grow
            // in place into the cacheable range — its capacity is unknown.
            if (old_class == null or new_class == null) return false;
            return old_class.? == new_class.?;
        }
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *BlockCacheAllocator = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() > std.heap.page_size_min) {
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }
        const old_class = classOf(memory.len);
        const new_class = classOf(new_len);
        if (old_class != null or new_class != null) {
            if (old_class == null or new_class == null) return null;
            return if (old_class.? == new_class.?) memory.ptr else null;
        }
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *BlockCacheAllocator = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() > std.heap.page_size_min) {
            return self.backing.rawFree(memory, alignment, ret_addr);
        }
        const class = classOf(memory.len) orelse {
            return self.backing.rawFree(memory, alignment, ret_addr);
        };
        self.mu.lock();
        if (self.counts[class] < class_caps[class]) {
            self.blocks[class][self.counts[class]] = memory.ptr;
            self.counts[class] += 1;
            self.mu.unlock();
            return;
        }
        self.mu.unlock();
        self.backing.rawFree(memory.ptr[0..classSize(class)], block_alignment, ret_addr);
    }
};

test "block cache: round-trips and reuses a large block" {
    var cache = BlockCacheAllocator.init(std.testing.allocator);
    defer cache.deinit();
    const a = cache.allocator();

    const first = try a.alloc(u8, 100_000);
    const first_ptr = first.ptr;
    first[0] = 42;
    first[99_999] = 7;
    a.free(first);

    // Same class (128 KB) — must come back out of the cache.
    const second = try a.alloc(u8, 70_000);
    try std.testing.expectEqual(first_ptr, second.ptr);
    a.free(second);
}

test "block cache: small and huge allocations pass through" {
    var cache = BlockCacheAllocator.init(std.testing.allocator);
    defer cache.deinit();
    const a = cache.allocator();

    const small = try a.alloc(u8, 512);
    a.free(small);
    const huge = try a.alloc(u8, (1 << 26) + 1); // above the largest class
    a.free(huge);
}

test "block cache: in-place resize allowed only within one class" {
    var cache = BlockCacheAllocator.init(std.testing.allocator);
    defer cache.deinit();
    const a = cache.allocator();

    var buf = try a.alloc(u8, 100_000);
    defer a.free(buf);
    // 100_000 and 120_000 both round to the 128 KB class.
    try std.testing.expect(a.resize(buf, 120_000));
    buf.len = 120_000;
    // 200_000 crosses into the 256 KB class — must refuse.
    try std.testing.expect(!a.resize(buf, 200_000));
}
