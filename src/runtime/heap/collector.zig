//! GC collector driver for `ObjectHeap`: marking, generational sweep, and
//! threshold policy over the heap's storage model.
//!
//! These are free functions over `heap: *ObjectHeap` rather than methods (Zig
//! cannot add methods to a struct from another file). Hot allocation helpers
//! remain on `ObjectHeap` so they inline at their call sites.
//!

const std = @import("std");
const heap_mod = @import("../heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const HeapLocal = heap_mod.HeapLocal;
const Object = heap_mod.Object;
const ObjectId = heap_mod.ObjectId;
const Value = @import("../value.zig").Value;

const gc_debug = heap_mod.gc_debug;

pub const SweepStats = struct {
    objects_freed: u64 = 0,
};

const FreeRange = struct {
    segment: u32,
    offset: u32,
    len: u32,
};

/// Collection-local streaming coalescer. Sweep order follows allocation order
/// closely (exactly on one worker, per-worker for a parallel minor), so adjacent
/// dead owners normally arrive consecutively. Holding one interval per store
/// merges those runs with no per-range allocation, sorting, or address hash.
const RangeBatch = struct {
    heap: *ObjectHeap,
    fixed_dst: ?*HeapLocal,
    shard: usize = 0,
    values: ?FreeRange = null,
    attrs: ?FreeRange = null,
    attr_pos: ?FreeRange = null,

    fn global(heap: *ObjectHeap) RangeBatch {
        return .{ .heap = heap, .fixed_dst = null };
    }

    fn local(heap: *ObjectHeap, dst: *HeapLocal) RangeBatch {
        return .{ .heap = heap, .fixed_dst = dst };
    }

    fn add(self: *RangeBatch, comptime pending_field: []const u8, comptime free_field: []const u8, range: FreeRange) void {
        const pending = &@field(self, pending_field);
        if (pending.*) |*last| {
            if (last.segment == range.segment and last.offset + last.len == range.offset) {
                last.len += range.len;
                return;
            }
            if (last.segment == range.segment and range.offset + range.len == last.offset) {
                last.offset = range.offset;
                last.len += range.len;
                return;
            }
            self.emit(free_field, last.*);
        }
        pending.* = range;
    }

    fn emit(self: *RangeBatch, comptime free_field: []const u8, range: FreeRange) void {
        const dst = self.fixed_dst orelse blk: {
            const selected = &self.heap.worker_locals[self.shard];
            self.shard += 1;
            if (self.shard == self.heap.worker_locals.len) self.shard = 0;
            break :blk selected;
        };
        @field(dst, free_field).push(self.heap.allocator, range.segment, range.offset, range.len);
    }

    fn flushOne(self: *RangeBatch, comptime pending_field: []const u8, comptime free_field: []const u8) void {
        const pending = &@field(self, pending_field);
        if (pending.*) |range| self.emit(free_field, range);
        pending.* = null;
    }

    fn flush(self: *RangeBatch) void {
        self.flushOne("values", "gc_free_values");
        self.flushOne("attrs", "gc_free_attrs");
        self.flushOne("attr_pos", "gc_free_attr_pos");
    }
};

/// Free every filled object that `mark_bits` left unmarked. Must run at a
/// safepoint with no concurrent allocation.
pub fn sweep(heap: *ObjectHeap, mark_bits: []const u64) SweepStats {
    var stats: SweepStats = .{};
    var ranges = RangeBatch.global(heap);
    if (comptime !gc_debug) heap.gcReconstructAllocBits();
    if (comptime gc_debug) verifyMarkClosed(heap, mark_bits);
    const object_count = heap.objects.count();
    const shard_count = heap.worker_locals.len;
    var shard: usize = 0;
    var id: ObjectId = 0;
    while (id < object_count) : (id += 1) {
        const word = id >> 6;
        if (word >= heap.collection.alloc_bits.len) break;
        const bit = @as(u64, 1) << @intCast(id & 63);
        if (heap.collection.alloc_bits[word] & bit == 0) continue;
        const is_marked = word < mark_bits.len and (mark_bits[word] & bit != 0);
        if (is_marked) continue;
        const local = &heap.worker_locals[shard];
        freeObjectRanges(heap, &ranges, heap.objects.get(id));
        heap.collection.alloc_bits[word] &= ~bit;
        local.gc_free_objects.append(heap.allocator, id) catch {};
        stats.objects_freed += 1;
        shard += 1;
        if (shard >= shard_count) shard = 0;
    }
    ranges.flush();
    return stats;
}

/// Turn on reclaim (alloc-bitmap maintenance + free-list reuse + sweep)
/// with a memory `budget` (the reserved-bytes ceiling the collector
/// defends — see `ObjectHeap.collection.budget_bytes`). `step_bytes` > 0 is the
/// validation override: collect every that-many bytes of fresh allocation
/// from a low starting threshold, ignoring the budget.
pub fn enableCollect(heap: *ObjectHeap, budget: u64, step_bytes: u64) void {
    heap.collection.step_bytes = step_bytes;
    heap.collection.budget_bytes = budget;
    // Collect after fresh reservations cross the configured threshold.
    heap.collection.threshold_bytes = if (step_bytes > 0) heap.totalReservedBytes() + step_bytes else budget;
    // Validation path arms eagerly (bootstrap_end == the arming count, so the
    // pre-arming region is empty), but turn on constrained mode so the always-
    // on transient-root gates are exercised. `armTracking` enables root tracking.
    heap.collection.bootstrap_end = heap.objects.count();
    heap.collection.root_always = true;
    // Detector: presize the alloc bitmap here, like the constrained `enableBudget`
    // path. `armTracking` only presizes outside constrained mode, so without this
    // the eager step path would arm with a ZERO-length bitmap — every per-fill
    // `gcSetAllocBit` would silently drop its bit (word >= len) and the very
    // first tracked read would false-trap "read after sweep". (`armTracking`
    // below then skips its own presize, preserving this freshly-zeroed map.)
    if (comptime gc_debug) heap.gcPresizeAllocBits();
    armTracking(heap);
}

/// Lazy variant (the production collection-line policy, see
/// `gc_controller.memoryBudget`): don't start any per-allocation tracking yet — just
/// watch the reserved-bytes cursor. At half the line the safepoint driver arms
/// tracking (STW, `armTracking`); at the line it collects. A run that never
/// reaches line/2 pays ZERO tracking cost (no young-slot appends, no write
/// barrier, no free-list probes) — below the line the evaluator stays at
/// rooting-tax-only. The price: objects allocated before arming are permanently
/// old (unreclaimable floor ≈ reserved at line/2 — half the line, by
/// construction) UNLESS `root_always` (constrained mode): then a major also
/// reclaims that pre-arming region, paid for by keeping the transient-root
/// gates live from here. `collection.bootstrap_end` is captured now
/// as the reclaim boundary (bootstrap below it stays pinned).
pub fn enableBudget(heap: *ObjectHeap, budget: u64, root_always: bool) void {
    heap.collection.step_bytes = 0;
    heap.collection.budget_bytes = budget;
    heap.collection.threshold_bytes = budget / 2;
    heap.collection.bootstrap_end = heap.objects.count();
    heap.collection.root_always = root_always;
    heap.collection.root_active = root_always;
    // Detector: with bits live from here (per-fill, gated on root tracking),
    // size the bitmap now — arming won't be the first sizer, and its re-size
    // outside constrained mode would otherwise wipe bits set in between.
    if (comptime gc_debug) if (root_always) heap.gcPresizeAllocBits();
}

/// Start young-slot tracking, the old-to-young write barrier, and free-list
/// reuse. Objects already allocated are treated as old. The caller must hold
/// the world stopped while the object TLABs are discarded and tracking is
/// published.
pub fn armTracking(heap: *ObjectHeap) void {
    heap.collection.collect_enabled = true;
    heap.collection.root_active = true; // arming turns rooting on (already on if constrained)
    heap.collection.track_from = heap.objects.count();
    // A partially used object TLAB contains reserved ids below the tracking boundary.
    // Discard it so every subsequent object enters the young-slot lists.
    for (heap.worker_locals) |*l| {
        l.object = .{};
    }
    // Detector build: pre-size the alloc bitmap to the whole object id
    // space so the incremental per-fill bit-set never reallocs (which
    // would free the array under a concurrent reader/setter at
    // --workers>1). With a stable array, set uses atomic-or and read uses
    // atomic-load — no lock on detector paths.
    // Constrained mode already sized-and-populated the bitmap from eval start
    // (gcEnableBudget); re-sizing here would @memset those live bits to zero.
    if (comptime gc_debug) if (!heap.collection.root_always) heap.gcPresizeAllocBits();
}

/// The budget/2 STW safepoint under the lazy policy: arm tracking and
/// re-arm the threshold to the full budget. No mark, no sweep, no token
/// bump — nothing allocated so far is tracked, so there is nothing to
/// reclaim yet.
pub fn armLazy(heap: *ObjectHeap) void {
    armTracking(heap);
    heap.collection.collect_requested = false;
    const budget = heap.collection.budget_bytes;
    const headroom = std.math.clamp(budget / 8, 64 << 20, ObjectHeap.gc_headroom);
    heap.collection.threshold_bytes = @max(budget, heap.totalReservedBytes() + headroom);
}

/// Run a collection now via the registered callback (the evaluator's
/// mark+sweep). Caller must be at a safepoint. `collector_id` is the
/// worker driving the collection (its slot in the parallel mark).
pub fn runCollect(heap: *ObjectHeap, collector_id: u8) void {
    if (heap.collection.hook) |h| h.sample(h.ctx, collector_id);
}

/// Called by the evaluator after a sweep: clear the request and set the
/// next threshold. The store cursors are monotonic — non-moving reuse
/// returns freed ranges to the free lists but never lowers
/// `totalReservedBytes` — so the threshold must be relative to the
/// CURSOR NOW, not the live set: collect again only once we've committed
/// another `gc_headroom` of genuinely fresh pages (i.e. the free lists
/// drained and the cursor actually grew). Anchoring to live would leave
/// the threshold permanently below the cursor → collect every safepoint
/// (livelock). `live_bytes` is accepted for stats only.
pub fn afterCollect(heap: *ObjectHeap, live_bytes: u64) void {
    _ = live_bytes;
    heap.collection.collect_requested = false;
    // Post-collect headroom scales with the budget (an eighth, clamped to
    // [64 MB, gc_headroom]): a small-RAM budget must not grant itself a
    // flat 1 GB of growth per cycle, and a huge budget needn't collect
    // every 64 MB once it has (somehow) been crossed.
    const budget = heap.collection.budget_bytes;
    const headroom = std.math.clamp(budget / 8, 64 << 20, ObjectHeap.gc_headroom);
    heap.collection.threshold_bytes = if (heap.collection.step_bytes > 0)
        heap.totalReservedBytes() + heap.collection.step_bytes
    else
        @max(budget, heap.totalReservedBytes() + headroom);
    // Invalidate all thread-local caches (thunk memo, attr IC, call IC)
    // that key on `token`. Current thunk-memo and attr-cache values were
    // traced as roots for this collection because a cache may momentarily be
    // their sole owner; the fresh token makes every old slot miss afterward,
    // before a recycled ObjectId can be mistaken for that prior value.
    heap.token = heap_mod.next_heap_token.fetchAdd(1, .monotonic);
}

/// Visit every remembered old source (STW). `cb(ctx, source_id)`.
pub fn forEachRemsetSource(heap: *ObjectHeap, ctx: anytype, comptime cb: fn (@TypeOf(ctx), ObjectId) void) void {
    for (heap.worker_locals) |*wl| for (wl.gc_remset.items) |sid| cb(ctx, sid);
}

pub fn remsetClear(heap: *ObjectHeap) void {
    for (heap.worker_locals) |*wl| wl.gc_remset.clearRetainingCapacity();
}

/// In detector builds, verify that every young child of a live object was
/// marked before sweeping. A failure identifies the missed parent-child edge.
pub fn verifyMinorClosure(heap: *ObjectHeap, mark_bits: []const u64) void {
    if (comptime !gc_debug) return;
    const marked = struct {
        fn f(mb: []const u64, id: ObjectId) bool {
            const w = id >> 6;
            return w < mb.len and (mb[w] & (@as(u64, 1) << @intCast(id & 63))) != 0;
        }
    }.f;
    var shown: u32 = 0;
    // Include pinned objects because they may point into the young generation.
    var id: ObjectId = 0;
    const n = heap.objects.count();
    while (id < n and shown < 8) : (id += 1) {
        const word = id >> 6;
        if (word >= heap.collection.alloc_bits.len) break;
        if (heap.collection.alloc_bits[word] & (@as(u64, 1) << @intCast(id & 63)) == 0) continue;
        // Only LIVE parents constrain the mark: a dead young object
        // (unmarked, about to be swept) may freely reference dead young
        // children. Old and marked-young parents are live.
        if (heap.gcIsYoung(id) and !marked(mark_bits, id)) continue;
        const obj = heap.objects.get(id);
        const check = struct {
            fn f(h: *ObjectHeap, mb: []const u64, parent: ObjectId, child_v: Value, sh: *u32) void {
                const cid = ObjectHeap.gcHeapId(child_v) orelse return;
                if (!h.gcIsYoung(cid)) return; // old child: fine (not in minor set)
                if (!marked(mb, cid) and sh.* < 8) {
                    std.debug.print("GC MISSED EDGE: {s} {d} -> unmarked young {s} {d}\n", .{ @tagName(h.objects.get(parent).*), parent, @tagName(h.objects.get(cid).*), cid });
                    sh.* += 1;
                }
            }
        }.f;
        switch (obj.*) {
            .list => |r| for (heap.values.slice(r)) |v| check(heap, mark_bits, id, v, &shown),
            .attrs => |a| for (heap.attrs.slice(a.range)) |e| check(heap, mark_bits, id, e.value, &shown),
            .closure => |c| for (heap.values.slice(c.upvalues)) |v| check(heap, mark_bits, id, v, &shown),
            .builtin_closure => |c| for (heap.values.slice(c.args)) |v| check(heap, mark_bits, id, v, &shown),
            .partial_app => |p| {
                check(heap, mark_bits, id, p.func, &shown);
                for (heap.values.slice(p.args)) |v| check(heap, mark_bits, id, v, &shown);
            },
            .context_string => |c| for (heap.attrs.slice(c.context)) |e| check(heap, mark_bits, id, e.value, &shown),
            .merge_attrs => |m| {
                check(heap, mark_bits, id, Value.attrs(m.base), &shown);
                check(heap, mark_bits, id, Value.attrs(m.overlay), &shown);
                const flat = m.flattened.load(.monotonic);
                if (flat != heap_mod.no_flattened_attrs) check(heap, mark_bits, id, Value.attrs(flat), &shown);
            },
            .thunk => |*t| {
                const FutureState = @import("../future.zig").FutureState;
                const fs = @as(FutureState, @enumFromInt(t.future.state.load(.monotonic)));
                switch (fs) {
                    .resolved => check(heap, mark_bits, id, t.payload.result, &shown),
                    .errored, .blackhole => {},
                    .unresolved, .evaluating => switch (t.targetKind()) {
                        .closure => check(heap, mark_bits, id, t.payload.target.closure, &shown),
                        .pass_through => check(heap, mark_bits, id, t.payload.target.pass_through, &shown),
                        .attr_access => check(heap, mark_bits, id, t.payload.target.attr_access.base, &shown),
                        .bytecode => for (t.payload.target.bytecode.upvalues()) |v| check(heap, mark_bits, id, v, &shown),
                        .deferred => for (t.payload.target.deferred.env()) |v| check(heap, mark_bits, id, v, &shown),
                    },
                }
            },
            .boxed_int => {},
        }
    }
    if (shown > 0) @panic("gc: minor mark not closed — missed edge (see MISSED EDGE lines)");
}

/// Sweep the per-worker young-object lists. Marked objects are promoted in
/// place; unmarked objects return their slots and owned ranges to free lists.
pub fn minorCollect(heap: *ObjectHeap, mark_bits: []const u64) ObjectHeap.MinorStats {
    var st: ObjectHeap.MinorStats = .{};
    heap.gcGrowOldBits(heap.objects.count());
    verifyMinorClosure(heap, mark_bits);
    // The calling worker owns the free-list shard receiving serial results.
    const dst = heap.currentLocal();
    var ranges = RangeBatch.local(heap, dst);
    for (heap.worker_locals) |*local| {
        sweepYoungListInto(heap, local.gc_young_slots.items, dst, &ranges, mark_bits, &st);
        local.gc_young_slots.clearRetainingCapacity();
    }
    ranges.flush();
    return st;
}

/// Sweep one young-object list into the processing worker's free-list shard.
/// Lists are disjoint, and each worker writes only its own destination shard.
fn sweepYoungListInto(heap: *ObjectHeap, src_ids: []const ObjectId, dst: *HeapLocal, ranges: *RangeBatch, mark_bits: []const u64, st: *ObjectHeap.MinorStats) void {
    for (src_ids) |id| {
        const word = id >> 6;
        const bit = @as(u64, 1) << @intCast(id & 63);
        const marked = word < mark_bits.len and (mark_bits[word] & bit != 0);
        if (marked) {
            heap.gcSetOld(id);
            st.promoted += 1;
        } else {
            // Detector builds retain the slot so stale reads trap reliably.
            freeObjectRanges(heap, ranges, heap.objects.get(id));
            if (comptime gc_debug) {
                if (word < heap.collection.alloc_bits.len) _ = @atomicRmw(u64, &heap.collection.alloc_bits[word], .And, ~bit, .monotonic);
            } else {
                dst.gc_free_objects.append(heap.allocator, id) catch {};
            }
            st.freed += 1;
        }
    }
}

// --- parallel minor sweep -------------------------------------------------

/// Arm the young-list work queue while the object count is quiescent.
pub fn beginMinorSweep(heap: *ObjectHeap, worker_count: u8) void {
    heap.gcGrowOldBits(heap.objects.count());
    heap.collection.mark_slot.store(0, .release);
    heap.collection.minor_sweep_count = worker_count;
    heap.collection.minor_sweep_next.store(0, .monotonic);
    heap.collection.minor_sweep_done.store(0, .monotonic);
    heap.collection.minor_sweep_promoted.store(0, .monotonic);
    heap.collection.minor_sweep_freed.store(0, .monotonic);
    heap.collection.minor_sweep_open.store(false, .release);
}

/// Release helpers after the mark reaches closure.
pub fn openMinorSweep(heap: *ObjectHeap) void {
    heap.collection.minor_sweep_open.store(true, .release);
}

/// Claim and sweep young-object lists until the queue drains.
pub fn minorSweepClaimLoop(heap: *ObjectHeap, mark_bits: []const u64) void {
    while (!heap.collection.minor_sweep_open.load(.acquire)) std.atomic.spinLoopHint();
    const dst = heap.currentLocal();
    var local_st: ObjectHeap.MinorStats = .{};
    var ranges = RangeBatch.local(heap, dst);
    while (true) {
        const i = heap.collection.minor_sweep_next.fetchAdd(1, .monotonic);
        if (i >= heap.collection.minor_sweep_count) break;
        sweepYoungListInto(heap, heap.worker_locals[i].gc_young_slots.items, dst, &ranges, mark_bits, &local_st);
        // Publish the final pending intervals before declaring this source
        // list swept; the coordinator uses `minor_sweep_done` as its fence.
        ranges.flush();
        heap.worker_locals[i].gc_young_slots.clearRetainingCapacity();
        _ = heap.collection.minor_sweep_done.fetchAdd(1, .release);
    }
    _ = heap.collection.minor_sweep_promoted.fetchAdd(local_st.promoted, .monotonic);
    _ = heap.collection.minor_sweep_freed.fetchAdd(local_st.freed, .monotonic);
}

/// Block until every young-object list has been swept.
pub fn waitMinorSweepDone(heap: *ObjectHeap) void {
    while (heap.collection.minor_sweep_done.load(.acquire) < heap.collection.minor_sweep_count) std.atomic.spinLoopHint();
}

/// Return the aggregate result after every list has drained.
pub fn finishMinorSweep(heap: *ObjectHeap) ObjectHeap.MinorStats {
    return .{ .promoted = heap.collection.minor_sweep_promoted.load(.monotonic), .freed = heap.collection.minor_sweep_freed.load(.monotonic) };
}

/// Debug: verify the mark is closed — no MARKED object may reference an
/// unmarked filled object. A violation means the tracer missed an edge
/// (systematic bug); silence means marking is complete and any swept
/// object is genuinely unreachable (held only by a Zig local / untracked
/// root). Prints up to a few violations. STW-only.
pub fn verifyMarkClosed(heap: *ObjectHeap, mark_bits: []const u64) void {
    const marked = struct {
        fn f(mb: []const u64, ab: []const u64, id: ObjectId) bool {
            const w = id >> 6;
            const bit = @as(u64, 1) << @intCast(id & 63);
            if (w >= ab.len or ab[w] & bit == 0) return false; // not filled
            return w < mb.len and (mb[w] & bit != 0);
        }
    }.f;
    const check = struct {
        fn f(h: *ObjectHeap, mb: []const u64, parent: ObjectId, child_v: Value, shown: *u32) void {
            if (!(child_v.isList() or child_v.isAttrs() or child_v.isThunk() or child_v.isClosure() or
                child_v.isBuiltinClosure() or child_v.isContextString() or child_v.isBoxedInt() or child_v.isPartialApp())) return;
            const child = child_v.asObjectId();
            const w = child >> 6;
            const bit = @as(u64, 1) << @intCast(child & 63);
            const filled = w < h.collection.alloc_bits.len and (h.collection.alloc_bits[w] & bit != 0);
            if (!filled) return;
            const cmarked = w < mb.len and (mb[w] & bit != 0);
            if (!cmarked and shown.* < 8) {
                std.debug.print("  TRACER-MISSED EDGE: marked {d} ({s}) -> unmarked {d} ({s})\n", .{ parent, @tagName(h.objects.get(parent).*), child, @tagName(h.objects.get(child).*) });
                shown.* += 1;
            }
        }
    }.f;
    var shown: u32 = 0;
    var id: ObjectId = 0;
    const n = heap.objects.count();
    while (id < n and shown < 8) : (id += 1) {
        if (!marked(mark_bits, heap.collection.alloc_bits, id)) continue;
        const obj = heap.objects.get(id);
        switch (obj.*) {
            .list => |r| for (heap.values.slice(r)) |v| check(heap, mark_bits, id, v, &shown),
            .attrs => |a| for (heap.attrs.slice(a.range)) |e| check(heap, mark_bits, id, e.value, &shown),
            .closure => |c| for (heap.values.slice(c.upvalues)) |v| check(heap, mark_bits, id, v, &shown),
            .builtin_closure => |c| for (heap.values.slice(c.args)) |v| check(heap, mark_bits, id, v, &shown),
            .partial_app => |p| {
                check(heap, mark_bits, id, p.func, &shown);
                for (heap.values.slice(p.args)) |v| check(heap, mark_bits, id, v, &shown);
            },
            .context_string => |c| for (heap.attrs.slice(c.context)) |e| check(heap, mark_bits, id, e.value, &shown),
            .merge_attrs => |m| {
                check(heap, mark_bits, id, Value.attrs(m.base), &shown);
                check(heap, mark_bits, id, Value.attrs(m.overlay), &shown);
            },
            .thunk => |*t| {
                if (@as(@import("../future.zig").FutureState, @enumFromInt(t.future.state.load(.monotonic))) == .resolved)
                    check(heap, mark_bits, id, t.payload.result, &shown);
            },
            else => {},
        }
    }
    if (shown > 0) std.debug.print("=== ^ mark NOT closed: tracer missed edges (bug) ===\n", .{});
}

/// Return a dead object's owned store ranges to the free lists. Ranges
/// are single-owner (every construction site reserves fresh + copies),
/// so this is the only owner — see docs/gc.md. Thunk *spilled*
/// upvalue/env storage records its segment range and is reclaimed either here
/// (unresolved dead thunk) or immediately after a force publishes its result.
/// `attrs_merge`/`boxed_int` own no ranges.
fn freeObjectRanges(heap: *ObjectHeap, ranges: *RangeBatch, obj: *const Object) void {
    // Detector: poison the freed range so a dangling raw `getList`/`getAttrs`
    // slice (owner swept while a Zig local held the slice — the class the
    // reuse-off object-read assert can't see) traps on next access instead
    // of silently reading stale-but-valid data. Poison is a thunk to an
    // unallocated id, so forcing/reading a poisoned element hits gcAssertLive.
    if (comptime gc_debug) {
        const poison = Value.thunk(heap_mod.object_max_slots - 1);
        switch (obj.*) {
            .list => |r| for (heap.values.sliceMut(r)) |*v| {
                v.* = poison;
            },
            .attrs => |a| for (heap.attrs.sliceMut(a.range)) |*e| {
                e.value = poison;
            },
            .builtin_closure => |c| for (heap.values.sliceMut(c.args)) |*v| {
                v.* = poison;
            },
            .partial_app => |p| for (heap.values.sliceMut(p.args)) |*v| {
                v.* = poison;
            },
            .context_string => |c| for (heap.attrs.sliceMut(c.context)) |*e| {
                e.value = poison;
            },
            else => {},
        }
    }
    switch (obj.*) {
        .list => |r| if (r.len > 0) ranges.add("values", "gc_free_values", .{ .segment = r.segment, .offset = r.offset, .len = r.len }),
        .attrs => |a| {
            if (a.range.len > 0) ranges.add("attrs", "gc_free_attrs", .{ .segment = a.range.segment, .offset = a.range.offset, .len = a.range.len });
            if (a.positions.len > 0) ranges.add("attr_pos", "gc_free_attr_pos", .{ .segment = a.positions.segment, .offset = a.positions.offset, .len = a.positions.len });
        },
        .builtin_closure => |c| if (c.args.len > 0) ranges.add("values", "gc_free_values", .{ .segment = c.args.segment, .offset = c.args.offset, .len = c.args.len }),
        .partial_app => |p| if (p.args.len > 0) ranges.add("values", "gc_free_values", .{ .segment = p.args.segment, .offset = p.args.offset, .len = p.args.len }),
        .context_string => |c| if (c.context.len > 0) ranges.add("attrs", "gc_free_attrs", .{ .segment = c.context.segment, .offset = c.context.offset, .len = c.context.len }),
        .thunk => |t| if (t.targetSpillRange()) |r| ranges.add("values", "gc_free_values", .{ .segment = r.segment, .offset = r.offset, .len = r.len }),
        // NOT reclaimed yet: an executing frame aliases its
        // `upvalues` slice owned by a .closure object. Freeing the range while
        // a frame runs would dangle it. Reclaiming closures needs each frame
        // to root its executing closure (a follow-up RSS optimization).
        .closure, .merge_attrs, .boxed_int => {},
    }
}
