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
const SpinMutex = @import("sync.zig").SpinMutex;
const hugetlb = @import("hugetlb.zig");

// When hugetlb backing is engaged (see base/hugetlb.zig for the policy and
// the numbers), blocks of 2 MB and up come from explicit hugetlb mmaps
// instead of the backing allocator's PageAllocator path: one 2 MB TLB entry
// replaces 512 4 KB ones and first-touch faults drop 512x. The mappings are
// non-NORESERVE, DONTFORK, and write-prefaulted, so pool/NUMA/cgroup failure
// is reported during setup and the block falls back to the backing allocator
// instead of risking a later SIGBUS. Ownership is tracked
// (`huge_ptrs`/`huge_lens`) so free/resize/remap/deinit munmap these blocks
// instead of handing foreign memory to the backing allocator.
const huge_page_size: usize = hugetlb.huge_page_size;

const min_size_log2: u6 = 16; // 64 KB — the smallest block class
const size_class_count: usize = 11; // 64 KB .. 64 MB
/// Per-class retained-block caps (index = class); bigger classes keep fewer.
const class_caps: [size_class_count]u8 = .{ 8, 8, 8, 8, 8, 8, 8, 4, 2, 1, 1 };
const max_blocks_per_class = 8;

/// Anything ABOVE this is direct-mapped by the backing SmpAllocator
/// (its slab size classes stop at 32 KB; a 33 KB request rounds to the
/// 64 KB power-of-two class, which is past its slab range and goes
/// straight to PageAllocator). That's the cacheable-range floor: a
/// (32 KB, 64 KB] request gets a 64 KB class block here — the unused
/// tail pages are never touched, so they cost nothing — instead of a
/// fresh mmap/munmap per use (measured ~4.6K such cycles per NixOS
/// eval at w=1, one ~36-60 KB parse-scratch block per file).
const direct_map_threshold: usize = 32 * 1024;

fn classSize(class: usize) usize {
    return @as(usize, 1) << (min_size_log2 + @as(u6, @intCast(class)));
}

/// Class index for `len`, or null when `len` is outside the cacheable range.
fn classOf(len: usize) ?usize {
    if (len <= direct_map_threshold) return null;
    const log = @max(std.math.log2_int_ceil(usize, len), min_size_log2);
    if (log >= min_size_log2 + size_class_count) return null;
    return log - min_size_log2;
}

/// Bytes currently parked on the free stacks, across instances (in
/// practice there is one, created in main). Read by `--mem-report` to
/// split "retained by the cache" from "in use by a live allocation"
/// inside the `fix:bigblock` smaps bucket.
pub var retained_bytes: std.atomic.Value(usize) = .init(0);

/// The reuse cache is generic over an instantiated `Vma` region-tracker
/// (see runtime/vma.zig): it registers/retags/unregisters its backing
/// mappings through `Vma.*` so `--mem-report` can attribute them, but
/// carries no knowledge of the app's tag taxonomy itself. Instantiate with
/// the shared `mem_tag.vma`.
pub fn BlockCacheAllocator(comptime Vma: type) type {
    return struct {
        const Self = @This();

        backing: Allocator,
        mu: SpinMutex = .{},
        blocks: [size_class_count][max_blocks_per_class][*]u8 = undefined,
        counts: [size_class_count]u8 = @splat(0),

        /// (ptr, rounded_len) of blocks this cache mmap'd itself with
        /// MAP_HUGETLB. Small fixed table under `mu` — blocks of ≥2 MB
        /// number in the dozens per eval. Full table = fall back to the
        /// backing allocator for further blocks (never lose a free).
        /// Lookups are guarded by a `len >= huge_page_size` check on every path,
        /// so sub-2 MB traffic never scans it.
        huge_ptrs: [max_tracked_huge_blocks]usize = @splat(0),
        huge_lens: [max_tracked_huge_blocks]usize = @splat(0),
        huge_count: usize = 0,

        const max_tracked_huge_blocks = 512;

        /// Record a hugetlb-owned block. Returns false (caller must munmap
        /// and fall back) when the table is full.
        fn hugeTrack(self: *Self, ptr: [*]u8, rounded_len: usize) bool {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.huge_count == max_tracked_huge_blocks) return false;
            self.huge_ptrs[self.huge_count] = @intFromPtr(ptr);
            self.huge_lens[self.huge_count] = rounded_len;
            self.huge_count += 1;
            return true;
        }

        /// Rounded length of a hugetlb-owned block, or null. `remove` drops
        /// the entry (for frees that munmap); lookups for resize/remap keep it.
        fn hugeLookup(self: *Self, ptr: [*]const u8, remove: bool) ?usize {
            const addr = @intFromPtr(ptr);
            self.mu.lock();
            defer self.mu.unlock();
            for (self.huge_ptrs[0..self.huge_count], 0..) |p, i| {
                if (p == addr) {
                    const len = self.huge_lens[i];
                    if (remove) {
                        self.huge_count -= 1;
                        self.huge_ptrs[i] = self.huge_ptrs[self.huge_count];
                        self.huge_lens[i] = self.huge_lens[self.huge_count];
                    }
                    return len;
                }
            }
            return null;
        }

        pub fn init(backing: Allocator) Self {
            return .{ .backing = backing };
        }

        /// Release every retained block back to the backing allocator (or
        /// the OS, for hugetlb-owned blocks).
        pub fn deinit(self: *Self) void {
            self.trim();
        }

        /// Release every *parked* block (free stacks only — live allocations
        /// are untouched) and keep the cache usable. The evaluator's
        /// build-phase release calls this after the heap teardown floods the
        /// stacks with dead segment blocks that would otherwise sit retained
        /// (~200 MB) for the whole build. Thread-safe: the stacks are drained
        /// under `mu`, the frees run outside it.
        pub fn trim(self: *Self) void {
            var drained: [size_class_count][max_blocks_per_class][*]u8 = undefined;
            var drained_counts: [size_class_count]u8 = undefined;
            self.mu.lock();
            for (0..size_class_count) |class| {
                drained_counts[class] = self.counts[class];
                @memcpy(
                    drained[class][0..self.counts[class]],
                    self.blocks[class][0..self.counts[class]],
                );
                self.counts[class] = 0;
            }
            self.mu.unlock();
            for (0..size_class_count) |class| {
                const size = classSize(class);
                for (drained[class][0..drained_counts[class]]) |ptr| {
                    Vma.unregisterRegion(ptr);
                    _ = retained_bytes.fetchSub(size, .monotonic);
                    if (size >= huge_page_size) {
                        // `hugeLookup` takes `mu` itself — must run unlocked.
                        if (self.hugeLookup(ptr, true)) |rounded| {
                            hugetlb.unmap(ptr, rounded);
                            continue;
                        }
                    }
                    self.backing.rawFree(ptr[0..size], block_alignment, @returnAddress());
                }
            }
        }

        pub fn allocator(self: *Self) Allocator {
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

        /// Past SmpAllocator's direct-map threshold, a backing allocation is
        /// its own mmap and worth tracking for RSS attribution (see
        /// runtime/vma.zig); below it rides a shared slab.
        fn trackable(len: usize) bool {
            return len > direct_map_threshold;
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (alignment.toByteUnits() > std.heap.page_size_min) {
                const ptr = self.backing.rawAlloc(len, alignment, ret_addr);
                if (ptr != null and trackable(len)) Vma.registerRegion(ptr.?, len, Vma.alloc_tag);
                return ptr;
            }
            const class = classOf(len) orelse {
                // >64 MB pass-through blocks (the biggest store segments)
                // get their own hugetlb mapping when enabled; a failed mmap
                // (pool exhausted) or a full tracking table falls back.
                if (len >= huge_page_size and hugetlb.wanted()) {
                    if (hugetlb.map(len)) |hp| {
                        const rounded = hugetlb.roundedLen(len);
                        if (self.hugeTrack(hp, rounded)) {
                            if (trackable(len)) Vma.registerRegion(hp, len, Vma.alloc_tag);
                            return hp;
                        }
                        hugetlb.unmap(hp, rounded);
                    }
                }
                const ptr = self.backing.rawAlloc(len, alignment, ret_addr);
                // Outside the class range; >64 MB is still a dedicated mapping.
                if (ptr != null and trackable(len)) Vma.registerRegion(ptr.?, len, Vma.alloc_tag);
                return ptr;
            };
            self.mu.lock();
            if (self.counts[class] > 0) {
                self.counts[class] -= 1;
                const ptr = self.blocks[class][self.counts[class]];
                self.mu.unlock();
                _ = retained_bytes.fetchSub(classSize(class), .monotonic);
                // Reused block: hand it the current owner's attribution tag.
                if (Vma.alloc_tag != Vma.default_tag) Vma.retagRegion(ptr, Vma.alloc_tag);
                return ptr;
            }
            self.mu.unlock();
            // Fresh class blocks of ≥2 MB come from an explicit hugetlb
            // mapping when enabled (clean fallback on pool exhaustion).
            // Class sizes ≥2 MB are 2 MB multiples already.
            if (classSize(class) >= huge_page_size and hugetlb.wanted()) {
                if (hugetlb.map(classSize(class))) |hp| {
                    if (self.hugeTrack(hp, classSize(class))) {
                        Vma.registerRegion(hp, classSize(class), Vma.alloc_tag);
                        return hp;
                    }
                    hugetlb.unmap(hp, classSize(class));
                }
            }
            const ptr = self.backing.rawAlloc(classSize(class), block_alignment, ret_addr);
            // Registered once per backing mmap (cache hits skip this): these
            // blocks back the parse/compile arenas, retained AST arenas, and
            // builtin temp buffers — one bucket for "large allocator blocks".
            // Store segments re-tag themselves on claim (stable_segments.zig).
            if (ptr != null) Vma.registerRegion(ptr.?, classSize(class), Vma.alloc_tag);
            return ptr;
        }

        fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (alignment.toByteUnits() > std.heap.page_size_min) {
                return self.trackResize(self.backing.rawResize(memory, alignment, new_len, ret_addr), memory, new_len);
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
            // Never let the backing allocator resize a block it doesn't own:
            // a hugetlb pass-through (always >64 MB, hence the cheap length
            // guard) resizes in place only when the rounded hugetlb capacity
            // and the pass-through (class-less) routing both hold.
            if (memory.len >= huge_page_size) {
                if (self.hugeLookup(memory.ptr, false)) |rounded| {
                    return classOf(new_len) == null and hugetlb.roundedLen(new_len) == rounded;
                }
            }
            return self.trackResize(self.backing.rawResize(memory, alignment, new_len, ret_addr), memory, new_len);
        }

        /// Keep the attribution registry in step with an in-place resize of a
        /// backing-owned (pass-through) block whose registered length changed.
        fn trackResize(self: *Self, ok: bool, memory: []u8, new_len: usize) bool {
            _ = self;
            if (ok and (trackable(memory.len) or trackable(new_len))) {
                Vma.unregisterRegion(memory.ptr);
                if (trackable(new_len)) Vma.registerRegion(memory.ptr, new_len, Vma.alloc_tag);
            }
            return ok;
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (alignment.toByteUnits() > std.heap.page_size_min) {
                return self.trackRemap(self.backing.rawRemap(memory, alignment, new_len, ret_addr), memory, new_len);
            }
            const old_class = classOf(memory.len);
            const new_class = classOf(new_len);
            if (old_class != null or new_class != null) {
                if (old_class == null or new_class == null) return null;
                return if (old_class.? == new_class.?) memory.ptr else null;
            }
            // See `resize` — the backing allocator must not remap foreign
            // hugetlb mappings.
            if (memory.len >= huge_page_size) {
                if (self.hugeLookup(memory.ptr, false)) |rounded| {
                    const ok = classOf(new_len) == null and hugetlb.roundedLen(new_len) == rounded;
                    return if (ok) memory.ptr else null;
                }
            }
            return self.trackRemap(self.backing.rawRemap(memory, alignment, new_len, ret_addr), memory, new_len);
        }

        /// Registry bookkeeping for a pass-through remap (may move the block).
        fn trackRemap(self: *Self, new_ptr: ?[*]u8, memory: []u8, new_len: usize) ?[*]u8 {
            _ = self;
            if (new_ptr != null and (trackable(memory.len) or trackable(new_len))) {
                Vma.unregisterRegion(memory.ptr);
                if (trackable(new_len)) Vma.registerRegion(new_ptr.?, new_len, Vma.alloc_tag);
            }
            return new_ptr;
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (alignment.toByteUnits() > std.heap.page_size_min) {
                if (trackable(memory.len)) Vma.unregisterRegion(memory.ptr);
                return self.backing.rawFree(memory, alignment, ret_addr);
            }
            const class = classOf(memory.len) orelse {
                if (trackable(memory.len)) Vma.unregisterRegion(memory.ptr);
                // Blocks this cache mmap'd itself must never reach the
                // backing allocator's free (guard: hugetlb pass-throughs
                // are always >64 MB).
                if (memory.len >= huge_page_size) {
                    if (self.hugeLookup(memory.ptr, true)) |rounded|
                        return hugetlb.unmap(memory.ptr, rounded);
                }
                return self.backing.rawFree(memory, alignment, ret_addr);
            };
            self.mu.lock();
            if (self.counts[class] < class_caps[class]) {
                self.blocks[class][self.counts[class]] = memory.ptr;
                self.counts[class] += 1;
                self.mu.unlock();
                _ = retained_bytes.fetchAdd(classSize(class), .monotonic);
                // Parked, not returned to the OS: keep it registered, but
                // drop any subsystem-specific tag it picked up while in use.
                // (Hugetlb-owned blocks stay in the tracking table while
                // parked — a cache-hit reuse hands them out unchanged.)
                Vma.retagRegion(memory.ptr, Vma.default_tag);
                return;
            }
            self.mu.unlock();
            Vma.unregisterRegion(memory.ptr);
            if (classSize(class) >= huge_page_size) {
                if (self.hugeLookup(memory.ptr, true)) |rounded|
                    return hugetlb.unmap(memory.ptr, rounded);
            }
            self.backing.rawFree(memory.ptr[0..classSize(class)], block_alignment, ret_addr);
        }
    };
}

/// A throwaway `Vma` instantiation for the tests below: the cache is generic
/// over its Vma, and these tests only exercise the reuse/passthrough logic, so
/// the attribution taxonomy is irrelevant. The evaluator's real instantiation
/// lives in `nix`'s `mem_tag.zig`.
const TestTag = enum { none };
const TestVma = @import("vma.zig").Vma(TestTag, .none, struct {
    fn n(_: TestTag) [:0]const u8 {
        return "none";
    }
}.n);

test "block cache: round-trips and reuses a large block" {
    var cache = BlockCacheAllocator(TestVma).init(std.testing.allocator);
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
    var cache = BlockCacheAllocator(TestVma).init(std.testing.allocator);
    defer cache.deinit();
    const a = cache.allocator();

    const small = try a.alloc(u8, 512);
    a.free(small);
    const huge = try a.alloc(u8, (1 << 26) + 1); // above the largest class
    a.free(huge);
}

test "block cache: hugetlb-eligible blocks round-trip in every mode" {
    // Exercises the ≥2 MB class path and the >64 MB pass-through with
    // hugetlb forced on. Whether the pool actually serves the mappings
    // (engaged) or not (clean fallback to the backing allocator), the
    // blocks must be usable end to end and every free must reach the
    // right owner — std.testing.allocator flags a leak or a foreign free.
    const saved = hugetlb.getMode();
    hugetlb.setMode(.on);
    defer hugetlb.setMode(saved orelse .off);

    var cache = BlockCacheAllocator(TestVma).init(std.testing.allocator);
    defer cache.deinit();
    const a = cache.allocator();

    // 4 MB class block: write both ends, free (parks it), realloc same class
    // (must come back from the park list), free again (stays parked until
    // cache.deinit, which must munmap-or-rawFree by ownership).
    const blk = try a.alloc(u8, 4 << 20);
    blk[0] = 0xA5;
    blk[(4 << 20) - 1] = 0x5A;
    try std.testing.expectEqual(@as(u8, 0xA5), blk[0]);
    const blk_ptr = blk.ptr;
    a.free(blk);
    const again = try a.alloc(u8, 3 << 20); // same 4 MB class
    try std.testing.expectEqual(blk_ptr, again.ptr);
    a.free(again);

    // >64 MB pass-through: dedicated mapping either way.
    const big = try a.alloc(u8, (64 << 20) + 123);
    big[0] = 1;
    big[(64 << 20) + 122] = 2;
    try std.testing.expectEqual(@as(u8, 2), big[(64 << 20) + 122]);
    // Growing within the same 2 MB-rounded capacity may succeed in place
    // (hugetlb) or not (backing-owned); both are legal answers. Crossing
    // into the class range must always refuse.
    try std.testing.expect(!a.resize(big, 32 << 20));
    a.free(big);

    // Off again: fresh ≥2 MB blocks route to the backing allocator, and a
    // still-live hugetlb block allocated while on would still free correctly
    // (ownership is per-block, not per-mode).
    hugetlb.setMode(.off);
    const off_blk = try a.alloc(u8, 2 << 20);
    off_blk[0] = 7;
    a.free(off_blk);
}

test "block cache: in-place resize allowed only within one class" {
    var cache = BlockCacheAllocator(TestVma).init(std.testing.allocator);
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
