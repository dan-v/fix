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
const SpinMutex = @import("sync.zig").SpinMutex;
const hugetlb = @import("hugetlb.zig");

/// `StableSegments` parameters, generic over the injected `Vma`
/// instantiation so `vma_tag` can name the app's attribution enum without
/// this generic store depending on the taxonomy (see runtime/vma.zig,
/// runtime/mem_tag.zig).
pub fn Params(comptime Vma: type) type {
    return struct {
        /// Size of segment 0 in slots. Must be a power of two ≥ 1.
        first_segment_size: u32,
        /// Cap on the number of segments. Total addressable slots is
        /// `first_segment_size * (2^segment_count - 1)`.
        segment_count: u6 = 28,
        /// RSS-attribution tag for this store's segments (see
        /// runtime/vma.zig): a claimed segment is re-tagged from the
        /// allocator's generic "bigblock" bucket to the store's own, so
        /// `--mem-report` can tell the stores apart. Only segments big
        /// enough to be dedicated mappings (≥64 KB) are tagged; smaller
        /// early segments ride allocator slabs and keep the slab's identity.
        vma_tag: ?Vma.Tag = null,
        /// Segments of at least this many bytes get their own 2 MB-aligned
        /// NORESERVE mapping with a chunk-wise-grown reserved-hugetlb prefix
        /// (the FlatStore scheme) instead of a fully-hugetlb-mapped
        /// allocator block. Geometric doubling makes the tail segment huge
        /// (64–256 MB) and mostly empty at peak, and an up-front hugetlb map
        /// bills the whole segment against the pool — mapped-but-untouched
        /// hugetlb is real pool consumption. 0 = off (every segment through
        /// the allocator, as before). Requires every cursor advance to hold
        /// `write_mu` (`reserve`/`reserveLocal`/`reserveYoung`), so it is
        /// incompatible with `appendAtomic` (enforced at comptime).
        huge_overlay_min: usize = 0,
    };
}

pub fn StableSegments(comptime T: type, comptime params_in: anytype, comptime Vma: type) type {
    // `params_in` is an anonymous struct literal whose `vma_tag` (if any) is an
    // enum literal; copy it into a typed `Params(Vma)` so defaults apply and
    // `vma_tag` is resolved against the injected `Vma.Tag`. A struct value can't
    // coerce across the `anytype` boundary, so copy field-by-field.
    const params: Params(Vma) = blk: {
        var p: Params(Vma) = .{ .first_segment_size = params_in.first_segment_size };
        if (@hasField(@TypeOf(params_in), "segment_count")) p.segment_count = params_in.segment_count;
        if (@hasField(@TypeOf(params_in), "vma_tag")) p.vma_tag = params_in.vma_tag;
        if (@hasField(@TypeOf(params_in), "huge_overlay_min")) p.huge_overlay_min = params_in.huge_overlay_min;
        break :blk p;
    };
    comptime {
        if (T == void) @compileError("StableSegments(void) is unsupported");
        if (params.first_segment_size == 0) @compileError("first_segment_size must be > 0");
        if (!std.math.isPowerOfTwo(params.first_segment_size)) @compileError("first_segment_size must be a power of two");
        if (params.segment_count == 0 or params.segment_count > 32) @compileError("segment_count must be in 1..=32");
    }

    return struct {
        const Self = @This();

        pub const segment_count = params.segment_count;
        pub const first_segment_size = params.first_segment_size;
        const first_log2: u6 = std.math.log2_int(u32, params.first_segment_size);

        pub const Range = struct {
            segment: u32,
            offset: u32,
            len: u32,
        };

        /// Per-worker tenured bump cursor (a thread-local allocation buffer).
        /// Refilled a chunk at a time under `write_mu`; individual reservations
        /// bump the local cursor lock-free. Lets the parallel copying collector
        /// evacuate survivors concurrently without every worker serializing on
        /// the store's global `reserve`. Only the final partial chunk per worker
        /// leaks (its unused tail), so the waste is bounded and tiny.
        pub const Tlab = struct { seg: u32 = 0, off: u32 = 0, used: u32 = 0, cap: u32 = 0 };
        pub const tlab_chunk_size: u32 = 8192;

        /// Reserve `len` slots via `tlab` (tenured). Bumps the local cursor when
        /// the current chunk has room; otherwise refills one chunk under
        /// `write_mu` (or, for an oversized `len`, reserves it directly and
        /// leaves the chunk intact). Not thread-safe on a single `tlab` — each
        /// worker owns its own.
        pub fn reserveLocal(self: *Self, allocator: std.mem.Allocator, tlab: *Tlab, len: u32) !Range {
            if (len == 0) return .{ .segment = 0, .offset = 0, .len = 0 };
            if (tlab.used + len <= tlab.cap) {
                const r: Range = .{ .segment = tlab.seg, .offset = tlab.off + tlab.used, .len = len };
                tlab.used += len;
                return r;
            }
            if (len >= tlab_chunk_size) return self.reserve(allocator, len); // oversized: direct, keep tlab
            const chunk = try self.reserve(allocator, tlab_chunk_size);
            tlab.* = .{ .seg = chunk.segment, .off = chunk.offset, .used = len, .cap = chunk.len };
            return .{ .segment = chunk.segment, .offset = chunk.offset, .len = len };
        }

        /// Cursor packs (segment_index, used_in_segment) into one u64 so we can
        /// load it atomically. The writer mutex is the only mutator, so this
        /// could be plain u64; the atomic wrapper exists so opportunistic
        /// readers (e.g. `count()`) don't tear.
        cursor: std.atomic.Value(u64) = .init(0),
        segments: [segment_count]std.atomic.Value(?[*]T) = blk: {
            var arr: [segment_count]std.atomic.Value(?[*]T) = undefined;
            for (&arr) |*s| s.* = .init(null);
            break :blk arr;
        },
        write_mu: SpinMutex = .{},

        // --- copying-nursery support (GC) ---
        //
        // When `nursery_segs > 0` the low segments `[0, nursery_segs)` form a
        // resettable young-generation arena (its own bump cursor
        // `young_cursor`), and the tenured region is segments
        // `[nursery_segs, segment_count)` (the ordinary `cursor`, pre-positioned
        // by `enableNursery`). A range is "young" iff `range.segment <
        // nursery_segs` — so `slice`/`get` route by segment index with no tag
        // bit and no per-access branch. `resetYoung` rewinds `young_cursor` to
        // reclaim the whole nursery in O(1) after survivors are evacuated out.
        young_cursor: std.atomic.Value(u64) = .init(0),
        nursery_segs: u32 = 0,

        // --- per-segment hugetlb overlay (`params.huge_overlay_min`) ---
        //
        // A self-mapped segment (see `ensureSegment`) is a 2 MB-aligned
        // NORESERVE mapping whose low `[0, seg_huge_frontier[i])` bytes are
        // overlaid with *reserved* hugetlb, grown a chunk at a time under
        // `write_mu` before the cursor moves past it — the exact FlatStore
        // scheme, per segment (see `FlatStore.extendHugeFrontier` for the
        // no-SIGBUS/no-data-loss argument). All zero/false when the feature
        // is off or a segment came from the allocator.
        seg_owned: [segment_count]bool = @splat(false),
        seg_huge_frontier: [segment_count]usize = @splat(0),
        seg_huge_off: [segment_count]bool = @splat(false),

        const overlay_enabled = params.huge_overlay_min > 0;
        const comptime_linux = builtin.os.tag == .linux;
        /// Overlay grow-ahead granularity (matches `FlatParams.huge_chunk`).
        const segment_huge_chunk_size: usize = 32 << 20;

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.segments, 0..) |*atom, i| {
                const ptr = atom.load(.monotonic) orelse continue;
                if (overlay_enabled and self.seg_owned[i]) {
                    if (comptime params.vma_tag != null) Vma.unregisterRegion(@ptrCast(ptr));
                    const bytes: [*]align(page_size_min) u8 = @ptrCast(@alignCast(ptr));
                    // One munmap covers the hugetlb-prefix + normal-tail VMAs;
                    // only the accounting needs to know the hugetlb share.
                    std.posix.munmap(bytes[0..segmentBytes(@intCast(i))]);
                    if (self.seg_huge_frontier[i] > 0) hugetlb.noteUnmapped(self.seg_huge_frontier[i]);
                    self.seg_owned[i] = false;
                    self.seg_huge_frontier[i] = 0;
                    self.seg_huge_off[i] = false;
                } else {
                    allocator.free(ptr[0..segmentCapacity(@intCast(i))]);
                }
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
                    if (seg + 1 >= segment_count) return error.OutOfMemory;
                    seg += 1;
                    used = 0;
                    continue;
                }
                if (used + len <= cap) break;
                if (seg + 1 >= segment_count) return error.OutOfMemory;
                seg += 1;
                used = 0;
            }

            try self.ensureSegment(allocator, seg);
            // Extend the segment's reserved-hugetlb prefix over the range
            // being handed out BEFORE the cursor moves (see the overlay
            // notes above) — while `write_mu` is held, nothing above the
            // frontier has been handed to any caller.
            if (comptime overlay_enabled)
                self.extendSegHugeFrontier(seg, (@as(usize, used) + len) * @sizeOf(T));

            const range: Range = .{ .segment = seg, .offset = used, .len = len };
            self.cursor.store(packCursor(seg, used + len), .release);
            return range;
        }

        /// Partition the store into a young nursery (`[0, nursery_segs)`) and a
        /// tenured region (`[nursery_segs, segment_count)`). Must be called
        /// before any `reserve` (the tenured cursor is moved to the first
        /// tenured segment so ordinary reservations never land in the nursery).
        /// Idempotent-safe only from a fresh (`empty`) store.
        pub fn enableNursery(self: *Self, nursery_segs: u32) void {
            std.debug.assert(nursery_segs > 0 and nursery_segs < segment_count);
            std.debug.assert(self.count() == 0);
            self.nursery_segs = nursery_segs;
            self.young_cursor.store(0, .monotonic);
            self.cursor.store(packCursor(nursery_segs, 0), .release);
        }

        /// Reserve `len` slots in the young nursery. Returns `null` when the
        /// nursery is full (the caller then triggers a minor collection, or
        /// spills to the tenured `reserve`). Never grows past `nursery_segs`.
        pub fn reserveYoung(self: *Self, allocator: std.mem.Allocator, len: u32) !?Range {
            if (len == 0) return Range{ .segment = 0, .offset = 0, .len = 0 };
            self.write_mu.lock();
            defer self.write_mu.unlock();

            const cur = self.young_cursor.load(.monotonic);
            var seg = segmentOf(cur);
            var used = usedOf(cur);
            while (true) {
                if (seg >= self.nursery_segs) return null; // nursery exhausted
                const cap = segmentCapacity(seg);
                if (len <= cap and used + len <= cap) break;
                seg += 1;
                used = 0;
            }
            try self.ensureSegment(allocator, seg);
            // Nursery segments are small (below `huge_overlay_min` in every
            // real instantiation) so this is a no-op there, but keep the
            // invariant uniform: cursor never passes the frontier.
            if (comptime overlay_enabled)
                self.extendSegHugeFrontier(seg, (@as(usize, used) + len) * @sizeOf(T));
            const range: Range = .{ .segment = seg, .offset = used, .len = len };
            self.young_cursor.store(packCursor(seg, used + len), .release);
            return range;
        }

        /// Young slots reserved (high-water within the nursery). O(1).
        pub fn youngCount(self: *const Self) u32 {
            const cur = self.young_cursor.load(.acquire);
            return segmentStart(segmentOf(cur)) + usedOf(cur);
        }

        /// Tenured slots reserved (excludes the nursery capacity that
        /// `count()`'s `segmentStart` would otherwise fold in).
        pub fn tenuredCount(self: *const Self) u32 {
            if (self.nursery_segs == 0) return self.count();
            return self.count() - segmentStart(self.nursery_segs);
        }

        /// Total committed slots across both regions (RSS proxy for the GC
        /// threshold). Excludes the un-backed nursery-capacity gap.
        pub fn reservedSlots(self: *const Self) u32 {
            if (self.nursery_segs == 0) return self.count();
            return self.tenuredCount() + self.youngCount();
        }

        /// Base address + capacity of nursery segment `i` for `MADV_DONTNEED`
        /// on reset. Null if the segment was never touched.
        pub fn nurserySegmentPages(self: *const Self, i: u32) ?[]T {
            const ptr = self.segments[i].load(.monotonic) orelse return null;
            return ptr[0..segmentCapacity(i)];
        }

        /// Is `range` a young (nursery) reservation? True iff it lives in a
        /// nursery segment. Used by the copying collector to decide what to
        /// evacuate.
        pub fn isYoung(self: *const Self, range: Range) bool {
            return self.nursery_segs != 0 and range.segment < self.nursery_segs;
        }

        /// Does raw pointer `ptr` fall inside a nursery segment? For the one
        /// place a bare slice into the store is held (spilled thunk upvalues),
        /// where the owning `(segment, offset)` isn't recorded. O(nursery_segs).
        pub fn isYoungPtr(self: *const Self, ptr: [*]const T) bool {
            if (self.nursery_segs == 0) return false;
            const p = @intFromPtr(ptr);
            var i: u32 = 0;
            while (i < self.nursery_segs) : (i += 1) {
                const seg = self.segments[i].load(.monotonic) orelse continue;
                const base = @intFromPtr(seg);
                if (p >= base and p < base + @as(usize, segmentCapacity(i)) * @sizeOf(T)) return true;
            }
            return false;
        }

        /// Append a single value. Returns its global u32 id.
        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !u32 {
            const range = try self.reserve(allocator, 1);
            const slot = self.segments[range.segment].load(.acquire).?;
            slot[range.offset] = value;
            return globalIdOf(range.segment, range.offset);
        }

        /// Lock-free single-slot append: reserve a slot by CAS-bumping the
        /// cursor (no `write_mu`), ensure its segment exists via a CAS-alloc,
        /// then write the value. Lets many workers register concurrently
        /// without serializing on the writer mutex — the compile hot path
        /// (ChunkRegistry.register) registers ~700K chunks. `count()` stays
        /// accurate (each reserved slot is written by its own call before the
        /// id escapes); a reserved-but-unwritten slot is transient and only
        /// observable by a full-store scan, which never races registration
        /// (scans run at teardown / STW / after eval). NOT for the nursery
        /// variant — asserts no nursery is active.
        pub fn appendAtomic(self: *Self, allocator: std.mem.Allocator, value: T) !u32 {
            // The overlay scheme requires every cursor advance to hold
            // `write_mu` (the frontier must cover a range before it is
            // handed out); this lock-free path can't uphold that.
            comptime if (overlay_enabled) @compileError("appendAtomic is incompatible with huge_overlay_min");
            std.debug.assert(self.nursery_segs == 0);
            while (true) {
                const cur = self.cursor.load(.acquire);
                const seg = segmentOf(cur);
                const used = usedOf(cur);
                const cap = segmentCapacity(seg);
                if (used >= cap) {
                    if (seg + 1 >= segment_count) return error.OutOfMemory;
                    // Advance to the next segment; whoever wins the CAS moves
                    // the cursor, everyone retries and reserves in the new one.
                    _ = self.cursor.cmpxchgWeak(cur, packCursor(seg + 1, 0), .acq_rel, .monotonic);
                    continue;
                }
                if (self.cursor.cmpxchgWeak(cur, packCursor(seg, used + 1), .acq_rel, .monotonic) != null) continue;
                // Won slot (seg, used). Ensure the segment is allocated, then write.
                try self.ensureSegmentAtomic(allocator, seg);
                const slot = self.segments[seg].load(.acquire).?;
                slot[used] = value;
                return globalIdOf(seg, used);
            }
        }

        /// `appendAtomic` for a caller that guarantees NO concurrent writer
        /// exists (a `--workers=1` evaluator): the same cursor/segment
        /// protocol with plain-cost monotonic accesses instead of the CAS.
        /// Concurrent readers (`get`/`count` from samplers or post-eval
        /// walkers) stay well-defined — monotonic keeps the accesses atomic,
        /// it just drops the RMW and fences.
        pub fn appendSerial(self: *Self, allocator: std.mem.Allocator, value: T) !u32 {
            std.debug.assert(self.nursery_segs == 0);
            const cur = self.cursor.load(.monotonic);
            var seg = segmentOf(cur);
            var used = usedOf(cur);
            if (used >= segmentCapacity(seg)) {
                if (seg + 1 >= segment_count) return error.OutOfMemory;
                seg += 1;
                used = 0;
            }
            try self.ensureSegment(allocator, seg);
            const slot = self.segments[seg].load(.monotonic).?;
            slot[used] = value;
            self.cursor.store(packCursor(seg, used + 1), .release);
            return globalIdOf(seg, used);
        }

        /// Allocate `segment`'s backing buffer if absent, racing-safe: the CAS
        /// loser frees its buffer and uses the winner's.
        fn ensureSegmentAtomic(self: *Self, allocator: std.mem.Allocator, segment: u32) !void {
            if (self.segments[segment].load(.acquire) != null) return;
            const cap = segmentCapacity(segment);
            const buf = try allocator.alloc(T, cap);
            if (self.segments[segment].cmpxchgStrong(null, buf.ptr, .acq_rel, .acquire) != null) {
                allocator.free(buf);
                return;
            }
            nameSegment(buf);
        }

        /// Re-tag a freshly-claimed segment's backing region for RSS
        /// attribution (no-op unless `params.vma_tag` is set and the
        /// segment is a dedicated mapping — see runtime/vma.zig).
        fn nameSegment(buf: []T) void {
            if (comptime params.vma_tag) |tag| {
                const bytes = buf.len * @sizeOf(T);
                if (bytes < (64 << 10)) return;
                Vma.retagRegion(buf.ptr, tag);
            }
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

        /// `get`, tolerating id space whose segment was never allocated —
        /// with the collector the low nursery segments stay null until arming, so
        /// a linear id walk (diagnostics/stats) crosses a hole. Returns
        /// null there and sets `next_id.*` to the first id of the next
        /// segment so walkers skip the hole in O(1).
        pub fn getIfAllocated(self: *const Self, id: u32, next_id: *u32) ?*const T {
            const loc = locationOf(id);
            const seg_ptr = self.segments[loc.segment].load(.acquire) orelse {
                next_id.* = segmentStart(loc.segment) + segmentCapacity(loc.segment);
                return null;
            };
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

        /// Cross-call state for `populateAhead` (segment base + populated-to).
        pub const PopulateState = struct { base: usize = 0, populated: usize = 0 };

        /// Pre-populate (`madv_populate_write`) the cursor's segment up to
        /// `ahead` bytes past the current fill point. Kernel-side and
        /// value-preserving, so it is race-free against concurrent
        /// writers; called from the heap's background pre-toucher to
        /// absorb the store's first-touch minor faults. Only segments of
        /// >=1 MB are touched (they are dedicated page-aligned mappings;
        /// smaller ones ride allocator slabs that are already warm).
        pub fn populateAhead(self: *const Self, state: *PopulateState, ahead: usize) void {
            if (comptime builtin.os.tag != .linux) return;
            const page = std.heap.page_size_min;
            const cur = self.cursor.load(.acquire);
            const seg = segmentOf(cur);
            const used = @as(usize, usedOf(cur)) * @sizeOf(T);
            const cap = @as(usize, segmentCapacity(seg)) * @sizeOf(T);
            if (cap < (1 << 20)) return;
            const ptr = self.segments[seg].load(.acquire) orelse return;
            const base = @intFromPtr(ptr);
            if (base & (page - 1) != 0) return;
            if (state.base != base) state.* = .{ .base = base, .populated = std.mem.alignForward(usize, used, page) };
            var target = std.mem.alignForward(usize, @min(used + ahead, cap), page);
            // Self-mapped overlay segment: don't populate past the hugetlb
            // frontier while it is still growing (see FlatStore.populateRange
            // — 4 KB pages there get discarded by the next overlay and
            // re-faulted huge; racy monotonic read only under-populates).
            if (comptime overlay_enabled) {
                if (self.seg_owned[seg] and !@atomicLoad(bool, &self.seg_huge_off[seg], .monotonic)) {
                    target = @min(target, @atomicLoad(usize, &self.seg_huge_frontier[seg], .monotonic));
                }
            }
            if (target <= state.populated) return;
            const madv_populate_write: u32 = 23;
            const addr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(base + state.populated);
            _ = std.os.linux.madvise(addr, target - state.populated, madv_populate_write);
            state.populated = target;
        }

        /// Translate a global id to (segment, offset).
        pub fn locationOf(id: u32) Range {
            // segment_start(i) = FIRST * (2^i - 1), so the segment containing
            // id is the largest i with segment_start(i) ≤ id. Equivalent:
            //   i = floor(log2((id / FIRST) + 1))
            const shifted = (id >> first_log2) + 1;
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
            if (comptime overlay_enabled and comptime_linux) {
                if (self.mapOwnedSegment(segment)) return;
            }
            const cap = segmentCapacity(segment);
            const buf = try allocator.alloc(T, cap);
            self.segments[segment].store(buf.ptr, .release);
            nameSegment(buf);
        }

        fn segmentBytes(segment: u32) usize {
            return @as(usize, segmentCapacity(segment)) * @sizeOf(T);
        }

        /// Self-map a big segment (see `Params.huge_overlay_min`): a
        /// 2 MB-aligned NORESERVE reservation whose hugetlb prefix
        /// `extendSegHugeFrontier` grows chunk-wise as the cursor advances.
        /// Returns false (caller falls back to the allocator, behavior
        /// unchanged) when the segment is small, hugetlb isn't engaged, the
        /// size doesn't split into whole huge pages, or the mmap fails.
        fn mapOwnedSegment(self: *Self, segment: u32) bool {
            const bytes = segmentBytes(segment);
            if (bytes < params.huge_overlay_min) return false;
            if (bytes % hugetlb.huge_page_size != 0) return false;
            if (!hugetlb.wanted()) return false;
            // Over-reserve by one huge page and trim to a 2 MB-aligned
            // window (a MAP_FIXED hugetlb overlay needs an aligned target).
            const mem = std.posix.mmap(
                null,
                bytes + hugetlb.huge_page_size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            ) catch return false;
            const raw = @intFromPtr(mem.ptr);
            const base = std.mem.alignForward(usize, raw, hugetlb.huge_page_size);
            if (base > raw) {
                const head: [*]align(page_size_min) u8 = @ptrFromInt(raw);
                std.posix.munmap(head[0 .. base - raw]);
            }
            const tail_start = base + bytes;
            const tail_end = raw + bytes + hugetlb.huge_page_size;
            if (tail_end > tail_start) {
                const tail: [*]align(page_size_min) u8 = @ptrFromInt(tail_start);
                std.posix.munmap(tail[0 .. tail_end - tail_start]);
            }
            const seg_ptr: [*]T = @ptrFromInt(base);
            if (comptime params.vma_tag) |tag| Vma.registerRegion(@ptrCast(seg_ptr), bytes, tag);
            self.seg_owned[segment] = true;
            self.seg_huge_frontier[segment] = 0;
            self.seg_huge_off[segment] = false;
            self.segments[segment].store(seg_ptr, .release);
            return true;
        }

        /// Grow segment `segment`'s reserved-hugetlb prefix to cover at
        /// least `need_bytes` (plus a chunk of lookahead). Only meaningful
        /// under `write_mu` before the cursor is published — the FlatStore
        /// invariant, per segment: everything at or above the frontier is
        /// unhanded-out, so `overlayFixed`'s replace loses no data. Any
        /// failure stops growth for this segment permanently; its tail then
        /// lives on ordinary pages like a non-hugetlb run.
        fn extendSegHugeFrontier(self: *Self, segment: u32, need_bytes: usize) void {
            if (!self.seg_owned[segment] or self.seg_huge_off[segment]) return;
            const frontier = self.seg_huge_frontier[segment];
            if (need_bytes <= frontier) return;
            const limit = segmentBytes(segment); // whole huge pages by construction
            const want = @max(need_bytes, frontier +| segment_huge_chunk_size);
            const target = @min(std.mem.alignForward(usize, want, hugetlb.huge_page_size), limit);
            if (target <= frontier or target < need_bytes) {
                @atomicStore(bool, &self.seg_huge_off[segment], true, .monotonic);
                return;
            }
            const basep: [*]u8 = @ptrCast(self.segments[segment].load(.monotonic).?);
            // Atomic stores pair with the pre-toucher's racy reads in
            // `populateAhead`; a stale read only under-populates.
            if (hugetlb.overlayFixed(basep + frontier, target - frontier)) {
                @atomicStore(usize, &self.seg_huge_frontier[segment], target, .monotonic);
                if (target == limit) @atomicStore(bool, &self.seg_huge_off[segment], true, .monotonic);
            } else {
                // Pool exhausted (or shrank): the tail continues on normal
                // pages; data below the frontier stays on reserved pages.
                @atomicStore(bool, &self.seg_huge_off[segment], true, .monotonic);
            }
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

pub fn FlatParams(comptime Vma: type) type {
    return struct {
        /// Virtual address space to reserve, in slots. The whole region is
        /// mapped up front (MAP_NORESERVE — only touched pages cost physical
        /// memory) and never relocated, so a slot's address is stable for the
        /// store's lifetime and reads need no synchronization on the base.
        max_slots: u32,
        /// RSS-attribution tag for the reservation (see `Params.vma_tag`);
        /// registered at init since the flat store owns its mmap directly.
        vma_tag: ?Vma.Tag = null,
        /// Hugetlb grow-ahead granularity (see `extendHugeFrontier`): the
        /// reserved huge-page prefix grows in chunks of this many bytes.
        /// Small enough that a run only over-reserves one chunk of pool
        /// (mapped-but-untouched hugetlb is real pool consumption — it
        /// counts against the footprint and starves other mappings), big
        /// enough that extension mmaps stay rare (an overlay is one
        /// mmap+mremap under the already-held write lock; a ~1 GB store
        /// crosses a 32 MB frontier ~30 times per run). Tests shrink it to
        /// exercise many frontier crossings on a small store.
        huge_chunk: usize = 32 << 20,
    };
}

/// Append-only flat storage backed by a single mmap-reserved contiguous
/// region. A drop-in replacement for `StableSegments` *for flat-id*
/// entities (the object store): `get(id)` is one load — `base[id]` — with
/// no segment decode, no per-access atomic. The trade vs `StableSegments`
/// is a fixed virtual reservation instead of geometric segment growth; it
/// only suits stores referenced solely by flat id (never via `Range`/
/// `slice` handed out externally).
///
/// Thread safety:
///   - `base` is set once in `init` (single-threaded, before any worker
///     spawns) and never changes, so `get`/`getMut` are plain loads.
///   - `reserve` bumps `cursor` under `write_mu`; concurrent readers only
///     ever touch ids already published through the value/state release
///     that made them reachable, which happens-after the slot was filled.
///
/// Huge pages: when hugetlb backing is engaged (base/hugetlb.zig), the low
/// bytes of the reservation are overlaid with *reserved* (non-NORESERVE)
/// 2 MB pages, grown chunk-wise ahead of the cursor under `write_mu` — see
/// `extendHugeFrontier` for the no-SIGBUS/no-data-loss invariants. Any
/// failure degrades that store's tail to ordinary pages.
pub fn FlatStore(comptime T: type, comptime params_in: anytype, comptime Vma: type) type {
    // See `StableSegments`: copy the anonymous literal into a typed
    // `FlatParams(Vma)` so `vma_tag` resolves against the injected `Vma.Tag`.
    const params: FlatParams(Vma) = blk: {
        var p: FlatParams(Vma) = .{ .max_slots = params_in.max_slots };
        if (@hasField(@TypeOf(params_in), "vma_tag")) p.vma_tag = params_in.vma_tag;
        if (@hasField(@TypeOf(params_in), "huge_chunk")) p.huge_chunk = params_in.huge_chunk;
        break :blk p;
    };
    comptime {
        if (T == void) @compileError("FlatStore(void) is unsupported");
        if (params.max_slots == 0) @compileError("max_slots must be > 0");
    }

    return struct {
        const Self = @This();

        pub const max_slots = params.max_slots;

        /// Range shape mirrors `StableSegments.Range` so the heap's TLAB
        /// code is store-agnostic. `segment` is always 0 here (one flat
        /// region); `offset` is the global id.
        pub const Range = struct {
            segment: u32,
            offset: u32,
            len: u32,
        };

        /// Base of the mmap-reserved region. Immutable after `init`.
        base: [*]T,
        /// Next free slot. Bumped under `write_mu`; loaded atomically by
        /// `count()` so an opportunistic reader doesn't tear.
        cursor: std.atomic.Value(u32),
        write_mu: SpinMutex,
        /// Hugetlb prefix frontier: bytes `[0, huge_frontier)` of the
        /// reservation are backed by reserved, DONTFORK, write-prefaulted
        /// huge pages, so pool/NUMA/cgroup failure can only fail a frontier
        /// extension (handled), never a later touch. Always a 2 MB multiple;
        /// mutated only under `write_mu`.
        huge_frontier: usize,
        /// Set when the prefix can't grow further (mode off, pool exhausted,
        /// or the overlayable range is used up): the rest of the store stays
        /// on ordinary 4 KB pages, permanently — which also upholds the
        /// overlay-never-covers-data invariant (see `extendHugeFrontier`).
        huge_grow_off: bool,

        const byte_count: usize = @as(usize, params.max_slots) * @sizeOf(T);
        /// Only whole huge pages can be overlaid; a sub-2 MB tail stays normal.
        const huge_limit: usize = std.mem.alignBackward(usize, byte_count, hugetlb.huge_page_size);
        const huge_chunk_size: usize = params.huge_chunk;

        pub fn init() !Self {
            var self: Self = .{
                .base = undefined,
                .cursor = .init(0),
                .write_mu = .{},
                .huge_frontier = 0,
                .huge_grow_off = true,
            };
            const use_huge = comptime_linux and huge_limit >= hugetlb.huge_page_size and
                byte_count % page_size_min == 0 and hugetlb.wanted();
            const mem: [*]align(page_size_min) u8 = if (use_huge) blk: {
                // A hugetlb overlay (MAP_FIXED) needs a 2 MB-aligned target,
                // so over-reserve by one huge page and trim to an aligned
                // window. Failure of the aligned dance falls through to the
                // plain mapping (`huge_grow_off` stays set).
                if (initAligned()) |ptr| {
                    self.huge_grow_off = false;
                    break :blk ptr;
                }
                break :blk try plainMap();
            } else try plainMap();
            if (comptime params.vma_tag) |tag| Vma.registerRegion(mem, byte_count, tag);
            self.base = @ptrCast(@alignCast(mem));
            return self;
        }

        const comptime_linux = builtin.os.tag == .linux;

        fn plainMap() ![*]align(page_size_min) u8 {
            const mem = std.posix.mmap(
                null,
                byte_count,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            ) catch return error.OutOfMemory;
            return mem.ptr;
        }

        /// Reserve `byte_count` of ordinary NORESERVE address space whose base is
        /// 2 MB-aligned: map one huge page extra, trim the misaligned head
        /// and the surplus tail. Null on mmap failure (caller falls back).
        fn initAligned() ?[*]align(page_size_min) u8 {
            const mem = std.posix.mmap(
                null,
                byte_count + hugetlb.huge_page_size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            ) catch return null;
            const raw = @intFromPtr(mem.ptr);
            const base = std.mem.alignForward(usize, raw, hugetlb.huge_page_size);
            if (base > raw) {
                const head: [*]align(page_size_min) u8 = @ptrFromInt(raw);
                std.posix.munmap(head[0 .. base - raw]);
            }
            const tail_start = base + byte_count;
            const tail_end = raw + byte_count + hugetlb.huge_page_size;
            if (tail_end > tail_start) {
                const tail: [*]align(page_size_min) u8 = @ptrFromInt(tail_start);
                std.posix.munmap(tail[0 .. tail_end - tail_start]);
            }
            return @ptrFromInt(base);
        }

        /// `allocator` is accepted for API parity with `StableSegments`
        /// (the heap calls `deinit(allocator)` uniformly); the flat store
        /// owns mmap memory, not allocator memory, so it's ignored.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            if (comptime params.vma_tag != null) Vma.unregisterRegion(self.base);
            const bytes: [*]align(page_size_min) u8 = @ptrCast(@alignCast(self.base));
            // One munmap covers the mixed hugetlb-prefix + normal-tail VMAs
            // (both are whole VMAs within the range); only the accounting
            // needs to know how much of it was hugetlb.
            std.posix.munmap(bytes[0..byte_count]);
            if (self.huge_frontier > 0) hugetlb.noteUnmapped(self.huge_frontier);
            self.huge_frontier = 0;
            self.huge_grow_off = true;
            self.cursor.store(0, .monotonic);
        }

        /// Reserve `len` consecutive slots. `allocator` ignored (see
        /// `deinit`). The returned `Range.offset` is the global id of the
        /// first slot.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, len: u32) !Range {
            _ = allocator;
            if (len == 0) return .{ .segment = 0, .offset = 0, .len = 0 };
            self.write_mu.lock();
            defer self.write_mu.unlock();
            const start = self.cursor.load(.monotonic);
            if (start > params.max_slots - len) return error.OutOfMemory;
            if (comptime comptime_linux) {
                if (!self.huge_grow_off) {
                    const end_bytes = @as(usize, start + len) * @sizeOf(T);
                    if (end_bytes > self.huge_frontier) self.extendHugeFrontier(end_bytes);
                }
            }
            self.cursor.store(start + len, .release);
            return .{ .segment = 0, .offset = start, .len = len };
        }

        /// Grow the reserved huge-page prefix to cover at least `need_bytes`
        /// (plus a chunk of lookahead) by overlaying `[huge_frontier,
        /// target)` with MAP_FIXED hugetlb. Called under `write_mu` *before*
        /// the cursor moves, which is what makes the overlay safe: while
        /// growth is on, every previously handed-out byte lies below
        /// `huge_frontier` (inductive — each reserve either fit under the
        /// frontier or extended it first), so the replaced range holds no
        /// data. The background pre-toucher (`populateRange`) may have
        /// populated pages above the frontier, but only with kernel zeroes —
        /// discarding them is harmless. Any failure (or running past
        /// `huge_limit`) permanently stops growth so the invariant can never
        /// be violated later; the store's tail then lives on normal pages
        /// exactly like a non-hugetlb run.
        fn extendHugeFrontier(self: *Self, need_bytes: usize) void {
            const want = @max(need_bytes, self.huge_frontier +| huge_chunk_size);
            const target = @min(std.mem.alignForward(usize, want, hugetlb.huge_page_size), huge_limit);
            if (target <= self.huge_frontier or target < need_bytes) {
                // Out of overlayable range (the ≥huge_limit tail): stop for good.
                @atomicStore(bool, &self.huge_grow_off, true, .monotonic);
                return;
            }
            const basep: [*]u8 = @ptrCast(self.base);
            // Atomic stores pair with the pre-toucher's racy frontier reads
            // (`populateRange`); ordering is irrelevant — a stale read only
            // under-populates.
            if (hugetlb.overlayFixed(basep + self.huge_frontier, target - self.huge_frontier)) {
                @atomicStore(usize, &self.huge_frontier, target, .monotonic);
                if (target == huge_limit) @atomicStore(bool, &self.huge_grow_off, true, .monotonic);
            } else {
                // Pool exhausted (or shrank): the tail continues on normal
                // pages. Data below the frontier stays on reserved huge
                // pages — still guaranteed by the kernel.
                @atomicStore(bool, &self.huge_grow_off, true, .monotonic);
            }
        }

        pub fn get(self: *const Self, id: u32) *const T {
            return &self.base[id];
        }

        pub fn getMut(self: *Self, id: u32) *T {
            return &self.base[id];
        }

        /// Total slots reserved. Approximate under concurrent writers
        /// (cursor moves at reserve end, so an in-flight reserve isn't
        /// reflected) — same contract as `StableSegments.count`.
        pub fn count(self: *const Self) u32 {
            return self.cursor.load(.acquire);
        }

        /// Bytes of the reservation currently in use.
        pub fn usedBytes(self: *const Self) usize {
            return @as(usize, self.count()) * @sizeOf(T);
        }

        /// Fault in (as-if-written) reservation bytes `[from, to)` via
        /// `madv_populate_write` — kernel-side pre-population that never
        /// modifies data, so it is race-free against concurrent writers.
        /// Clamped to the reservation; best-effort (Linux-only no-op
        /// elsewhere). Lets a background thread absorb the store's
        /// first-touch minor faults off the evaluating thread.
        pub fn populateRange(self: *Self, from: usize, to: usize) void {
            if (comptime builtin.os.tag != .linux) return;
            const madv_populate_write: u32 = 23;
            const lo = std.mem.alignBackward(usize, @min(from, byte_count), page_size_min);
            var hi = std.mem.alignForward(usize, @min(to, byte_count), page_size_min);
            // Never populate past the hugetlb frontier while the prefix is
            // still growing: those would be ordinary 4 KB pages that the next
            // overlay discards and re-faults as huge pages — pure double-fault
            // waste. Racy read is fine (the frontier only grows; a stale value
            // just populates less). Once growth stops (`huge_grow_off`) the
            // tail is permanently ordinary pages and populating helps again.
            if (!@atomicLoad(bool, &self.huge_grow_off, .monotonic)) {
                hi = @min(hi, @atomicLoad(usize, &self.huge_frontier, .monotonic));
            }
            if (hi <= lo) return;
            const bytes: [*]align(page_size_min) u8 = @ptrCast(@alignCast(self.base));
            _ = std.os.linux.madvise(bytes + lo, hi - lo, madv_populate_write);
        }

        /// A flat store has a single region, so the global id IS the
        /// offset. `segment` must be 0 (the only value `reserve` produces).
        pub fn globalIdOf(segment: u32, offset: u32) u32 {
            std.debug.assert(segment == 0);
            return offset;
        }
    };
}

const page_size_min = std.heap.page_size_min;

/// A throwaway `Vma` instantiation for the tests below (none of which tag
/// their stores, so the taxonomy is irrelevant — they just need a type to
/// satisfy the `Vma` parameter).
const TestTag = enum { none };
const TestVma = @import("vma.zig").Vma(TestTag, .none, struct {
    fn n(_: TestTag) [:0]const u8 {
        return "none";
    }
}.n);

test "stable segments: append and get" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 4 }, TestVma).empty;
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
    var seg = StableSegments(u8, .{ .first_segment_size = 4 }, TestVma).empty;
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
    var seg = StableSegments(u32, .{ .first_segment_size = 8 }, TestVma).empty;
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
    var seg = StableSegments(u32, .{ .first_segment_size = 4 }, TestVma).empty;
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
    const Seg = StableSegments(u32, .{ .first_segment_size = 4 }, TestVma);
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
    const Seg = StableSegments(u64, .{ .first_segment_size = 16 }, TestVma);
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

test "flat store: reserve, fill, get round-trip" {
    var store = try FlatStore(u64, .{ .max_slots = 4096 }, TestVma).init();
    defer store.deinit(std.testing.allocator);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const r = try store.reserve(std.testing.allocator, 1);
        try std.testing.expectEqual(@as(u32, 0), r.segment);
        try std.testing.expectEqual(i, r.offset);
        store.getMut(r.offset).* = @as(u64, i) * 7;
    }
    try std.testing.expectEqual(@as(u32, 1000), store.count());
    i = 0;
    while (i < 1000) : (i += 1) {
        try std.testing.expectEqual(@as(u64, i) * 7, store.get(i).*);
    }
}

test "flat store: multi-slot reservation is contiguous" {
    const Store = FlatStore(u32, .{ .max_slots = 256 }, TestVma);
    var store = try Store.init();
    defer store.deinit(std.testing.allocator);

    const r1 = try store.reserve(std.testing.allocator, 3);
    try std.testing.expectEqual(@as(u32, 0), r1.offset);
    const r2 = try store.reserve(std.testing.allocator, 5);
    try std.testing.expectEqual(@as(u32, 3), r2.offset);
    try std.testing.expectEqual(@as(u32, 8), store.count());
    try std.testing.expectEqual(@as(u32, 5), Store.globalIdOf(0, 5));
}

test "flat store: reserve past capacity errors without relocating" {
    var store = try FlatStore(u32, .{ .max_slots = 8 }, TestVma).init();
    defer store.deinit(std.testing.allocator);

    const r = try store.reserve(std.testing.allocator, 8);
    try std.testing.expectEqual(@as(u32, 0), r.offset);
    try std.testing.expectError(error.OutOfMemory, store.reserve(std.testing.allocator, 1));
    // The successfully-reserved slots remain addressable after the failure.
    store.getMut(7).* = 0xDEAD;
    try std.testing.expectEqual(@as(u32, 0xDEAD), store.get(7).*);
}

test "flat store: hugetlb prefix — data intact across many frontier crossings" {
    if (comptime builtin.os.tag != .linux) return;
    // Force hugetlb on with a tiny 2 MB grow-ahead chunk over an 8 MB store,
    // so reserves cross the frontier several times. Whether the pool serves
    // the overlays (this box) or every extension fails (no pool: first
    // extension falls back, store behaves plainly), the data written before,
    // at, and after each crossing must round-trip — this is the invariant
    // that the MAP_FIXED overlay never covers handed-out slots.
    const saved = hugetlb.getMode();
    hugetlb.setMode(.on);
    defer hugetlb.setMode(saved orelse .off);

    const Store = FlatStore(u64, .{ .max_slots = 1 << 20, .huge_chunk = 2 << 20 }, TestVma);
    var store = try Store.init();
    defer store.deinit(std.testing.allocator);

    // Mixed-size reservations so range ends land on both sides of 2 MB lines.
    var next: u32 = 0;
    const lens = [_]u32{ 1, 7, 4093, 262144, 3, 262143, 65536 };
    var li: usize = 0;
    while (next < (1 << 20) - 262145) {
        const len = lens[li % lens.len];
        li += 1;
        const r = try store.reserve(std.testing.allocator, len);
        try std.testing.expectEqual(next, r.offset);
        const s = r.offset;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            store.getMut(s + i).* = @as(u64, s + i) *% 0x9E3779B97F4A7C15;
        }
        next += len;
    }
    var id: u32 = 0;
    while (id < next) : (id += 1) {
        try std.testing.expectEqual(@as(u64, id) *% 0x9E3779B97F4A7C15, store.get(id).*);
    }
}

test "flat store: concurrent reserves are race-free" {
    const Store = FlatStore(u64, .{ .max_slots = 4096 }, TestVma);
    var store = try Store.init();
    defer store.deinit(std.testing.allocator);

    const Worker = struct {
        fn run(s: *Store, worker_id: u64, per_worker: u32) void {
            var i: u32 = 0;
            while (i < per_worker) : (i += 1) {
                const r = s.reserve(std.testing.allocator, 1) catch return;
                s.getMut(r.offset).* = (worker_id << 32) | i;
            }
        }
    };

    const worker_count: u8 = 4;
    const per_worker: u32 = 250;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &store, @as(u64, @intCast(i)), per_worker });
    }
    for (&threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, worker_count * per_worker), store.count());

    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    var id: u32 = 0;
    while (id < store.count()) : (id += 1) {
        const v = store.get(id).*;
        try std.testing.expect(!seen.contains(v));
        try seen.put(v, {});
    }
    try std.testing.expectEqual(@as(usize, worker_count * per_worker), seen.count());
}
