//! GC (`-Dgc`) collector driver for `ObjectHeap`: the non-inline mark/sweep/
//! evac/minor-collect machinery. Extracted out of the `heap.zig` god-file.
//!
//! These are free functions over `heap: *ObjectHeap` rather than methods (Zig
//! can't add methods to a struct from another file), but a sibling file has
//! full access to `ObjectHeap`'s fields and `pub` decls, so the bodies are a
//! mechanical relocation — the collector logic is byte-for-byte the same.
//!
//! The hot per-allocation inline helpers (gcNurseryFull / gcSetAllocBit /
//! gcIsYoung / gcSetOld / gcHeapId / gcRecordEdge / the bit-range helpers)
//! deliberately STAY in `ObjectHeap` so they keep inlining into the alloc
//! path; the collector here calls them through `heap`.
//!
//! Every entry point is comptime-guarded (`if (comptime !build_options.gc)
//! return;`) so the whole file compiles to nothing in a default build.

const std = @import("std");
const build_options = @import("build_options");
const heap_mod = @import("../heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const HeapLocal = heap_mod.HeapLocal;
const Object = heap_mod.Object;
const ObjectId = heap_mod.ObjectId;
const Value = @import("../value.zig").Value;

const gc_debug = heap_mod.gc_debug;

/// Turn on reclaim (alloc-bitmap maintenance + free-list reuse + sweep)
/// with a memory `budget` (the reserved-bytes ceiling the collector
/// defends — see `ObjectHeap.gc_budget_bytes`). `step_bytes` > 0 is the
/// validation override: collect every that-many bytes of fresh allocation
/// from a low starting threshold, ignoring the budget.
pub fn enableCollect(heap: *ObjectHeap, budget: u64, step_bytes: u64) void {
    if (comptime !build_options.gc) return;
    ObjectHeap.gc_step_bytes = step_bytes;
    ObjectHeap.gc_budget_bytes = budget;
    // NON-MOVING: collect on the reserved-bytes threshold (survivors stay
    // in place; there is no nursery to fill/reset). `gcNurseryFull` now only
    // requests a collect once the cursor has grown a headroom past the last
    // collect (`gcAfterCollect` re-arms the threshold), so we don't collect
    // every TLAB refill.
    heap.gc_threshold_bytes = if (step_bytes > 0) ObjectHeap.GC_MIN_THRESHOLD else budget;
    armTracking(heap);
}

/// Lazy variant (the production collection-line policy, see
/// `eval_gc.memoryBudget`): don't start any per-allocation tracking yet — just
/// watch the reserved-bytes cursor. At half the line the safepoint driver arms
/// tracking (STW, `armTracking`); at the line it collects. A run that never
/// reaches line/2 pays ZERO tracking cost (no young-slot appends, no write
/// barrier, no free-list probes) — below the line a `-Dgc` build stays at
/// rooting-tax-only. The price: objects allocated before arming are permanently
/// old (unreclaimable floor ≈ reserved at line/2 — half the line, by
/// construction).
pub fn enableBudget(heap: *ObjectHeap, budget: u64) void {
    if (comptime !build_options.gc) return;
    ObjectHeap.gc_step_bytes = 0;
    ObjectHeap.gc_budget_bytes = budget;
    heap.gc_threshold_bytes = budget / 2;
}

/// Start reclaim tracking: young-slot lists, the old→young write barrier,
/// and free-list reuse, with everything allocated so far tenured
/// (`gc_track_from` = the current count). Called either eagerly from
/// `enableCollect` (validation) or at the first budget/2 STW safepoint
/// (`enableBudget` → `armLazy`). Any later caller must hold the world
/// stopped: the TLAB flush and `gc_collect_enabled` publication race
/// mutators otherwise.
pub fn armTracking(heap: *ObjectHeap) void {
    if (comptime !build_options.gc) return;
    heap.gc_collect_enabled = true;
    heap.gc_track_from = heap.objects.count();
    // Flush each worker's TLABs so the first post-enable allocation refills
    // fresh instead of draining a leftover chunk carried over from bootstrap.
    // The object TLAB matters for correctness, not just the range TLABs: a
    // bootstrap object chunk reserves a whole span up to `objects.count()`
    // but leaves most of it UNFILLED. Since `gc_track_from` is that count,
    // any object later drained from those leftover low slots would land
    // BELOW `gc_track_from` — untracked — yet be born post-enable with a
    // YOUNG range. The nursery reset would then reclaim that range out from
    // under a live, never-evacuated object (untracked objects are never
    // marked/evacuated). Flushing forces post-enable objects onto fresh
    // slots at/above `gc_track_from`, so they are tracked and evacuated.
    for (heap.worker_locals) |*l| {
        l.value = .{};
        l.attr = .{};
        l.attr_pos = .{};
        l.object = .{};
    }
    // Detector build: pre-size the alloc bitmap to the whole object id
    // space so the incremental per-fill bit-set never reallocs (which
    // would free the array under a concurrent reader/setter at
    // --workers>1). With a stable array, set uses atomic-or and read uses
    // atomic-load — no lock on the hot detector paths. ~128 MB, debug only.
    if (comptime gc_debug) {
        const words = (@as(usize, heap_mod.OBJECT_MAX_SLOTS) + 63) >> 6;
        heap.gc_alloc_bits = heap.allocator.realloc(heap.gc_alloc_bits, words) catch heap.gc_alloc_bits;
        @memset(heap.gc_alloc_bits, 0);
    }
}

/// The budget/2 STW safepoint under the lazy policy: arm tracking and
/// re-arm the threshold to the full budget. No mark, no sweep, no token
/// bump — nothing allocated so far is tracked, so there is nothing to
/// reclaim yet.
pub fn armLazy(heap: *ObjectHeap) void {
    if (comptime !build_options.gc) return;
    armTracking(heap);
    heap.gc_collect_requested = false;
    const budget = ObjectHeap.gc_budget_bytes;
    const headroom = std.math.clamp(budget / 8, 64 << 20, ObjectHeap.GC_HEADROOM);
    heap.gc_threshold_bytes = @max(budget, heap.totalReservedBytes() + headroom);
}

/// Run a collection now via the registered callback (the evaluator's
/// mark+sweep). Caller must be at a safepoint. `collector_id` is the
/// worker driving the collection (its slot in the parallel mark).
pub fn runCollect(heap: *ObjectHeap, collector_id: u8) void {
    if (comptime !build_options.gc) return;
    if (heap.gc_hook) |h| h.sample(h.ctx, collector_id);
}

/// Called by the evaluator after a sweep: clear the request and set the
/// next threshold. The store cursors are monotonic — non-moving reuse
/// returns freed ranges to the free lists but never lowers
/// `totalReservedBytes` — so the threshold must be relative to the
/// CURSOR NOW, not the live set: collect again only once we've committed
/// another `GC_HEADROOM` of genuinely fresh pages (i.e. the free lists
/// drained and the cursor actually grew). Anchoring to live would leave
/// the threshold permanently below the cursor → collect every safepoint
/// (livelock). `live_bytes` is accepted for stats only.
pub fn afterCollect(heap: *ObjectHeap, live_bytes: u64) void {
    if (comptime !build_options.gc) return;
    _ = live_bytes;
    heap.gc_collect_requested = false;
    // Post-collect headroom scales with the budget (an eighth, clamped to
    // [64 MB, GC_HEADROOM]): a small-RAM budget must not grant itself a
    // flat 1 GB of growth per cycle, and a huge budget needn't collect
    // every 64 MB once it has (somehow) been crossed.
    const budget = ObjectHeap.gc_budget_bytes;
    const headroom = std.math.clamp(budget / 8, 64 << 20, ObjectHeap.GC_HEADROOM);
    heap.gc_threshold_bytes = if (ObjectHeap.gc_step_bytes > 0)
        heap.totalReservedBytes() + ObjectHeap.gc_step_bytes
    else
        @max(budget, heap.totalReservedBytes() + headroom);
    // Invalidate all thread-local caches (thunk memo, attr IC, call IC)
    // that key on `token`: they hold Values weakly (not GC roots), so a
    // swept object could still be reachable through a stale cache slot.
    // A fresh unique token makes every existing slot miss. This is why
    // caches needn't be traced (see docs/plans/gc-plan.md).
    heap.token = heap_mod.next_heap_token.fetchAdd(1, .monotonic);
}

/// Visit every remembered old source (STW). `cb(ctx, source_id)`.
pub fn forEachRemsetSource(heap: *ObjectHeap, ctx: anytype, comptime cb: fn (@TypeOf(ctx), ObjectId) void) void {
    if (comptime !build_options.gc) return;
    for (heap.worker_locals) |*wl| for (wl.gc_remset.items) |sid| cb(ctx, sid);
}

pub fn remsetClear(heap: *ObjectHeap) void {
    for (heap.worker_locals) |*wl| wl.gc_remset.clearRetainingCapacity();
}

/// One stop-the-world minor collection. The evaluator has already marked
/// the reachable young set into `mark_bits` (young-gated: roots + the
/// old→young remembered set, stopping at old). Here: evacuate every marked
/// young object's ranges to tenured + promote it, reclaim dead young slot
/// ids, then reset the nursery (bulk-reclaiming all dead young storage).
/// Runs at a safepoint; single-threaded at `--workers=1`.
/// Detector: verify the minor mark is CLOSED before we sweep — every young
/// object referenced by a live (filled) object must be marked. An unmarked
/// young child of any parent means the tracer/remembered-set missed an edge
/// and is about to sweep a live object. Panics with parent→child so a missed
/// barrier/root is caught at its source, before any downstream misread.
pub fn verifyMinorClosure(heap: *ObjectHeap, mark_bits: []const u64) void {
    if (comptime !gc_debug) return;
    const marked = struct {
        fn f(mb: []const u64, id: ObjectId) bool {
            const w = id >> 6;
            return w < mb.len and (mb[w] & (@as(u64, 1) << @intCast(id & 63))) != 0;
        }
    }.f;
    var shown: u32 = 0;
    // From 0, not gc_track_from: catches the class where a post-enable
    // object lands in a leftover bootstrap slot BELOW track_from (untracked)
    // with a young range — the bug the object-TLAB-flush fix closed.
    var id: ObjectId = 0;
    const n = heap.objects.count();
    while (id < n and shown < 8) : (id += 1) {
        const word = id >> 6;
        if (word >= heap.gc_alloc_bits.len) break;
        if (heap.gc_alloc_bits[word] & (@as(u64, 1) << @intCast(id & 63)) == 0) continue;
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
                if (flat != heap_mod.NO_FLAT) check(heap, mark_bits, id, Value.attrs(flat), &shown);
            },
            .thunk => |*t| {
                const FutureState = @import("../thunk.zig").FutureState;
                const fs = @as(FutureState, @enumFromInt(t.future.state.load(.monotonic)));
                switch (fs) {
                    .resolved => check(heap, mark_bits, id, t.payload.result, &shown),
                    .errored, .blackhole => {},
                    .unresolved, .evaluating => switch (t.future.target_kind) {
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

/// One minor collection — **O(young)**, not O(total objects). The young
/// generation is the contiguous slot range `[gc_young_slot_start, count)`.
/// Slot ids are NOT recycled between minors (dead young slots leak until a
/// rare major), so the range is gap-free and holds exactly this cycle's new
/// objects. `gcResetNursery` flushes the OBJECT TLABs too, so after a minor
/// `count()` is the true next-allocatable id — the frontier — and the next
/// generation's objects are all born at or above it (the reserved-vs-filled
/// TLAB-tail hazard is why an earlier frontier=count attempt leaked
/// below-frontier survivors). Only MARKED (survivor) slots do work; unmarked
/// slots are dead young or unfilled tails and need nothing. No
/// `gcReconstructAllocBits`, no O(count) walk.
pub fn minorCollect(heap: *ObjectHeap, mark_bits: []const u64) ObjectHeap.MinorStats {
    var st: ObjectHeap.MinorStats = .{};
    if (comptime !build_options.gc) return st;
    heap.gcGrowOldBits(heap.objects.count());
    verifyMinorClosure(heap, mark_bits);
    // Iterate exactly this cycle's young objects (per-worker lists), all into
    // the calling worker's tenured TLAB / free shard.
    const dst = heap.currentLocal();
    for (heap.worker_locals) |*local| {
        evacListInto(heap, local.gc_young_slots.items, dst, mark_bits, &st);
        local.gc_young_slots.clearRetainingCapacity();
    }
    // NON-MOVING: do NOT reset the nursery — survivor ranges stay in place
    // (they were not evacuated), and dead ranges were returned to the free
    // lists individually above. Resetting would discard the live survivors.
    return st;
}

/// Evacuate one young-object list into `dst` (the *processing* worker's
/// tenured TLAB + free shard — NOT necessarily the list's owner). Marked ⇒
/// live survivor: evacuate its young ranges + promote. Unmarked ⇒ dead:
/// reclaim its slot id (its young ranges vanish with the nursery reset).
/// Safe to run concurrently on DISJOINT lists: each object id lives in
/// exactly one list, ranges are single-owner, `gcSetOld` is atomic, and each
/// worker writes only its own `dst`.
pub fn evacListInto(heap: *ObjectHeap, src_ids: []const ObjectId, dst: *HeapLocal, mark_bits: []const u64, st: *ObjectHeap.MinorStats) void {
    for (src_ids) |id| {
        const word = id >> 6;
        const bit = @as(u64, 1) << @intCast(id & 63);
        const marked = word < mark_bits.len and (mark_bits[word] & bit != 0);
        if (marked) {
            // NON-MOVING: promote in place — the object's ranges stay put
            // (no evacuation), so no `gc_debug` re-fetch discipline and no
            // relocation. Just flip the generation bit; the id is unchanged.
            heap.gcSetOld(id);
            st.promoted += 1;
        } else {
            // Dead: return its ranges to the free lists IN PLACE (reused by
            // the next allocation) and recycle its slot id. The detector
            // leaks the id (no reuse) + clears the alloc bit atomically so a
            // dangling read traps; `gcFreeObjectRanges` poisons the ranges.
            freeObjectRanges(heap, dst, heap.objects.get(id));
            if (comptime gc_debug) {
                if (word < heap.gc_alloc_bits.len) _ = @atomicRmw(u64, &heap.gc_alloc_bits[word], .And, ~bit, .monotonic);
            } else {
                dst.gc_free_objects.append(heap.allocator, id) catch {};
            }
            st.freed += 1;
        }
    }
}

// --- parallel evacuation phase (`--workers>1`) ---------------------------
//
// The collector calls `beginEvac` before opening the mark, then (after the
// mark terminates and it has verified closure) `openEvac`. Every worker —
// collector and parked peers alike — runs `evacClaimLoop`, atomically
// claiming young-object lists and evacuating them into its own TLAB. The
// collector then `waitEvacDone` + `finishEvac` (reset the nursery).

/// Collector: arm the evac work queue. Called before `gcOpenMark` (grows the
/// generation bitmap while the object count is quiescent; the phase stays
/// closed until `openEvac`).
pub fn beginEvac(heap: *ObjectHeap, worker_count: u8) void {
    if (comptime !build_options.gc) return;
    heap.gcGrowOldBits(heap.objects.count());
    heap.gc_mark_slot.store(0, .release);
    heap.gc_evac_count = worker_count;
    heap.gc_evac_next.store(0, .monotonic);
    heap.gc_evac_done.store(0, .monotonic);
    heap.gc_evac_promoted.store(0, .monotonic);
    heap.gc_evac_freed.store(0, .monotonic);
    heap.gc_evac_open.store(false, .release);
}

/// Collector: release helpers into the evac phase. Called only after mark
/// closure is verified, so no worker moves a range the collector is still
/// reading.
pub fn openEvac(heap: *ObjectHeap) void {
    if (comptime !build_options.gc) return;
    heap.gc_evac_open.store(true, .release);
}

/// Any worker (collector or parked peer): claim + evacuate young-object
/// lists until the queue drains. Spins until the collector opens the phase.
pub fn evacClaimLoop(heap: *ObjectHeap, mark_bits: []const u64) void {
    if (comptime !build_options.gc) return;
    while (!heap.gc_evac_open.load(.acquire)) std.atomic.spinLoopHint();
    const dst = heap.currentLocal();
    var local_st: ObjectHeap.MinorStats = .{};
    while (true) {
        const i = heap.gc_evac_next.fetchAdd(1, .monotonic);
        if (i >= heap.gc_evac_count) break;
        evacListInto(heap, heap.worker_locals[i].gc_young_slots.items, dst, mark_bits, &local_st);
        heap.worker_locals[i].gc_young_slots.clearRetainingCapacity();
        _ = heap.gc_evac_done.fetchAdd(1, .release);
    }
    _ = heap.gc_evac_promoted.fetchAdd(local_st.promoted, .monotonic);
    _ = heap.gc_evac_freed.fetchAdd(local_st.freed, .monotonic);
}

/// Collector: block until every young-object list has been evacuated.
pub fn waitEvacDone(heap: *ObjectHeap) void {
    if (comptime !build_options.gc) return;
    while (heap.gc_evac_done.load(.acquire) < heap.gc_evac_count) std.atomic.spinLoopHint();
}

/// Collector: post-evac finish (all lists drained). Verify + reset nursery.
pub fn finishEvac(heap: *ObjectHeap) ObjectHeap.MinorStats {
    if (comptime !build_options.gc) return .{};
    // NON-MOVING: survivors were promoted in place (not evacuated) and dead
    // ranges freed to the free lists individually — do NOT reset the
    // nursery (that would discard the live survivors' ranges).
    return .{ .promoted = heap.gc_evac_promoted.load(.monotonic), .freed = heap.gc_evac_freed.load(.monotonic) };
}

// --- parallel MAJOR sweep (`--workers>1`) -------------------------------
//
// The full sweep walks the whole id range, so it's partitioned into word-
// aligned chunks that the mark participants (collector + helping peers) claim
// and sweep into their OWN free-list shard. Word-aligned chunks are alloc-bit
// disjoint, so the per-slot bit clears need no atomics. Coordinated like the
// evac phase: the collector reconstructs the alloc bitmap serially, opens the
// phase, sweeps alongside the peers, then waits for done. A `chunk` never
// straddles a 64-bit alloc-bit word (SWEEP_CHUNK is a multiple of 64).
const SWEEP_CHUNK: usize = 1 << 15; // 32768 ids = 512 alloc-bit words

/// Collector: reconstruct the alloc bitmap (release) — or verify mark closure
/// (debug) — so the parallel sweep reads a valid filled-set. Call after the
/// mark terminates, before opening the sweep.
pub fn sweepPrep(heap: *ObjectHeap, mark_bits: []const u64) void {
    if (comptime !build_options.gc) return;
    if (comptime !gc_debug) heap.gcReconstructAllocBits();
    if (comptime gc_debug) verifyMarkClosed(heap, mark_bits);
}

/// Any participant (collector or helping peer): claim id-range chunks and free
/// every unmarked filled slot in them to THIS worker's shard, until the range
/// is exhausted. Spins until the collector opens the phase.
pub fn sweepClaimLoop(heap: *ObjectHeap, mark_bits: []const u64) void {
    if (comptime !build_options.gc) return;
    while (!heap.gc_sweep_open.load(.acquire)) std.atomic.spinLoopHint();
    const local = heap.currentLocal();
    const n: usize = heap.objects.count();
    var freed: u64 = 0;
    while (true) {
        const chunk = heap.gc_sweep_next.fetchAdd(1, .monotonic);
        const lo: usize = @as(usize, chunk) * SWEEP_CHUNK;
        if (lo >= n) break;
        const hi: usize = @min(lo + SWEEP_CHUNK, n);
        var id: ObjectId = @intCast(lo);
        while (id < hi) : (id += 1) {
            const word = id >> 6;
            if (word >= heap.gc_alloc_bits.len) break;
            const bit = @as(u64, 1) << @intCast(id & 63);
            if (heap.gc_alloc_bits[word] & bit == 0) continue; // unfilled / already free
            if (word < mark_bits.len and (mark_bits[word] & bit != 0)) continue; // live
            freeObjectRanges(heap, local, heap.objects.get(id));
            heap.gc_alloc_bits[word] &= ~bit; // word-disjoint across chunks ⇒ no atomic
            local.gc_free_objects.append(heap.allocator, id) catch {};
            freed += 1;
        }
    }
    _ = heap.gc_sweep_freed.fetchAdd(freed, .monotonic);
    _ = heap.gc_sweep_done.fetchAdd(1, .release);
}

/// Collector: block until every participant finished sweeping.
pub fn sweepWaitDone(heap: *ObjectHeap) void {
    if (comptime !build_options.gc) return;
    while (heap.gc_sweep_done.load(.acquire) < heap.gc_sweep_count) std.atomic.spinLoopHint();
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
            const filled = w < h.gc_alloc_bits.len and (h.gc_alloc_bits[w] & bit != 0);
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
        if (!marked(mark_bits, heap.gc_alloc_bits, id)) continue;
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
                if (@as(@import("../thunk.zig").FutureState, @enumFromInt(t.future.state.load(.monotonic))) == .resolved)
                    check(heap, mark_bits, id, t.payload.result, &shown);
            },
            else => {},
        }
    }
    if (shown > 0) std.debug.print("=== ^ mark NOT closed: tracer missed edges (bug) ===\n", .{});
}

/// Return a dead object's owned store ranges to the free lists. Ranges
/// are single-owner (every construction site reserves fresh + copies),
/// so this is the only owner — see docs/plans/gc-plan.md. Thunk *spilled*
/// upvalue/env storage is a bare slice (no segment/offset to recover),
/// so it is not reclaimed yet (thunks with >2 upvalues — a minority);
/// `attrs_merge`/`boxed_int` own no ranges.
pub fn freeObjectRanges(heap: *ObjectHeap, local: *HeapLocal, obj: *const Object) void {
    // Detector: poison the freed range so a dangling raw `getList`/`getAttrs`
    // slice (owner swept while a Zig local held the slice — the class the
    // reuse-off object-read assert can't see) traps on next access instead
    // of silently reading stale-but-valid data. Poison is a thunk to an
    // unallocated id, so forcing/reading a poisoned element hits gcAssertLive.
    if (comptime gc_debug) {
        const poison = Value.thunk(heap_mod.OBJECT_MAX_SLOTS - 1);
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
        .list => |r| if (r.len > 0) local.gc_free_values.push(heap.allocator, r.segment, r.offset, r.len),
        .attrs => |a| {
            if (a.range.len > 0) local.gc_free_attrs.push(heap.allocator, a.range.segment, a.range.offset, a.range.len);
            if (a.positions.len > 0) local.gc_free_attr_pos.push(heap.allocator, a.positions.segment, a.positions.offset, a.positions.len);
        },
        .builtin_closure => |c| if (c.args.len > 0) local.gc_free_values.push(heap.allocator, c.args.segment, c.args.offset, c.args.len),
        .partial_app => |p| if (p.args.len > 0) local.gc_free_values.push(heap.allocator, p.args.segment, p.args.offset, p.args.len),
        .context_string => |c| if (c.context.len > 0) local.gc_free_attrs.push(heap.allocator, c.context.segment, c.context.offset, c.context.len),
        // NOT reclaimed yet: an executing frame aliases its
        // `upvalues` slice, which is owned by the .closure object (or a
        // .thunk's spilled storage). Freeing the range while a frame
        // runs would dangle it. Reclaiming these needs the frame to
        // root its executing closure/thunk (a follow-up RSS opt);
        // until then their ranges leak. `attrs_merge`/`boxed_int` own
        // no reclaimable range.
        .closure, .thunk, .merge_attrs, .boxed_int => {},
    }
}
