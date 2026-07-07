//! Runtime object heap.
//!
//! Values refer to boxed runtime objects by ObjectId rather than by host
//! pointers. This keeps the value representation position-independent and
//! centralizes object layout behind heap accessors.
//!
//! Thread safety:
//!   - The four backing stores are non-relocating: `objects` is a flat
//!     mmap `FlatStore`, `values`/`attrs`/`attr_positions` are
//!     `StableSegments`. Readers are lock-free; writers serialize per-store
//!     on the store's internal `SpinMutex`.
//!   - In-place mutation of an object payload is restricted to atomics:
//!       * `*Thunk` state (via `getThunk` -> CAS / release-store).
//!       * `merge_attrs.flattened` (cmpxchg memoizing the flattened attrs id).
//!   - The union tag of an object slot is fixed at creation and never changes,
//!     so concurrent readers can pattern-match without synchronization once
//!     they have a published ObjectId.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const types = @import("types.zig");

/// Deterministic use-after-free detector (ReleaseSafe `-Dgc` only): when
/// on, freed object slots are NOT reused and every object read asserts the
/// slot's alloc-bit is set — so a collection that frees a still-live object
/// traps at the first stale read with a stack trace, instead of a
/// nondeterministic segfault much later. Off in ReleaseFast (production).
pub const gc_debug = build_options.gc and builtin.mode == .ReleaseSafe;
const stable = @import("stable_segments.zig");
const worker_id_mod = @import("worker_id.zig");
/// GC (`-Dgc`) collector driver: the non-inline mark/sweep/evac/minor-collect
/// machinery, extracted to keep this file from being a god-file. Free
/// functions over `*ObjectHeap`; the hot inline alloc-path helpers stay here.
/// Re-exported (`pub`) so out-of-module callers reach it as
/// `@import("runtime").heap.heap_gc`.
pub const heap_gc = @import("heap/gc.zig");
/// ARC-feasibility census (`-Darc-census`): exit-time whole-heap cycle-mass
/// + RC-traffic analysis. Print-only; compiles to nothing when off.
pub const heap_arc = @import("heap/arc_census.zig");
const struct_census = @import("struct_census.zig");
const Value = @import("value.zig").Value;
const Thunk = @import("thunk.zig").Thunk;
const BytecodeThunk = @import("thunk.zig").BytecodeThunk;
const DeferredThunk = @import("thunk.zig").DeferredThunk;
const ErrorInfo = @import("thunk.zig").ErrorInfo;
/// `-Dprof-main`: the creation-context / demanded-age probe fields on
/// `Future` are live (see thunk.zig `created_tsc_enabled`).
const prof_census_enabled = @import("thunk.zig").created_tsc_enabled;

pub const ObjectId = types.ObjectId;
pub const ChunkId = types.ChunkId;
pub const InternId = types.InternId;

pub const AttrEntry = struct {
    name: InternId,
    value: Value,
};

pub const SourcePos = struct {
    file: InternId,
    line: u32,
    column: u32,
};

pub const AttrPosEntry = struct {
    name: InternId,
    pos: SourcePos,
};

/// The object store is backed by a single mmap-reserved contiguous
/// region rather than geometric segments: it is referenced *only* by
/// flat ObjectId (never via an externally-handed-out `Range`/`slice`,
/// unlike the value/attr stores), so `get(id)` collapses to one load —
/// `base[id]` — with no segment decode (`clz` + shifts) and no per-access
/// atomic segment-pointer load. On the NixOS toplevel this access happens
/// tens of millions of times. `OBJECT_MAX_SLOTS` is a virtual reservation
/// (MAP_NORESERVE), so the headroom over the ~6M objects a real eval
/// produces costs no physical memory.
pub const OBJECT_MAX_SLOTS: u32 = 1 << 30;
const ObjectStore = stable.FlatStore(Object, .{ .max_slots = OBJECT_MAX_SLOTS });
const ValueStore = stable.StableSegments(Value, .{ .first_segment_size = 1024 });
const AttrStore = stable.StableSegments(AttrEntry, .{ .first_segment_size = 512 });
const AttrPosStore = stable.StableSegments(AttrPosEntry, .{ .first_segment_size = 512 });

pub var next_heap_token: std.atomic.Value(u64) = .init(1);

pub const ValueRange = ValueStore.Range;
pub const AttrRange = AttrStore.Range;
pub const AttrPosRange = AttrPosStore.Range;

/// A zero-length attr-position range: the attrset carries no source
/// positions. Sliced only after a `len == 0` guard, so the (possibly
/// segment-less) store is never indexed.
pub const EMPTY_ATTR_POS: AttrPosRange = .{ .segment = 0, .offset = 0, .len = 0 };

pub const Closure = struct {
    chunk_id: ChunkId,
    upvalues: []const Value,
};

pub const BuiltinClosure = struct {
    builtin_id: u16,
    args: []const Value,
};

pub const PartialApp = struct {
    func: Value,
    args: []const Value,
};

pub const ContextString = struct {
    text: InternId,
    context: []const AttrEntry,
};

pub const PendingBytecodeThunk = struct {
    chunk_id: ChunkId,
    range: ValueRange,
};

const BuiltinClosureObject = struct {
    builtin_id: u16,
    args: ValueRange,
};

const ClosureObject = struct {
    chunk_id: ChunkId,
    upvalues: ValueRange,
};

/// A partial application: an uncurried (arity>1) `func` closure with
/// `0 < args.len < arity` parameters already supplied. Applying the
/// remaining args runs the body. Modeled exactly like
/// `BuiltinClosureObject` — a callable plus its accumulated args.
const PartialAppObject = struct {
    func: Value,
    args: ValueRange,
};

const ContextStringObject = struct {
    text: InternId,
    context: AttrRange,
};

/// An attrset slot: the sorted attr entries plus optional source
/// positions for `unsafeGetAttrPos` / error messages. Positions used to
/// live in a separate `meta` field on every heap object; folding them
/// into the attrs variant (which is far smaller than the thunk variant
/// that sizes the union) let the per-object `meta` field be removed
/// entirely — a ~20% shrink across all heap objects, the vast majority
/// of which carry no positions. `positions.len == 0` means "no
/// positions"; it is never sliced.
pub const AttrsObject = struct {
    range: AttrRange,
    positions: AttrPosRange = EMPTY_ATTR_POS,
    /// Demand-sibling prefetch (`FIX_SIBLING`): has this set already been
    /// swept? Once-per-attrset dedup for `force_attrs_sweep` submission.
    /// Plain bool in existing union padding (the thunk variant sizes the
    /// union); racy-benign — a lost race means one duplicate sweep task,
    /// which the per-thunk claim CAS makes idempotent.
    sibling_swept: bool = false,
};

/// A lazy, layered `//` (update) result: `base // overlay`, both attrset
/// objects (either may itself be a `merge_attrs`, forming a chain). The
/// NixOS module/overlay fixpoints build a massive attrset by `//`-ing an
/// accumulator thousands of times; materializing each step copies the
/// whole accumulator (O(N) per merge → O(N·K) total, and ~18M of the
/// 19.4M attr-store entries are these throwaway copies). Layering makes a
/// large `//` O(1): just record `base`+`overlay`. `//` is *shallow*
/// right-biased, so lookup checks `overlay` then `base`; the (obj,name)
/// inline cache absorbs repeated lookups. The chain is flattened (one
/// real merge) once `depth` exceeds `MERGE_FLATTEN_DEPTH`, bounding both
/// lookup depth and the chain length any single flatten must walk.
/// `flattened` memoizes the flattened plain-attrs object (NO_FLAT until
/// first `getAttrs`/iteration forces it).
pub const MergeAttrsObject = struct {
    base: ObjectId,
    overlay: ObjectId,
    depth: u16,
    flattened: std.atomic.Value(ObjectId),
};

/// Sentinel for `MergeAttrsObject.flattened` meaning "not yet flattened".
pub const NO_FLAT: ObjectId = std.math.maxInt(ObjectId);

/// Only layer `a // b` when `a` is at least this large — small merges
/// (literal `{..} // {..}`) stay eager so the common cheap case keeps its
/// flat single-binary-search lookup and pays no indirection.
const MERGE_LAYER_MIN: u32 = 32;

/// Flatten a layer chain once it gets this deep, so `getAttrValue` walks
/// at most this many overlays and each flatten merges a bounded chain.
const MERGE_FLATTEN_DEPTH: u16 = 8;

pub const Object = union(enum) {
    list: ValueRange,
    attrs: AttrsObject,
    merge_attrs: MergeAttrsObject,
    closure: ClosureObject,
    builtin_closure: BuiltinClosureObject,
    thunk: Thunk,
    context_string: ContextStringObject,
    /// Heap-boxed full-range i64 for values that don't fit Value's
    /// 48-bit inline int payload. See `runtime/int.zig`.
    boxed_int: i64,
    partial_app: PartialAppObject,
};

/// Per-worker thread-local allocation buffer. Each worker reserves a
/// chunk of slots from the global stores under their mutex once, then
/// hands them out lock-free for subsequent ops until the chunk is used.
/// This keeps the hot path off the global mutex on workloads that
/// allocate many small ranges (lists, attrsets, closure upvalues).
///
/// We only TLAB the range-typed stores (values, attrs, attr_positions).
/// The `objects` store is still global so that `objects.count()` reflects
/// the next ObjectId assigned — `buildAttrSet` predicts that id to
/// construct the `builtins.builtins` self-reference.
const OBJECT_CHUNK_SIZE: u32 = 256;
const VALUE_CHUNK_SIZE: u32 = 1024;
const ATTR_CHUNK_SIZE: u32 = 512;
const ATTR_POS_CHUNK_SIZE: u32 = 256;

/// Scavenger ring capacity (power of two). Each worker records the ids
/// of thunks it creates; idle peers (FIX_SCAVENGE) force the oldest
/// still-unresolved ones speculatively. 64K ids = 256KB per worker.
pub const SCAV_RING_SIZE: u32 = 1 << 16;

// Copying nursery (`-Dgc`): the low `NURSERY_SEGS_*` segments of each range
// store are the resettable young generation; the rest is tenured. Capacity =
// first_segment_size * (2^N - 1) slots. With first_segment_size {values 1024,
// attrs 512, attr_pos 512} and N below the nursery is ~16 MB for values and
// ~16 MB for attrs — a minor fires when whichever store's nursery fills. A
// young range is one whose `segment < nursery_segs` (no tag bit needed).
const NURSERY_SEGS_VALUES: u32 = 13;
const NURSERY_SEGS_ATTRS: u32 = 13;
const NURSERY_SEGS_ATTR_POS: u32 = 13;

const LocalSlice = struct { segment: u32, offset: u32, len: u32 };

const LocalChunk = struct {
    segment: u32 = 0,
    cursor: u32 = 0,
    end: u32 = 0,

    fn fits(self: LocalChunk, n: u32) bool {
        return self.cursor + n <= self.end;
    }

    fn take(self: *LocalChunk, n: u32) LocalSlice {
        const r: LocalSlice = .{ .segment = self.segment, .offset = self.cursor, .len = n };
        self.cursor += n;
        return r;
    }
};

pub const HeapLocal = struct {
    object: LocalChunk = .{},
    value: LocalChunk = .{},
    attr: LocalChunk = .{},
    attr_pos: LocalChunk = .{},
    /// Scavenger ring (FIX_SCAVENGE, see `Worker.scavengeStep`): ids of
    /// thunks this worker created, in creation order. Single-writer (the
    /// owning worker); idle helpers scan worker 0's ring for old,
    /// still-unresolved thunks with proven-expensive bodies. `scav_head`
    /// is the monotonic count of entries written, release-published
    /// after each ring store; `scav_head_local` is the writer's
    /// non-atomic mirror (avoids an RMW on the hot path).
    scav_ring: [SCAV_RING_SIZE]ObjectId = undefined,
    scav_head_local: u64 = 0,
    scav_head: std.atomic.Value(u64) = .init(0),
    /// Monotonic count of thunks this worker has created. One plain add
    /// on a cache line the allocation already touches; used by the
    /// sibling-sweep diagnostics (`FIX_SIBLING_LOG`) to attribute
    /// evaluation cascades to individual speculative member forces.
    thunks_created: u64 = 0,
    /// Creation-context flag: true while the fiber currently running on
    /// this worker thread is doing SPECULATIVE work (any
    /// `forceValueSpeculative`, including nested import VMs it spawns),
    /// false on the demand chain. Maintained by `Worker.runFiber` (from
    /// the resumed fiber's `vm.in_speculation`) and toggled by
    /// `forceValueSpeculative` itself. Single-writer (the owning thread);
    /// read at thunk creation to tag demand-created thunks for the
    /// scavenger / `-Dprof-main` creation-context probe.
    spec_ctx: bool = false,
    // GC per-worker free lists (`-Dgc`): lock-free reclaim reuse. The sweep
    // (STW, single collector) distributes freed slots/ranges round-robin
    // across every worker's shard; each worker's allocation hot path then pops
    // from its OWN shard with no lock — this is what makes reclaim viable at
    // --workers>1 (a single shared free list serialized all allocation). A
    // worker whose shard lacks the needed size just bump-allocates.
    gc_free_objects: if (build_options.gc) std.ArrayListUnmanaged(ObjectId) else void = if (build_options.gc) .empty else {},
    gc_free_values: if (build_options.gc) RangeFreeList else void = if (build_options.gc) .{} else {},
    gc_free_attrs: if (build_options.gc) RangeFreeList else void = if (build_options.gc) .{} else {},
    gc_free_attr_pos: if (build_options.gc) RangeFreeList else void = if (build_options.gc) .{} else {},
    /// Copying-nursery remembered set: `source` object ids (already old) that
    /// were written a pointer to a young object since the last minor. Per-worker
    /// and single-owner, so the write barrier (`gcRecordEdge`) appends without a
    /// lock. Drained (STW) at the next minor to seed the young referents that
    /// only an old object keeps alive; cleared after.
    gc_remset: if (build_options.gc) std.ArrayListUnmanaged(ObjectId) else void = if (build_options.gc) .empty else {},
    /// This worker's young objects since the last minor (every id from
    /// `reserveObjectSlot`, including reused slots). The STW minor iterates
    /// exactly these — O(young) — and clears the list. Reuse- and TLAB-tail-
    /// safe, unlike an id-range frontier.
    gc_young_slots: if (build_options.gc) std.ArrayListUnmanaged(ObjectId) else void = if (build_options.gc) .empty else {},

    fn deinit(self: *HeapLocal, allocator: std.mem.Allocator) void {
        if (comptime !build_options.gc) return;
        self.gc_free_objects.deinit(allocator);
        self.gc_free_values.deinit(allocator);
        self.gc_free_attrs.deinit(allocator);
        self.gc_free_attr_pos.deinit(allocator);
        self.gc_remset.deinit(allocator);
        self.gc_young_slots.deinit(allocator);
    }
};

/// GC collect hook (gated behind `-Dgc`). The heap can't reach the
/// evaluator's roots, so the evaluator registers a mark+sweep callback the
/// heap fires from `gcRunCollect` at a safepoint. Type-erased to keep the
/// heap free of an `eval`/`gc` import cycle. `collector_id` is the worker
/// that won the collection (its marker slot in the parallel mark).
pub const GcHook = struct {
    ctx: *anyopaque,
    sample: *const fn (*anyopaque, collector_id: u8) void,
};

/// Exact-fit free list of reclaimed ranges in one segmented store, keyed
/// by length: `len -> stack of packed (segment<<32 | offset)`. Exact-fit
/// (no rounding to size classes) keeps internal fragmentation at zero,
/// which matters for the RSS goal; the module fixpoint re-builds
/// same-shaped structures so same-length reuse hits often. All ops are
/// best-effort — on OOM growing the list we simply don't record the free
/// range (it stays allocated), never corrupting state.
const RangeFreeList = struct {
    map: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u64)) = .empty,

    pub fn push(self: *RangeFreeList, allocator: std.mem.Allocator, segment: u32, offset: u32, len: u32) void {
        const gop = self.map.getOrPut(allocator, len) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(allocator, (@as(u64, segment) << 32) | offset) catch {};
    }

    const Loc = struct { segment: u32, offset: u32 };

    fn pop(self: *RangeFreeList, len: u32) ?Loc {
        const entry = self.map.getPtr(len) orelse return null;
        const bits = entry.pop() orelse return null;
        return .{ .segment = @intCast(bits >> 32), .offset = @intCast(bits & 0xFFFF_FFFF) };
    }

    fn deinit(self: *RangeFreeList, allocator: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        self.map.deinit(allocator);
    }
};

/// Result of one `sweep`.
pub const SweepStats = struct {
    objects_freed: u64 = 0,
};

pub const ObjectHeap = struct {
    allocator: std.mem.Allocator,
    objects: ObjectStore,
    values: ValueStore,
    attrs: AttrStore,
    attr_positions: AttrPosStore,
    /// One entry per worker (including the main thread). Indexed by
    /// `worker_id_mod.current`.
    worker_locals: []HeapLocal,
    /// All `ErrorInfo` allocations produced by `Thunk.errored`, recorded
    /// at publish time so `deinit` can release them in O(errored_thunks)
    /// rather than walking every object slot. Almost always tiny — a
    /// realistic NixOS toplevel produces ~hundreds of entries against a
    /// heap of millions of objects.
    errored_infos: std.ArrayListUnmanaged(*ErrorInfo),
    errored_infos_mu: stable.SpinMutex,
    /// Unique-per-init id for cache invalidation. Same trick as the
    /// intern table: thread-local caches outlive an Evaluator, and the
    /// allocator can reuse heap addresses, so a stale slot would match
    /// pointer equality even though it refers to a freed heap.
    token: u64,
    /// Record thunk creations into the per-worker scavenger rings
    /// (FIX_SCAVENGE). Set once before helpers start; read-only after.
    scav_record: bool = false,
    /// Object-store pre-toucher: a background thread that keeps the flat
    /// reservation populated (`MADV_POPULATE_WRITE`) a few MB ahead of
    /// the bump cursor, absorbing the store's first-touch minor faults
    /// (~700 MB / ~170K faults per NixOS toplevel — the single biggest
    /// fault surface) onto an idle core instead of the evaluating
    /// thread. Spawned lazily once the store is big enough to matter, so
    /// small evals (unit tests) never start it. Data-race-free by
    /// construction: population is kernel-side and value-preserving.
    toucher: ?std.Thread = null,
    toucher_state: std.atomic.Value(u8) = .init(0), // 0 = not started, 1 = running
    toucher_stop: std.atomic.Value(bool) = .init(false),
    /// GC Phase 0 (`-Dgc`): periodic live-set sampler. `void` in normal
    /// builds so there is zero footprint.
    gc_hook: if (build_options.gc) ?GcHook else void = if (build_options.gc) null else {},
    /// Set by the allocation path when total reserved bytes cross
    /// `gc_threshold_bytes`; consumed at the next safepoint poll.
    gc_collect_requested: if (build_options.gc) bool else void = if (build_options.gc) false else {},
    gc_threshold_bytes: if (build_options.gc) u64 else void = if (build_options.gc) std.math.maxInt(u64) else {},
    /// GC reclaim state (`-Dgc`). Inert until `gc_collect_enabled` is set
    /// (the evaluator turns it on only at `--workers=1` for now — the
    /// alloc-bitmap maintenance is not yet thread-safe). When off, the
    /// allocator hot path is exactly as in a non-`-Dgc` build.
    gc_collect_enabled: if (build_options.gc) bool else void = if (build_options.gc) false else {},
    /// First ObjectId tracked by the alloc-bitmap (set at gcEnableCollect).
    /// Objects created before collection was enabled aren't tracked/swept,
    /// so the detector's assert skips them.
    gc_track_from: if (build_options.gc) ObjectId else void = if (build_options.gc) 0 else {},
    /// One bit per ObjectId: set when a slot is *filled* (a real object),
    /// cleared when swept. Lets `sweep` tell live objects from TLAB-
    /// reserved-but-unfilled slots and already-freed slots.
    gc_alloc_bits: if (build_options.gc) []u64 else void = if (build_options.gc) &.{} else {},
    /// Copying-nursery generation bitmap: one bit per ObjectId, set ⇒ **old**
    /// (tenured). Clear (or beyond the array) ⇒ **young**. Written ONLY at a
    /// stop-the-world minor (promote sets it; a future major clears it on
    /// free), so there is NO allocation-path barrier — a freshly bumped slot is
    /// young by default. Grown (zeroed) at each minor to cover the object count.
    gc_old_bits: if (build_options.gc) []u64 else void = if (build_options.gc) &.{} else {},
    /// Parallel non-moving SWEEP coordination (`--workers>1`; the `gc_evac_*`
    /// names are historical — the minor no longer evacuates). The young-object
    /// lists (`worker_locals[*].gc_young_slots`) form a work queue: each helping
    /// worker atomically claims a list index via `gc_evac_next` and sweeps it
    /// (promote marked survivors in place; free dead ranges to ITS OWN free-list
    /// shard), then bumps `gc_evac_done`. The collector opens the phase via
    /// `gc_evac_open` (after verifying mark closure) and waits until
    /// `gc_evac_done == gc_evac_count`.
    gc_evac_open: if (build_options.gc) std.atomic.Value(bool) else void = if (build_options.gc) .init(false) else {},
    gc_evac_next: if (build_options.gc) std.atomic.Value(u32) else void = if (build_options.gc) .init(0) else {},
    gc_evac_done: if (build_options.gc) std.atomic.Value(u32) else void = if (build_options.gc) .init(0) else {},
    gc_evac_count: if (build_options.gc) u32 else void = if (build_options.gc) 0 else {},
    /// Dynamic marker-slot dispenser. The parallel collection is CAPPED at
    /// `min(worker_count, GC_PAR_CAP)` participants because the mark+evac is
    /// contention-bound: it bottoms out around 8 workers and gets *worse* past
    /// that (shared mark bitmap + old-bits + TLAB-refill cache-line bouncing).
    /// Each helping worker grabs the next slot; a worker whose slot is beyond
    /// the cap parks idle rather than piling on. Reset per collection.
    gc_mark_slot: if (build_options.gc) std.atomic.Value(u32) else void = if (build_options.gc) .init(0) else {},
    gc_evac_promoted: if (build_options.gc) std.atomic.Value(u64) else void = if (build_options.gc) .init(0) else {},
    gc_evac_freed: if (build_options.gc) std.atomic.Value(u64) else void = if (build_options.gc) .init(0) else {},
    // Free lists are PER-WORKER (`HeapLocal.gc_free_*`) so the allocation hot
    // path reuses without a lock — a single shared free list + mutex
    // serialized all allocation across workers and was the entire w>1 wall
    // cost (measured: 3.8x). The sweep (STW, single collector) distributes
    // freed memory round-robin across the per-worker shards.

    /// Nursery size (segments) for a range store. Scales with worker count:
    /// each STW minor stalls ALL workers, so at higher parallelism we amortize
    /// over a bigger nursery (fewer collections). `+1 segment` ≈ doubles the
    /// capacity; capped so it doesn't overshoot to zero collections (no
    /// reclaim). `FIX_GC_NURSERY_SEGS` overrides the per-store base for tuning.
    /// Optional compile-time-set override for the nursery base (set once from
    /// the evaluator, which can read env). 0 = use the passed base.
    var gc_nursery_base_override: u32 = 0;
    pub fn gcSetNurseryBase(n: u32) void {
        if (comptime !build_options.gc) return;
        if (n > 0 and n < 26) gc_nursery_base_override = n;
    }

    fn gcNurserySegs(base: u32, worker_count: u8) u32 {
        _ = worker_count;
        // Worker-count scaling was measured net-negative with the current
        // SERIAL O(total-objects) minor: a bigger nursery cuts collections but
        // raises RSS and each collection still does O(count) reconstruct+walk,
        // so wall barely moves. Making w>1 fast needs parallel + O(young)
        // minors first (then revisit scaling). For now: fixed base.
        return if (gc_nursery_base_override != 0) gc_nursery_base_override else base;
    }

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !ObjectHeap {
        var objects = try ObjectStore.init();
        errdefer objects.deinit(allocator);
        const locals = try allocator.alloc(HeapLocal, @max(worker_count, 1));
        for (locals) |*l| l.* = .{};
        var values: ValueStore = .empty;
        var attrs: AttrStore = .empty;
        var attr_positions: AttrPosStore = .empty;
        // Partition each range store into a young nursery (low segments) +
        // tenured region. Done here, before any allocation, so pre-collect
        // bootstrap (builtins) tenures directly and post-collect allocations
        // bump the nursery. Zero-cost in non-`-Dgc` builds.
        if (comptime build_options.gc) {
            values.enableNursery(gcNurserySegs(NURSERY_SEGS_VALUES, worker_count));
            attrs.enableNursery(gcNurserySegs(NURSERY_SEGS_ATTRS, worker_count));
            attr_positions.enableNursery(gcNurserySegs(NURSERY_SEGS_ATTR_POS, worker_count));
        }
        return .{
            .allocator = allocator,
            .objects = objects,
            .values = values,
            .attrs = attrs,
            .attr_positions = attr_positions,
            .worker_locals = locals,
            .errored_infos = .empty,
            .errored_infos_mu = .{},
            .token = next_heap_token.fetchAdd(1, .monotonic),
        };
    }

    pub fn deinit(self: *ObjectHeap) void {
        if (self.toucher) |t| {
            self.toucher_stop.store(true, .release);
            t.join();
            self.toucher = null;
        }
        self.freeErroredInfos();
        if (comptime build_options.gc) {
            self.allocator.free(self.gc_alloc_bits);
            self.allocator.free(self.gc_old_bits);
            for (self.worker_locals) |*l| l.deinit(self.allocator);
        }
        self.allocator.free(self.worker_locals);
        self.attr_positions.deinit(self.allocator);
        self.attrs.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    /// Record a freshly-allocated `ErrorInfo` so `deinit` can release it
    /// without scanning the object store. Called by `Thunk.errored` via
    /// the heap's tracker — see `vm/force.zig`'s `publishThunkFailure`.
    pub fn trackErroredInfo(self: *ObjectHeap, info: *ErrorInfo) !void {
        self.errored_infos_mu.lock();
        defer self.errored_infos_mu.unlock();
        try self.errored_infos.append(self.allocator, info);
    }

    fn freeErroredInfos(self: *ObjectHeap) void {
        // Single-threaded by the time deinit runs; no need to lock.
        for (self.errored_infos.items) |info| {
            if (info.message) |msg| self.allocator.free(msg);
            self.allocator.destroy(info);
        }
        self.errored_infos.deinit(self.allocator);
    }

    pub const Stats = struct {
        objects: u32,
        values: u32,
        attrs: u32,
        attr_positions: u32,
        variant_counts: [9]u32,
        thunk_states: [5]u32,
        /// Of the `resolved` thunks (thunk_states[2]), the split by
        /// `Future.demanded`: `resolved_demanded` were observed by a real
        /// (demand) caller; `resolved_undemanded` were pre-forced by
        /// speculation / fan-out and never observed — the speculative-waste
        /// fraction. See docs/plans/parallel-redesign-plan.md (instrument I1).
        resolved_demanded: u32,
        resolved_undemanded: u32,
        /// Magnitude histogram for inline `.int` values found in the
        /// values + attrs stores. Buckets are chosen to inform a 16→8
        /// byte Value migration: a NaN-boxed Value can hold a 48-bit
        /// sign-extended integer inline, so `int_overflows_i48` is the
        /// count that would have to be heap-boxed.
        ///
        ///   0 = zero
        ///   1 = |x| < 2^15  (i16 range)
        ///   2 = |x| < 2^31  (i32 range)
        ///   3 = |x| < 2^47  (i48 range — NaN-box inline limit)
        ///   4 = |x| >= 2^47 (would require boxing under NaN-boxing)
        int_buckets: [5]u32,

        pub fn variantName(index: usize) []const u8 {
            return switch (index) {
                0 => "list",
                1 => "attrs",
                2 => "closure",
                3 => "builtin_closure",
                4 => "thunk",
                5 => "context_string",
                6 => "boxed_int",
                7 => "merge_attrs",
                8 => "partial_app",
                else => "?",
            };
        }

        pub fn thunkStateName(index: usize) []const u8 {
            return switch (index) {
                0 => "unresolved",
                1 => "evaluating",
                2 => "resolved",
                3 => "blackhole",
                4 => "errored",
                else => "?",
            };
        }

        pub fn intBucketLabel(index: usize) []const u8 {
            return switch (index) {
                0 => "zero",
                1 => "i16",
                2 => "i32",
                3 => "i48",
                4 => ">=2^47",
                else => "?",
            };
        }

        pub fn intTotal(self: Stats) u32 {
            var t: u32 = 0;
            for (self.int_buckets) |c| t += c;
            return t;
        }

        pub fn intOverflowsI48(self: Stats) u32 {
            return self.int_buckets[4];
        }
    };

    /// Aggregate runtime stats. Safe only when there are no concurrent
    /// writers — the inspector calls this once evaluation has finished.
    pub fn stats(self: *const ObjectHeap) Stats {
        var result: Stats = .{
            .objects = self.objects.count(),
            .values = self.values.count(),
            .attrs = self.attrs.count(),
            .attr_positions = self.attr_positions.count(),
            .variant_counts = [_]u32{0} ** 9,
            .thunk_states = [_]u32{0} ** 5,
            .resolved_demanded = 0,
            .resolved_undemanded = 0,
            .int_buckets = [_]u32{0} ** 5,
        };

        // Per-worker TLABs reserve a chunk of slots from each global store
        // but fill them one at a time. Slots between `cursor` and `end`
        // are reserved but unfilled — their payload is undefined memory.
        // Build per-store skip sets so the scans below don't read garbage.
        const obj_skip = self.collectUnfilled(.object);
        const val_skip = self.collectUnfilled(.value);
        const attr_skip = self.collectUnfilled(.attr);

        var id: u32 = 0;
        const total_objs = result.objects;
        scan_obj: while (id < total_objs) : (id += 1) {
            if (obj_skip.skipPast(id)) |next| {
                id = next - 1;
                continue :scan_obj;
            }
            const obj = self.objects.get(id);
            const v_index: usize = switch (obj.*) {
                .list => 0,
                .attrs => 1,
                .closure => 2,
                .builtin_closure => 3,
                .thunk => |t| blk: {
                    const state = t.future.state.load(.acquire);
                    const s_index: usize = @intCast(@min(state, 4));
                    result.thunk_states[s_index] += 1;
                    // Split resolved thunks by whether a real caller ever
                    // demanded the value (vs. pre-forced and unobserved).
                    if (s_index == 2) {
                        if (t.future.isDemanded()) {
                            result.resolved_demanded += 1;
                        } else {
                            result.resolved_undemanded += 1;
                        }
                    }
                    break :blk 4;
                },
                .context_string => 5,
                .boxed_int => 6,
                .merge_attrs => 7,
                .partial_app => 8,
            };
            result.variant_counts[v_index] += 1;
        }

        // Walk the values + attrs stores for inline `.int` magnitudes.
        // Lists, closure upvalues, and thunk-args all live in `values`;
        // attrset values live in `attrs`. These two cover every place an
        // int Value can be heap-resident — the VM stack contains transient
        // ints during execution but is empty by the time stats() runs.
        var vid: u32 = 0;
        scan_val: while (vid < result.values) : (vid += 1) {
            if (val_skip.skipPast(vid)) |next| {
                vid = next - 1;
                continue :scan_val;
            }
            bucketInt(&result.int_buckets, self.values.get(vid).*);
        }
        var aid: u32 = 0;
        scan_attr: while (aid < result.attrs) : (aid += 1) {
            if (attr_skip.skipPast(aid)) |next| {
                aid = next - 1;
                continue :scan_attr;
            }
            bucketInt(&result.int_buckets, self.attrs.get(aid).value);
        }
        return result;
    }

    // ---- `-Dprof-main` demand-prediction de-risk censuses ----
    //
    // Exit-time (no concurrent writers) heap walks that size the junk
    // ratio of two candidate prefetch mechanisms BEFORE building them:
    //   - creation census: thunks by creation context (demand chain vs.
    //     speculative work) × final observation state — the selection
    //     precision of a "scavenge only demand-fiber creations" policy.
    //   - sibling census: for attrsets with >= 1 demanded member, what
    //     fraction of their thunk members is ever demanded — the junk
    //     ratio of a "first member access sweeps the siblings" prefetch.
    // Print-only; compiled out unless `-Dprof-main`.

    pub fn profCreationCensus(self: *const ObjectHeap) void {
        if (comptime !prof_census_enabled) return;
        const Cell = struct {
            n: u64 = 0,
            dem_old: u64 = 0,
            dem_young: u64 = 0,
            never_resolved_spec: u64 = 0, // resolved but never demanded
            never_unresolved: u64 = 0,
            errored: u64 = 0,
        };
        var cells: [2]Cell = @splat(.{}); // [0]=demand-created, [1]=spec-created
        const obj_skip = self.collectUnfilled(.object);
        var id: u32 = 0;
        const total = self.objects.count();
        scan: while (id < total) : (id += 1) {
            if (obj_skip.skipPast(id)) |next| {
                id = next - 1;
                continue :scan;
            }
            switch (self.objects.get(id).*) {
                .thunk => |t| {
                    const cell = &cells[if (t.future.created_demand) 0 else 1];
                    cell.n += 1;
                    const state = t.future.state.load(.acquire);
                    if (t.future.isDemanded()) {
                        if (t.future.demanded_old) cell.dem_old += 1 else cell.dem_young += 1;
                    } else switch (state) {
                        2 => cell.never_resolved_spec += 1, // resolved
                        3, 4 => cell.errored += 1, // blackhole / errored
                        else => cell.never_unresolved += 1,
                    }
                },
                else => {},
            }
        }
        for (cells, 0..) |c, i| {
            if (c.n == 0) continue;
            std.debug.print(
                "prof creation-census [{s}]: n={d} demanded_old={d} ({d:.1}%) demanded_young={d} ({d:.1}%) never:spec_resolved={d} ({d:.1}%) never:unresolved={d} ({d:.1}%) errored={d}\n",
                .{
                    if (i == 0) "demand-created" else "spec-created",
                    c.n,
                    c.dem_old,             profPct(c.dem_old, c.n),
                    c.dem_young,           profPct(c.dem_young, c.n),
                    c.never_resolved_spec, profPct(c.never_resolved_spec, c.n),
                    c.never_unresolved,    profPct(c.never_unresolved, c.n),
                    c.errored,
                },
            );
        }
    }

    pub fn profSiblingCensus(self: *const ObjectHeap) void {
        if (comptime !prof_census_enabled) return;
        // Size buckets: [4,8) [8,16) [16,32) [32,64) [64,256) [256,inf)
        const bucket_lo = [_]usize{ 4, 8, 16, 32, 64, 256 };
        const Bucket = struct {
            sets: u64 = 0,
            touched: u64 = 0,
            all_demanded_sets: u64 = 0,
            // Members of TOUCHED sets only (thunk-valued members):
            members: u64 = 0,
            dem_old: u64 = 0,
            dem_young: u64 = 0,
            spec_resolved: u64 = 0, // resolved, never demanded
            unresolved: u64 = 0,
        };
        var buckets: [bucket_lo.len]Bucket = @splat(.{});
        var merge_attrs_n: u64 = 0;
        const obj_skip = self.collectUnfilled(.object);
        var id: u32 = 0;
        const total = self.objects.count();
        scan: while (id < total) : (id += 1) {
            if (obj_skip.skipPast(id)) |next| {
                id = next - 1;
                continue :scan;
            }
            const entries: []const AttrEntry = switch (self.objects.get(id).*) {
                .attrs => |a| self.attrs.slice(a.range),
                .merge_attrs => {
                    merge_attrs_n += 1;
                    continue :scan;
                },
                else => continue :scan,
            };
            if (entries.len < bucket_lo[0]) continue :scan;
            var bi: usize = bucket_lo.len - 1;
            while (entries.len < bucket_lo[bi]) bi -= 1;
            const b = &buckets[bi];
            b.sets += 1;
            var members: u64 = 0;
            var dem_old: u64 = 0;
            var dem_young: u64 = 0;
            var spec_resolved: u64 = 0;
            var unresolved: u64 = 0;
            for (entries) |entry| {
                if (!entry.value.isThunk()) continue;
                switch (self.objects.get(entry.value.asObjectId()).*) {
                    .thunk => |t| {
                        members += 1;
                        if (t.future.isDemanded()) {
                            if (t.future.demanded_old) dem_old += 1 else dem_young += 1;
                        } else if (t.future.state.load(.acquire) == 2) {
                            spec_resolved += 1;
                        } else {
                            unresolved += 1;
                        }
                    },
                    else => {},
                }
            }
            if (dem_old + dem_young == 0) continue :scan; // untouched set
            b.touched += 1;
            if (dem_old + dem_young == members) b.all_demanded_sets += 1;
            b.members += members;
            b.dem_old += dem_old;
            b.dem_young += dem_young;
            b.spec_resolved += spec_resolved;
            b.unresolved += unresolved;
        }
        std.debug.print("prof sibling-census (attrsets by entry count; member stats over TOUCHED sets = >=1 demanded member; merge_attrs skipped n={d}):\n", .{merge_attrs_n});
        var tot: Bucket = .{};
        for (buckets, 0..) |b, i| {
            tot.sets += b.sets;
            tot.touched += b.touched;
            tot.all_demanded_sets += b.all_demanded_sets;
            tot.members += b.members;
            tot.dem_old += b.dem_old;
            tot.dem_young += b.dem_young;
            tot.spec_resolved += b.spec_resolved;
            tot.unresolved += b.unresolved;
            if (b.sets == 0) continue;
            std.debug.print(
                "  size>={d:<3}: sets={d} touched={d} all_dem={d} members={d} dem_old={d} ({d:.1}%) dem_young={d} ({d:.1}%) spec_res={d} ({d:.1}%) unres={d} ({d:.1}%)\n",
                .{
                    bucket_lo[i], b.sets, b.touched, b.all_demanded_sets, b.members,
                    b.dem_old,       profPct(b.dem_old, b.members),
                    b.dem_young,     profPct(b.dem_young, b.members),
                    b.spec_resolved, profPct(b.spec_resolved, b.members),
                    b.unresolved,    profPct(b.unresolved, b.members),
                },
            );
        }
        std.debug.print(
            "  TOTAL     : sets={d} touched={d} all_dem={d} members={d} dem_old={d} ({d:.1}%) dem_young={d} ({d:.1}%) spec_res={d} ({d:.1}%) unres={d} ({d:.1}%)\n",
            .{
                tot.sets, tot.touched, tot.all_demanded_sets, tot.members,
                tot.dem_old,       profPct(tot.dem_old, tot.members),
                tot.dem_young,     profPct(tot.dem_young, tot.members),
                tot.spec_resolved, profPct(tot.spec_resolved, tot.members),
                tot.unresolved,    profPct(tot.unresolved, tot.members),
            },
        );
    }

    fn profPct(x: u64, total: u64) f64 {
        return if (total == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(total));
    }

    pub const Store = enum { object, value, attr };
    pub const SkipSet = struct {
        starts: [256]u32 = undefined,
        ends: [256]u32 = undefined,
        len: usize = 0,

        /// If `id` falls inside an unfilled range, returns the first
        /// filled id past it; otherwise null. Callers use the returned id
        /// to skip the loop forward (subtract 1 to compensate for the
        /// loop's increment).
        fn skipPast(self: SkipSet, id: u32) ?u32 {
            for (self.starts[0..self.len], self.ends[0..self.len]) |s, e| {
                if (id >= s and id < e) return e;
            }
            return null;
        }
    };

    pub fn collectUnfilled(self: *const ObjectHeap, comptime store: Store) SkipSet {
        var set: SkipSet = .{};
        for (self.worker_locals) |local| {
            const chunk = switch (store) {
                .object => local.object,
                .value => local.value,
                .attr => local.attr,
            };
            if (chunk.cursor >= chunk.end) continue;
            if (set.len >= set.starts.len) break;
            const start = switch (store) {
                .object => ObjectStore.globalIdOf(chunk.segment, chunk.cursor),
                .value => ValueStore.globalIdOf(chunk.segment, chunk.cursor),
                .attr => AttrStore.globalIdOf(chunk.segment, chunk.cursor),
            };
            const end = switch (store) {
                .object => ObjectStore.globalIdOf(chunk.segment, chunk.end),
                .value => ValueStore.globalIdOf(chunk.segment, chunk.end),
                .attr => AttrStore.globalIdOf(chunk.segment, chunk.end),
            };
            set.starts[set.len] = start;
            set.ends[set.len] = end;
            set.len += 1;
        }
        return set;
    }

    pub inline fn currentLocal(self: *ObjectHeap) *HeapLocal {
        return &self.worker_locals[worker_id_mod.current];
    }

    /// Update this worker thread's creation-context flag (see
    /// `HeapLocal.spec_ctx`). One store to the worker's own cache line.
    pub inline fn setSpecCtx(self: *ObjectHeap, spec: bool) void {
        self.currentLocal().spec_ctx = spec;
    }

    /// Demand-sibling prefetch admission (`FIX_SIBLING`): true iff `id`
    /// is a plain attrset with entry count in `[min, max)` that has not
    /// been swept yet — and marks it swept. Racy-benign (see
    /// `AttrsObject.sibling_swept`). `merge_attrs` layers are excluded:
    /// sweeping them would force a flatten on the demand path.
    pub fn trySiblingSweep(self: *ObjectHeap, id: ObjectId, min: u32, max: u32) bool {
        switch (self.objects.getMut(id).*) {
            .attrs => |*a| {
                if (a.range.len < min or a.range.len >= max) return false;
                if (a.sibling_swept) return false;
                a.sibling_swept = true;
                return true;
            },
            else => return false,
        }
    }

    /// Undo `trySiblingSweep`'s mark when the sweep task could not be
    /// submitted (queue full / no helpers) — otherwise the set becomes
    /// permanently unsweepable on a transient rejection. Racy-benign
    /// like the mark.
    pub fn clearSiblingSwept(self: *ObjectHeap, id: ObjectId) void {
        switch (self.objects.getMut(id).*) {
            .attrs => |*a| a.sibling_swept = false,
            else => {},
        }
    }

    /// TLAB reserve shared by the three range stores. When reclaim is active
    /// (`gc_collect_enabled`) a reused range is popped from the free list (see
    /// the callers) or a fresh chunk is bumped from the young region; if that
    /// region is full the reservation spills to the tenured region so the
    /// allocation always succeeds, and — past the reserved-bytes threshold — a
    /// collection is requested (`gcNurseryFull`). Non-moving: nothing is reset
    /// or relocated; the minor frees dead ranges to the free lists in place.
    /// Otherwise it is the ordinary tenured bump (identical to a non-`-Dgc`
    /// build). A returned range is young iff `segment < nursery_segs`.
    inline fn reserveRangeLocal(
        self: *ObjectHeap,
        comptime StoreT: type,
        store: *StoreT,
        chunk: *LocalChunk,
        chunk_size: u32,
        n: u32,
    ) !StoreT.Range {
        if (chunk.fits(n)) {
            const r = chunk.take(n);
            return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
        }
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled) {
                if (n > chunk_size) {
                    // Oversized reservations bypass the TLAB; tenure directly
                    // if they don't fit a nursery segment.
                    if (try store.reserveYoung(self.allocator, n)) |yr| return yr;
                } else if (try store.reserveYoung(self.allocator, chunk_size)) |cr| {
                    chunk.segment = cr.segment;
                    chunk.cursor = cr.offset;
                    chunk.end = cr.offset + cr.len;
                    const r = chunk.take(n);
                    return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
                }
                // Nursery full: request a minor and spill to tenured below.
                self.gcNurseryFull();
            }
        }
        if (n > chunk_size) return store.reserve(self.allocator, n);
        const refilled = try store.reserve(self.allocator, chunk_size);
        chunk.segment = refilled.segment;
        chunk.cursor = refilled.offset;
        chunk.end = refilled.offset + refilled.len;
        const r = chunk.take(n);
        return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
    }

    fn reserveValuesLocal(self: *ObjectHeap, n: u32) !ValueRange {
        const local = self.currentLocal();
        // NON-MOVING reuse: a swept dead range of exactly `n` is reused in
        // place before touching the bump cursor. Ranges never relocate, so the
        // returned slice is stable across forces (no re-fetch needed).
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled) {
                if (local.gc_free_values.pop(n)) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
            }
        }
        return self.reserveRangeLocal(ValueStore, &self.values, &local.value, VALUE_CHUNK_SIZE, n);
    }

    /// Reserve `n` slots of attr storage for a merge in progress.
    /// Caller writes into the returned range via `attrsMutSlice` and
    /// publishes the final entry count with `publishMergedAttrs`. Used
    /// by attr-set merge primitives to skip a per-merge ArrayList +
    /// extra copy.
    pub fn reserveAttrsForMerge(self: *ObjectHeap, n: u32) !AttrRange {
        // Tenured: the caller holds this reservation's raw `dst` slice across
        // value-merge forces (see vm/objects.zig mergeAttrLiteralObjects). A
        // young reservation would be reclaimed out from under `dst` by a minor's
        // nursery reset. Tenured slots are never reset/evacuated, so `dst` stays
        // valid. (The published object's slot is still young/reclaimable.)
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled) return self.attrs.reserve(self.allocator, n);
        }
        return self.reserveAttrsLocal(n);
    }

    pub fn attrsMutSlice(self: *ObjectHeap, range: AttrRange) []AttrEntry {
        return self.attrs.sliceMut(range);
    }

    /// Commit a partially-filled reservation as a new attrs object.
    /// `actual` is the number of entries written (<= range.len). The
    /// trailing unused slots remain reserved but unreferenced; on the
    /// merge workload the overlap rate makes this waste small
    /// relative to the steady-state attr storage footprint.
    pub fn publishMergedAttrs(self: *ObjectHeap, range: AttrRange, actual: u32) !ObjectId {
        const trimmed: AttrRange = .{
            .segment = range.segment,
            .offset = range.offset,
            .len = actual,
        };
        return self.add(.{ .attrs = .{ .range = trimmed } });
    }

    fn reserveAttrsLocal(self: *ObjectHeap, n: u32) !AttrRange {
        const local = self.currentLocal();
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled) {
                if (local.gc_free_attrs.pop(n)) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
            }
        }
        return self.reserveRangeLocal(AttrStore, &self.attrs, &local.attr, ATTR_CHUNK_SIZE, n);
    }

    fn reserveAttrPositionsLocal(self: *ObjectHeap, n: u32) !AttrPosRange {
        const local = self.currentLocal();
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled) {
                if (local.gc_free_attr_pos.pop(n)) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
            }
        }
        return self.reserveRangeLocal(AttrPosStore, &self.attr_positions, &local.attr_pos, ATTR_POS_CHUNK_SIZE, n);
    }

    /// Threshold hook: once reserved bytes cross `gc_threshold_bytes`, request a
    /// (non-moving) collection to run at the next forceThunk safepoint — it marks
    /// live, promotes survivors in place, and frees dead ranges to the free lists.
    /// The reservation that triggered this has already spilled to the tenured
    /// region so the allocation succeeds now; the spill window (until the
    /// safepoint) is small because forces are frequent.
    inline fn gcNurseryFull(self: *ObjectHeap) void {
        if (comptime !build_options.gc) return;
        // NON-MOVING: request a collect only once reserved bytes cross the
        // threshold (re-armed to cursor+headroom after each collect). Called
        // frequently (every young-full TLAB refill), so it polls the threshold.
        if (self.totalReservedBytes() >= self.gc_threshold_bytes) self.gc_collect_requested = true;
    }

    /// Register the collect callback (no-op in non-`-Dgc` builds). Fired at
    /// a safepoint via `gcRunCollect` when a collection has been requested.
    pub fn setGcHook(self: *ObjectHeap, hook: GcHook) void {
        if (comptime !build_options.gc) return;
        self.gc_hook = hook;
    }

    pub fn add(self: *ObjectHeap, object: Object) !ObjectId {
        const id = try self.reserveObjectSlot();
        self.fillObjectSlot(id, object);
        if (comptime struct_census.enabled) {
            switch (object) {
                .list => |range| struct_census.recordAlloc(id, .list, range.len),
                .attrs => |a| struct_census.recordAlloc(id, .attrs, a.range.len),
                // Layer node is O(1); its structural cost is ~1 entry.
                .merge_attrs => struct_census.recordAlloc(id, .attrs, 1),
                else => {},
            }
        }
        // Scavenger ring (FIX_SCAVENGE): record thunk creations, in
        // order, for idle peers to pre-force. Three stores to this
        // worker's own cache lines; a single predictable branch when off.
        if (self.scav_record and object == .thunk) {
            const local = self.currentLocal();
            const slot = &local.scav_ring[@intCast(local.scav_head_local & (SCAV_RING_SIZE - 1))];
            @atomicStore(ObjectId, slot, id, .release);
            local.scav_head_local += 1;
            local.scav_head.store(local.scav_head_local, .release);
        }
        if (object == .thunk) self.currentLocal().thunks_created += 1;
        // `-Dprof-main` creation-context probe: tag the thunk with whether
        // it was created on the demand chain (vs. inside speculative work).
        // Post-fill, pre-publish — no reader can observe the slot yet.
        if (comptime prof_census_enabled) {
            if (object == .thunk)
                self.objects.getMut(id).thunk.future.created_demand = !self.currentLocal().spec_ctx;
        }
        return id;
    }

    /// Object count above which the pre-toucher pays for its thread:
    /// ~6 MB of store. Real evals blow far past it; unit tests don't.
    const TOUCHER_MIN_SLOTS: u32 = 64 * 1024;
    /// How far past the bump cursor the toucher keeps pages populated.
    /// The store grows ~270 KB/ms at w=1 peak, so 8 MB rides out many
    /// wake-up periods; over-population waste at exit is at most this.
    const TOUCHER_AHEAD_BYTES: usize = 8 << 20;

    /// CAS-guarded lazy spawn (racing workers refill TLABs concurrently).
    fn maybeStartToucher(self: *ObjectHeap) void {
        if (self.toucher_state.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) return;
        self.toucher = std.Thread.spawn(.{ .stack_size = 128 * 1024 }, toucherMain, .{self}) catch {
            self.toucher_state.store(0, .monotonic);
            return;
        };
    }

    fn toucherMain(self: *ObjectHeap) void {
        var populated: usize = self.objects.usedBytes();
        var values_state: ValueStore.PopulateState = .{};
        var attrs_state: AttrStore.PopulateState = .{};
        while (!self.toucher_stop.load(.monotonic)) {
            const target = self.objects.usedBytes() + TOUCHER_AHEAD_BYTES;
            if (target > populated) {
                self.objects.populateRange(populated, target);
                populated = target;
            }
            self.values.populateAhead(&values_state, TOUCHER_AHEAD_BYTES);
            self.attrs.populateAhead(&attrs_state, TOUCHER_AHEAD_BYTES);
            var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = std.os.linux.nanosleep(&req, null);
        }
    }

    /// Reserve an object slot and return its ObjectId without filling
    /// payload. The slot's contents are undefined until `fillObjectSlot`
    /// is called. The ID is only valid to expose once the slot has been
    /// filled — concurrent readers reaching the slot before that would
    /// see garbage. Currently used only at build-time for the
    /// `builtins.builtins` self-reference, where no other thread can
    /// observe the in-flight slot.
    pub fn reserveObjectSlot(self: *ObjectHeap) !ObjectId {
        const local = self.currentLocal();
        const id = blk: {
            if (comptime build_options.gc) {
                // Reuse a slot freed by a prior minor. Detector leaves freed
                // slots unused so use-after-free is caught.
                if (self.gc_collect_enabled and !gc_disable_reuse and !gc_debug) {
                    if (local.gc_free_objects.pop()) |rid| break :blk rid;
                }
            }
            const chunk = &local.object;
            if (chunk.cursor < chunk.end) {
                const cid = ObjectStore.globalIdOf(chunk.segment, chunk.cursor);
                chunk.cursor += 1;
                break :blk cid;
            }
            const refilled = try self.objects.reserve(self.allocator, OBJECT_CHUNK_SIZE);
            chunk.segment = refilled.segment;
            chunk.cursor = refilled.offset;
            chunk.end = refilled.offset + refilled.len;
            // TLAB refill = every OBJECT_CHUNK_SIZE objects: cheap spot to
            // lazily start the pre-toucher once the store is large enough.
            if (comptime builtin.os.tag == .linux) {
                if (refilled.offset >= TOUCHER_MIN_SLOTS and
                    self.toucher_state.load(.monotonic) == 0)
                    self.maybeStartToucher();
            }
            const cid = ObjectStore.globalIdOf(chunk.segment, chunk.cursor);
            chunk.cursor += 1;
            break :blk cid;
        };
        // Record the id in this worker's young-slot list: the minor iterates
        // exactly these (O(young)), and it's robust to slot reuse and the
        // reserved-vs-filled TLAB tail (both of which broke an id-range frontier).
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled) local.gc_young_slots.append(self.allocator, id) catch {};
        }
        return id;
    }

    pub fn fillObjectSlot(self: *ObjectHeap, id: ObjectId, object: Object) void {
        self.objects.getMut(id).* = object;
        // In the UAF-detector build the alloc bitmap must be live between
        // collections (every heap read asserts the bit), so set it per fill.
        // In release builds the bitmap is reconstructed at collection time
        // (`gcReconstructAllocBits`) from the id range minus the free lists,
        // keeping this hot path free of GC work.
        if (comptime gc_debug) {
            if (self.gc_collect_enabled) self.gcSetAllocBit(id);
        }
    }

    // --- GC reclaim (`-Dgc`, single-threaded for now) ---

    /// Floor on the collection threshold.
    pub const GC_MIN_THRESHOLD: u64 = 256 << 20;
    /// Headroom of genuinely-fresh committed pages between collections
    /// (additive, anchored to the cursor at last collect — see
    /// `gcAfterCollect`). Keeps peak RSS near live + a constant.
    pub const GC_HEADROOM: u64 = 1024 << 20;

    /// Validation knob (`FIX_GC_STEP_MB`, `-Dgc` only): when > 0, collect
    /// every this-many MB of fresh allocation instead of the normal additive-
    /// headroom policy. Drives many collections so the detector exercises
    /// every builtin loop. 0 = normal policy. Set from the evaluator (which
    /// owns the env map) via the `step_bytes` arg to `gcEnableCollect`.
    pub var gc_step_bytes: u64 = 0;

    /// Memory budget (`--max-memory` / `FIX_MAX_MEMORY`, `-Dgc` only): the
    /// heap-reserved-bytes ceiling the collector defends. No collection runs
    /// until reserved bytes cross it, so on a machine whose budget exceeds
    /// the eval's total allocation the collector never fires (zero pauses);
    /// on a small-RAM device it kicks in before the eval OOMs. Defaults to
    /// half of `MemAvailable` (see `eval/gc.zig:memoryBudget`). Set via the
    /// `budget` arg to `gcEnableCollect`.
    pub var gc_budget_bytes: u64 = 0;

    /// A/B knob (`FIX_GC_NOREUSE`): skip free-list reuse on the allocation hot
    /// paths (bump-allocate instead). Measurement only — loses the RSS bound.
    /// Lets us isolate reclaim's reuse cost/benefit. Set from the evaluator.
    var gc_disable_reuse: bool = false;
    pub fn gcSetDisableReuse(v: bool) void {
        if (comptime !build_options.gc) return;
        gc_disable_reuse = v;
    }

    /// Is the alloc-bit set for `id`? (Detector helper.) Atomic load — the
    /// bitmap is written concurrently by other workers' fills at --workers>1
    /// (pre-sized in `gcEnableCollect`, so the array never moves).
    fn gcAllocBitSet(self: *const ObjectHeap, id: ObjectId) bool {
        const word = id >> 6;
        if (word >= self.gc_alloc_bits.len) return false;
        const w = @atomicLoad(u64, &self.gc_alloc_bits[word], .monotonic);
        return w & (@as(u64, 1) << @intCast(id & 63)) != 0;
    }

    /// Detector: trap if a *tracked* slot is read after being freed.
    inline fn gcAssertLive(self: *const ObjectHeap, id: ObjectId) void {
        if (comptime !gc_debug) return;
        if (self.gc_collect_enabled and id >= self.gc_track_from and !self.gcAllocBitSet(id)) {
            // Reuse is off in the detector, so the slot still holds its real
            // payload — print the kind so we know which root is missing.
            std.debug.print("GC use-after-free: object {d} (kind={s}) read after sweep\n", .{ id, @tagName(self.objects.get(id).*) });
            @panic("gc use-after-free");
        }
    }

    /// Total bytes ever reserved across the four stores — the committed-RSS
    /// proxy. Reuse keeps the cursors (and this) from growing, so it
    /// plateaus near the threshold once collection keeps up.
    pub fn totalReservedBytes(self: *const ObjectHeap) u64 {
        return @as(u64, self.objects.count()) * @sizeOf(Object) +
            @as(u64, self.values.reservedSlots()) * @sizeOf(Value) +
            @as(u64, self.attrs.reservedSlots()) * @sizeOf(AttrEntry) +
            @as(u64, self.attr_positions.reservedSlots()) * @sizeOf(AttrPosEntry);
    }

    pub fn gcCollectRequested(self: *const ObjectHeap) bool {
        if (comptime !build_options.gc) return false;
        return self.gc_collect_requested;
    }

    /// Rebuild the alloc bitmap (which slots are filled-and-live) from
    /// scratch at a collection safepoint, so the per-alloc fast path needn't
    /// set bits incrementally. Filled = every tracked id `[track_from,
    /// count)` MINUS (a) each worker's reserved-but-unfilled object-chunk
    /// tail and (b) the currently-free slots. Relies on the object id space
    /// being dense with no gaps other than the per-worker current-chunk tail
    /// — true at `--workers=1` (the only mode reclaim runs in), where the
    /// lone worker fills each chunk fully before refilling. Release builds
    /// only; the detector build keeps the incremental bitmap (it asserts
    /// liveness on every read, between collections).
    fn gcReconstructAllocBits(self: *ObjectHeap) void {
        const n = self.objects.count();
        const words = (@as(usize, n) + 63) >> 6;
        if (self.gc_alloc_bits.len < words) {
            const old_len = self.gc_alloc_bits.len;
            self.gc_alloc_bits = self.allocator.realloc(self.gc_alloc_bits, words) catch return;
            @memset(self.gc_alloc_bits[old_len..words], 0);
        }
        @memset(self.gc_alloc_bits[0..words], 0);
        gcSetBitRange(self.gc_alloc_bits, self.gc_track_from, n);
        // Exclude each worker's reserved-but-unfilled current object chunk.
        for (self.worker_locals) |*wl| {
            const lo = ObjectStore.globalIdOf(wl.object.segment, wl.object.cursor);
            const hi = ObjectStore.globalIdOf(wl.object.segment, wl.object.end);
            if (hi > lo) gcClearBitRange(self.gc_alloc_bits, lo, hi);
        }
        // Exclude slots already on any worker's object free list (freed by a
        // prior collection, not yet reused).
        for (self.worker_locals) |*wl| {
            for (wl.gc_free_objects.items) |id| {
                const word = id >> 6;
                if (word < self.gc_alloc_bits.len) self.gc_alloc_bits[word] &= ~(@as(u64, 1) << @intCast(id & 63));
            }
        }
    }

    /// Set alloc bits for the half-open id range `[lo, hi)`.
    fn gcSetBitRange(bits: []u64, lo: ObjectId, hi: ObjectId) void {
        var id = lo;
        while (id < hi and (id & 63) != 0) : (id += 1) bits[id >> 6] |= @as(u64, 1) << @intCast(id & 63);
        while (id + 64 <= hi) : (id += 64) bits[id >> 6] = ~@as(u64, 0);
        while (id < hi) : (id += 1) bits[id >> 6] |= @as(u64, 1) << @intCast(id & 63);
    }

    /// Clear alloc bits for the half-open id range `[lo, hi)`.
    fn gcClearBitRange(bits: []u64, lo: ObjectId, hi: ObjectId) void {
        var id = lo;
        while (id < hi) : (id += 1) {
            const word = id >> 6;
            if (word < bits.len) bits[word] &= ~(@as(u64, 1) << @intCast(id & 63));
        }
    }

    fn gcSetAllocBit(self: *ObjectHeap, id: ObjectId) void {
        // Detector-only (gc_debug), called per object fill. The bitmap is
        // pre-sized in `gcEnableCollect` so it never reallocs here; concurrent
        // fills from other workers at --workers>1 are handled with atomic-or.
        const word = id >> 6;
        if (word >= self.gc_alloc_bits.len) return;
        _ = @atomicRmw(u64, &self.gc_alloc_bits[word], .Or, @as(u64, 1) << @intCast(id & 63), .monotonic);
    }

    // ===================================================================
    // Copying nursery — minor collection (`-Dgc`)
    // ===================================================================

    /// Is object `id` young? Old ⇒ its bit is set (promoted in a prior minor);
    /// young ⇒ clear or beyond the (STW-grown) bitmap. No allocation barrier.
    pub inline fn gcIsYoung(self: *const ObjectHeap, id: ObjectId) bool {
        if (comptime !build_options.gc) return false;
        // Pre-collection (bootstrap) objects are permanent — always old. Never
        // evacuated/reclaimed, and the write barrier MUST treat them as old so
        // an old→young edge they gain (e.g. a bootstrap thunk resolving to a
        // young value) is remembered.
        if (id < self.gc_track_from) return false;
        const word = id >> 6;
        if (word >= self.gc_old_bits.len) return true;
        return self.gc_old_bits[word] & (@as(u64, 1) << @intCast(id & 63)) == 0;
    }

    pub inline fn gcSetOld(self: *ObjectHeap, id: ObjectId) void {
        const word = id >> 6;
        if (word >= self.gc_old_bits.len) return;
        // Atomic OR: parallel evacuation promotes concurrently from multiple
        // workers, whose ids may share a bitmap word. (Serially uncontended, so
        // ~free at --workers=1.)
        _ = @atomicRmw(u64, &self.gc_old_bits[word], .Or, @as(u64, 1) << @intCast(id & 63), .monotonic);
    }

    /// Grow the generation bitmap to cover `[0, count)` (new words zeroed ⇒
    /// young). STW only, so plain (non-atomic).
    pub fn gcGrowOldBits(self: *ObjectHeap, count: u32) void {
        const words = (@as(usize, count) + 63) >> 6;
        if (self.gc_old_bits.len < words) {
            const old_len = self.gc_old_bits.len;
            self.gc_old_bits = self.allocator.realloc(self.gc_old_bits, words) catch return;
            @memset(self.gc_old_bits[old_len..words], 0);
        }
    }

    /// If a Value carries a heap ObjectId, return it (inlined here to avoid a
    /// gc-module import cycle — mirrors `gc.hasObjectRef`).
    pub inline fn gcHeapId(v: Value) ?ObjectId {
        if (v.isList() or v.isAttrs() or v.isThunk() or v.isClosure() or
            v.isBuiltinClosure() or v.isContextString() or v.isBoxedInt() or
            v.isPartialApp()) return v.asObjectId();
        return null;
    }

    /// Write barrier: `source` (an old object) now references `referent`. Record
    /// the source for the next minor iff this is a genuine old→young edge; every
    /// other case bails cheaply. Fired at the write-once mutation sites (thunk
    /// resolve, merge flatten, cell bind).
    pub fn gcRecordEdge(self: *ObjectHeap, source: ObjectId, referent: Value) void {
        if (comptime !build_options.gc) return;
        if (!self.gc_collect_enabled) return;
        const ref_id = gcHeapId(referent) orelse return;
        if (!self.gcIsYoung(ref_id)) return; // referent already old
        if (self.gcIsYoung(source)) return; // source young → not old→young
        self.currentLocal().gc_remset.append(self.allocator, source) catch {};
    }

    /// GC minor-collect statistics (`-Dgc`); populated by the collector
    /// driver in `heap/gc.zig`.
    pub const MinorStats = struct { promoted: u64 = 0, freed: u64 = 0 };

    // --- parallel evacuation phase (`--workers>1`) ---------------------------
    //
    // The collector calls `gcBeginEvac` before opening the mark, then (after the
    // mark terminates and it has verified closure) `gcOpenEvac`. Every worker —
    // collector and parked peers alike — runs `gcEvacClaimLoop`, atomically
    // claiming young-object lists and evacuating them into its own TLAB. The
    // collector then `gcWaitEvacDone` + `gcFinishEvac` (reset the nursery).

    /// Grab the next marker slot for this worker (collector or peer). A slot
    /// `>= marker_count` means "don't participate — park idle". Called by both
    /// the collector and the parallel-mark helper hook. (The rest of the evac
    /// phase — beginEvac/openEvac/evacClaimLoop/waitEvacDone/finishEvac — lives
    /// in the collector driver, `heap/gc.zig`.)
    pub fn gcMarkSlotGrab(self: *ObjectHeap) u32 {
        if (comptime !build_options.gc) return 0;
        return self.gc_mark_slot.fetchAdd(1, .acq_rel);
    }

    /// Detector: after evacuation every reachable object's owned ranges must be
    /// tenured (the nursery is about to be reset). A live object still pointing
    /// at a young range would dangle. Panics with the offending id/kind so a
    /// missed-evacuation bug is caught at its source, not downstream.
    /// Sweep: free every filled object that `mark_bits` left unmarked —
    /// return its owned ranges to the free lists and its slot to the
    /// object free list. `mark_bits` is the marker's live-bitmap (same
    /// ObjectId indexing); passed in so the heap needn't import the GC
    /// tracer. Must run at a safepoint with no concurrent allocation.
    pub fn sweep(self: *ObjectHeap, mark_bits: []const u64) SweepStats {
        var st: SweepStats = .{};
        if (comptime !build_options.gc) return st;
        // Release builds don't maintain the alloc bitmap incrementally —
        // rebuild it here from the live id range minus the free lists.
        if (comptime !gc_debug) self.gcReconstructAllocBits();
        if (comptime gc_debug) heap_gc.verifyMarkClosed(self, mark_bits);
        const n = self.objects.count();
        // Round-robin distribution across per-worker free-list shards. STW, so
        // the collector alone writes every shard (no concurrency); post-sweep
        // each worker consumes its OWN shard lock-free.
        const nshards = self.worker_locals.len;
        var shard: usize = 0;
        var id: ObjectId = 0;
        while (id < n) : (id += 1) {
            const word = id >> 6;
            if (word >= self.gc_alloc_bits.len) break;
            const bit = @as(u64, 1) << @intCast(id & 63);
            if (self.gc_alloc_bits[word] & bit == 0) continue; // unfilled / already free
            const marked = word < mark_bits.len and (mark_bits[word] & bit != 0);
            if (marked) continue;
            const local = &self.worker_locals[shard];
            heap_gc.freeObjectRanges(self, local, self.objects.get(id));
            self.gc_alloc_bits[word] &= ~bit;
            local.gc_free_objects.append(self.allocator, id) catch {};
            st.objects_freed += 1;
            shard += 1;
            if (shard >= nshards) shard = 0;
        }
        return st;
    }

    pub fn get(self: *ObjectHeap, id: ObjectId) *Object {
        self.gcAssertLive(id);
        return self.objects.getMut(id);
    }

    pub fn getConst(self: *const ObjectHeap, id: ObjectId) *const Object {
        self.gcAssertLive(id);
        return self.objects.get(id);
    }

    pub fn getList(self: *const ObjectHeap, id: ObjectId) ![]const Value {
        if (comptime struct_census.enabled) struct_census.recordRead(id);
        return switch (self.getConst(id).*) {
            .list => |range| self.values.slice(range),
            else => error.InvalidObjectType,
        };
    }

    pub fn getListLen(self: *const ObjectHeap, id: ObjectId) !usize {
        return (try self.getList(id)).len;
    }

    pub fn getListItem(self: *const ObjectHeap, id: ObjectId, index: usize) !Value {
        const items = try self.getList(id);
        if (index >= items.len) return error.IndexOutOfBounds;
        return items[index];
    }

    /// Full attr entries. A `merge_attrs` (layered `//`) is flattened to a
    /// real attrs object on first call (memoized), so value-iterating
    /// callers (deep force, `==`, JSON/XML, `attrNames`) see a normal
    /// sorted entry slice. Non-const because flattening allocates.
    pub fn getAttrs(self: *ObjectHeap, id: ObjectId) ![]const AttrEntry {
        if (comptime struct_census.enabled) struct_census.recordRead(id);
        return switch (self.getConst(id).*) {
            .attrs => |a| self.attrs.slice(a.range),
            .merge_attrs => self.attrs.slice(self.getConst(try self.flattenMerge(id)).attrs.range),
            else => error.InvalidObjectType,
        };
    }

    pub fn getAttrValue(self: *const ObjectHeap, id: ObjectId, name: InternId) !Value {
        return (try self.getAttrValueOpt(id, name)) orelse error.MissingAttribute;
    }

    /// Right-biased attr lookup returning null for a missing key. Walks a
    /// `merge_attrs` chain overlay-first without flattening (read-only, so
    /// it stays const and feeds the hot inline cache). Once a node has
    /// been flattened it delegates to the flat object's binary search.
    pub fn getAttrValueOpt(self: *const ObjectHeap, id: ObjectId, name: InternId) anyerror!?Value {
        if (comptime struct_census.enabled) struct_census.recordRead(id);
        return switch (self.getConst(id).*) {
            .attrs => |a| binarySearchAttr(self.attrs.slice(a.range), name),
            .merge_attrs => |m| {
                const flat = m.flattened.load(.acquire);
                if (flat != NO_FLAT) {
                    return binarySearchAttr(self.attrs.slice(self.getConst(flat).attrs.range), name);
                }
                if (try self.getAttrValueOpt(m.overlay, name)) |v| return v;
                return self.getAttrValueOpt(m.base, name);
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getAttrPos(self: *const ObjectHeap, id: ObjectId, name: InternId) ?SourcePos {
        return switch (self.getConst(id).*) {
            .attrs => |a| if (a.positions.len == 0) null else self.findAttrPos(a.positions, name),
            // `//` is right-biased; report the overlay's position if it
            // defines the name, else the base's. Walks the chain rather
            // than flattening (flattening drops positions).
            .merge_attrs => |m| if (self.attrContains(m.overlay, name))
                self.getAttrPos(m.overlay, name)
            else
                self.getAttrPos(m.base, name),
            else => null,
        };
    }

    fn attrContains(self: *const ObjectHeap, id: ObjectId, name: InternId) bool {
        return switch (self.getConst(id).*) {
            .attrs => |a| binarySearchAttrIndex(self.attrs.slice(a.range), name) != null,
            .merge_attrs => |m| self.attrContains(m.overlay, name) or self.attrContains(m.base, name),
            else => false,
        };
    }

    /// `left // right` as a (possibly layered) attrset. Large left
    /// operands are wrapped in a `merge_attrs` node instead of copied;
    /// small ones and over-deep chains fall back to the eager flat merge.
    pub fn mergeAttrsLayered(self: *ObjectHeap, left_id: ObjectId, right_id: ObjectId) !ObjectId {
        // `{} // x = x` / `x // {} = x`: an empty operand contributes nothing
        // to the right-biased merge, so return the other id instead of
        // building a merge node or copying. An empty attrset is always a
        // plain `.attrs` of range.len 0 (merges of non-empties are never
        // empty). `{} // x` in the module fixpoint is common — see census.
        const l = self.getConst(left_id).*;
        if (l == .attrs and l.attrs.range.len == 0) return right_id;
        const r = self.getConst(right_id).*;
        if (r == .attrs and r.attrs.range.len == 0) return left_id;

        const next_depth: u16 = switch (self.getConst(left_id).*) {
            .attrs => |a| if (a.range.len < MERGE_LAYER_MIN) 0 else 1,
            .merge_attrs => |m| if (m.depth + 1 > MERGE_FLATTEN_DEPTH) 0 else m.depth + 1,
            else => 0,
        };
        if (next_depth == 0) return self.addMergedAttrs(left_id, right_id);
        return self.add(.{ .merge_attrs = .{
            .base = left_id,
            .overlay = right_id,
            .depth = next_depth,
            .flattened = .init(NO_FLAT),
        } });
    }

    /// Materialize (memoized) a `merge_attrs` chain into a flat attrs
    /// object and return its id. Collects the whole chain's leaves in
    /// precedence order and does ONE k-way right-biased merge — avoiding
    /// the O(depth·N) intermediate attrs objects a recursive pairwise
    /// flatten would allocate.
    fn flattenMerge(self: *ObjectHeap, id: ObjectId) anyerror!ObjectId {
        const cached = self.get(id).merge_attrs.flattened.load(.acquire);
        if (cached != NO_FLAT) return cached;

        var leaves: std.ArrayListUnmanaged(ObjectId) = .empty;
        defer leaves.deinit(self.allocator);
        try self.collectMergeLeaves(id, &leaves);
        const flat = try self.kwayMergeLeaves(leaves.items);

        const prev = self.get(id).merge_attrs.flattened.cmpxchgStrong(NO_FLAT, flat, .acq_rel, .acquire);
        // old→young barrier: the (possibly old) merge node now points at its
        // flattened attrs object. Only the CAS winner installed the edge.
        if (prev == null) self.gcRecordEdge(id, Value.attrs(flat));
        return prev orelse flat;
    }

    /// Append the plain-attrs leaves of a `merge_attrs` subtree to `out`
    /// in left-to-right (oldest-base → newest-overlay) precedence order.
    /// An already-flattened node contributes its cached flat leaf.
    fn collectMergeLeaves(self: *ObjectHeap, id: ObjectId, out: *std.ArrayListUnmanaged(ObjectId)) anyerror!void {
        switch (self.getConst(id).*) {
            .attrs => try out.append(self.allocator, id),
            .merge_attrs => |m| {
                const f = m.flattened.load(.acquire);
                if (f != NO_FLAT) {
                    try out.append(self.allocator, f);
                    return;
                }
                try self.collectMergeLeaves(m.base, out);
                try self.collectMergeLeaves(m.overlay, out);
            },
            else => return error.InvalidObjectType,
        }
    }

    /// One-pass k-way merge of sorted plain-attrs `leaves`, right-biased:
    /// on a name shared by several leaves the highest-indexed (newest)
    /// wins. Positions are dropped (getAttrPos walks the merge chain, not
    /// the flattened object).
    fn kwayMergeLeaves(self: *ObjectHeap, leaves: []const ObjectId) !ObjectId {
        if (leaves.len == 1) return leaves[0];
        const n = leaves.len;
        const slices = try self.allocator.alloc([]const AttrEntry, n);
        defer self.allocator.free(slices);
        const cursors = try self.allocator.alloc(usize, n);
        defer self.allocator.free(cursors);

        var cap: u32 = 0;
        for (leaves, 0..) |leaf, i| {
            slices[i] = self.attrs.slice(self.getConst(leaf).attrs.range);
            cursors[i] = 0;
            cap += @intCast(slices[i].len);
        }

        const reserved = try self.reserveAttrsLocal(cap);
        const dst = self.attrs.sliceMut(reserved);
        var out: usize = 0;
        while (true) {
            // Smallest name still available across all cursors.
            var min_name: ?InternId = null;
            for (slices, cursors) |s, c| {
                if (c < s.len) {
                    const nm = s[c].name;
                    if (min_name == null or nm < min_name.?) min_name = nm;
                }
            }
            const name = min_name orelse break;
            // Among leaves positioned at `name`, the last (newest) wins;
            // advance every cursor sitting on `name`.
            var winner: usize = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (cursors[i] < slices[i].len and slices[i][cursors[i]].name == name) {
                    winner = i;
                }
            }
            dst[out] = slices[winner][cursors[winner]];
            out += 1;
            i = 0;
            while (i < n) : (i += 1) {
                if (cursors[i] < slices[i].len and slices[i][cursors[i]].name == name) cursors[i] += 1;
            }
        }

        const range: AttrRange = .{ .segment = reserved.segment, .offset = reserved.offset, .len = @intCast(out) };
        return self.add(.{ .attrs = .{ .range = range } });
    }

    pub fn getClosure(self: *const ObjectHeap, id: ObjectId) !Closure {
        return switch (self.getConst(id).*) {
            .closure => |closure| .{
                .chunk_id = closure.chunk_id,
                .upvalues = self.values.slice(closure.upvalues),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getBuiltinClosure(self: *const ObjectHeap, id: ObjectId) !BuiltinClosure {
        return switch (self.getConst(id).*) {
            .builtin_closure => |closure| .{
                .builtin_id = closure.builtin_id,
                .args = self.values.slice(closure.args),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getPartialApp(self: *const ObjectHeap, id: ObjectId) !PartialApp {
        return switch (self.getConst(id).*) {
            .partial_app => |pa| .{
                .func = pa.func,
                .args = self.values.slice(pa.args),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getContextString(self: *const ObjectHeap, id: ObjectId) !ContextString {
        return switch (self.getConst(id).*) {
            .context_string => |string| .{
                .text = string.text,
                .context = self.attrs.slice(string.context),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getThunk(self: *ObjectHeap, id: ObjectId) !*Thunk {
        return switch (self.get(id).*) {
            .thunk => |*thunk| thunk,
            else => error.InvalidObjectType,
        };
    }

    /// Skip the tagged-union dispatch when the caller has already
    /// observed `Value.discriminant == .thunk` and can therefore prove
    /// the object slot is a thunk. The release build elides the
    /// generated tag check; debug builds keep it.
    pub fn getThunkAssumeValid(self: *ObjectHeap, id: ObjectId) *Thunk {
        return &self.get(id).thunk;
    }

    pub fn addList(self: *ObjectHeap, items: []const Value) !ObjectId {
        const range = try self.reserveValuesLocal(@intCast(items.len));
        @memcpy(self.values.sliceMut(range), items);
        return self.add(.{ .list = range });
    }

    pub fn addConcatenatedLists(self: *ObjectHeap, left_id: ObjectId, right_id: ObjectId) !ObjectId {
        const left = try self.getList(left_id);
        // `[] ++ x = x` / `x ++ [] = x`: skip allocating a fresh range and
        // copying (the empty operand contributes nothing). `x ++ []` in
        // particular avoided copying all of `x`. Lists are immutable, so
        // returning an operand's id is safe. (A large share of single-use
        // `++` intermediates have a literal `[]` operand — see struct-census.)
        if (left.len == 0) return right_id;
        const right = try self.getList(right_id);
        if (right.len == 0) return left_id;

        const range = try self.reserveValuesLocal(@intCast(left.len + right.len));
        const dst = self.values.sliceMut(range);
        @memcpy(dst[0..left.len], left);
        @memcpy(dst[left.len..], right);
        return self.add(.{ .list = range });
    }

    pub fn addAttrs(self: *ObjectHeap, entries: []const AttrEntry) !ObjectId {
        const range = try self.prepareAttrsRange(entries);
        return self.add(.{ .attrs = .{ .range = range } });
    }

    /// Same as `addAttrs` but the caller guarantees `entries` is already
    /// sorted by `name` and contains no duplicates. Skips the sort and
    /// duplicate-check that `prepareAttrsRange` runs on unsorted input.
    /// Use this from merge-walk style builders (`mergeAttrs`,
    /// `intersectAttrs`) whose output is sorted+unique by construction.
    pub fn addAttrsSorted(self: *ObjectHeap, entries: []const AttrEntry) !ObjectId {
        const range = try self.appendAttrEntries(entries);
        return self.add(.{ .attrs = .{ .range = range } });
    }

    /// Allocate + sort + dedup an AttrRange without wrapping it in an
    /// object slot. Used by reserve+fill flows where the caller wants
    /// to compute the final attrs payload before publishing the
    /// containing slot's id.
    pub fn prepareAttrsRange(self: *ObjectHeap, entries: []const AttrEntry) !AttrRange {
        const range = try self.appendAttrEntries(entries);
        self.sortAttrs(range);
        try self.rejectDuplicateAttrs(range);
        return range;
    }

    pub fn addAttrsWithPositions(
        self: *ObjectHeap,
        entries: []const AttrEntry,
        positions: []const AttrPosEntry,
    ) !ObjectId {
        if (positions.len == 0) return self.addAttrs(entries);

        const range = try self.appendAttrEntries(entries);
        errdefer self.attrs.rollback(range);
        self.sortAttrs(range);
        try self.rejectDuplicateAttrs(range);

        const pos_range = try self.appendAttrPositions(positions);
        errdefer self.attr_positions.rollback(pos_range);
        self.sortAttrPositions(pos_range);
        return self.add(.{ .attrs = .{ .range = range, .positions = pos_range } });
    }

    pub fn addContextString(self: *ObjectHeap, text: InternId, context: []const AttrEntry) !ObjectId {
        const range = try self.appendAttrEntriesTenured(context);
        errdefer self.attrs.rollback(range);
        self.sortAttrs(range);
        try self.rejectDuplicateAttrs(range);
        return self.add(.{ .context_string = .{ .text = text, .context = range } });
    }

    pub fn addMergedAttrs(self: *ObjectHeap, left_id: ObjectId, right_id: ObjectId) !ObjectId {
        const left = try self.getAttrs(left_id);
        const right = try self.getAttrs(right_id);

        // Reserve worst-case (no overlap) directly in the heap's attr
        // storage and write the merge in place. Skips a per-merge
        // ArrayList allocation + one of the two memcpys the old path
        // did (input → ArrayList → heap). Inputs are both sorted+
        // deduped (invariant of `addAttrs`/`prepareAttrsRange`), so
        // the in-order walk produces sorted+unique output by
        // construction.
        //
        // Slight wastage: if entries overlap, we leave the trailing
        // unused slots reserved (the segment cursor doesn't roll
        // back). On NixOS module merge the overlap rate is high but
        // the absolute waste is small compared to the steady-state
        // attr storage footprint.
        const cap: u32 = @intCast(left.len + right.len);
        const reserved = try self.reserveAttrsLocal(cap);
        const dst = self.attrs.sliceMut(reserved);

        var out: usize = 0;
        var left_i: usize = 0;
        var right_i: usize = 0;
        while (left_i < left.len and right_i < right.len) {
            const l = left[left_i];
            const r = right[right_i];
            if (l.name < r.name) {
                dst[out] = l;
                out += 1;
                left_i += 1;
            } else if (l.name > r.name) {
                dst[out] = r;
                out += 1;
                right_i += 1;
            } else {
                dst[out] = r;
                out += 1;
                left_i += 1;
                right_i += 1;
            }
        }
        if (left_i < left.len) {
            const n = left.len - left_i;
            @memcpy(dst[out..][0..n], left[left_i..]);
            out += n;
        }
        if (right_i < right.len) {
            const n = right.len - right_i;
            @memcpy(dst[out..][0..n], right[right_i..]);
            out += n;
        }

        const positions = try self.mergeAttrPositions(left_id, right_id, right);
        errdefer if (positions.len != 0) self.attr_positions.rollback(positions);

        const range: AttrRange = .{
            .segment = reserved.segment,
            .offset = reserved.offset,
            .len = @intCast(out),
        };
        return self.add(.{ .attrs = .{ .range = range, .positions = positions } });
    }

    pub fn addAttrsFromStackPairs(self: *ObjectHeap, pairs: []const Value) !ObjectId {
        return self.addAttrsFromStackPairsWithPositions(pairs, &.{});
    }

    pub fn addAttrsFromStackPairsWithPositions(
        self: *ObjectHeap,
        pairs: []const Value,
        positions: []const AttrPosEntry,
    ) !ObjectId {
        std.debug.assert(pairs.len % 2 == 0);

        var count: u32 = 0;
        var pair_i: usize = 0;
        while (pair_i < pairs.len) : (pair_i += 2) {
            switch (pairs[pair_i].kind()) {
                .null => {},
                .string => count += 1,
                else => return error.TypeError,
            }
        }

        const range = try self.reserveAttrsLocal(count);
        const entries = self.attrs.sliceMut(range);

        var i: usize = 0;
        var entry_i: usize = 0;
        while (i < pairs.len) : (i += 2) {
            if (pairs[i].isNull()) continue;
            entries[entry_i] = .{
                .name = pairs[i].asInternId(),
                .value = pairs[i + 1],
            };
            entry_i += 1;
        }

        self.sortAttrs(range);
        try self.rejectDuplicateAttrs(range);

        if (positions.len == 0) return self.add(.{ .attrs = .{ .range = range } });

        // Positions arrive pre-sorted by name: the only producer is the
        // compiler's `emitBuildAttrs`, which bakes them sorted. No
        // runtime sort needed (findAttrPos binary-searches by name).
        std.debug.assert(positionsSortedByName(positions));
        const pos_range = try self.appendAttrPositions(positions);
        errdefer self.attr_positions.rollback(pos_range);
        return self.add(.{ .attrs = .{ .range = range, .positions = pos_range } });
    }

    fn positionsSortedByName(positions: []const AttrPosEntry) bool {
        if (positions.len < 2) return true;
        for (positions[1..], positions[0 .. positions.len - 1]) |cur, prev| {
            if (cur.name < prev.name) return false;
        }
        return true;
    }

    pub fn addClosure(self: *ObjectHeap, chunk_id: ChunkId, upvalues: []const Value) !ObjectId {
        // Upvalues are cached in the executing frame's `upvalues` slice (see
        // vm/stack.zig Frame), which would dangle if the range were evacuated
        // mid-execution. Born tenured so the frame slice never moves. (A future
        // optimization can re-derive frame.upvalues at GC time and let these be
        // young — see docs/plans/gc-copying-nursery-plan.md.)
        const range = try self.appendValuesTenured(upvalues);
        errdefer self.values.rollback(range);
        return self.add(.{ .closure = .{
            .chunk_id = chunk_id,
            .upvalues = range,
        } });
    }

    pub fn addBuiltinClosure(self: *ObjectHeap, builtin_id: u16, args: []const Value) !ObjectId {
        const range = try self.appendValues(args);
        errdefer self.values.rollback(range);
        return self.add(.{ .builtin_closure = .{
            .builtin_id = builtin_id,
            .args = range,
        } });
    }

    pub fn addThunk(self: *ObjectHeap, thunk: Thunk) !ObjectId {
        return self.add(.{ .thunk = thunk });
    }

    /// Build a partial-application object from `func` (an arity>1 closure
    /// or another PAP's underlying closure) and the args supplied so far.
    pub fn addPartialApp(self: *ObjectHeap, func: Value, args: []const Value) !ObjectId {
        const range = try self.appendValues(args);
        errdefer self.values.rollback(range);
        return self.add(.{ .partial_app = .{
            .func = func,
            .args = range,
        } });
    }

    pub fn addBoxedInt(self: *ObjectHeap, v: i64) !ObjectId {
        return self.add(.{ .boxed_int = v });
    }

    pub fn getBoxedInt(self: *const ObjectHeap, id: ObjectId) !i64 {
        return switch (self.getConst(id).*) {
            .boxed_int => |v| v,
            else => error.InvalidObjectType,
        };
    }

    pub fn addBytecodeThunk(self: *ObjectHeap, chunk_id: ChunkId, upvalues: []const Value) !ObjectId {
        // Inline-storage thunks (<= INLINE_CAP upvalues) need no
        // `values`-store allocation — `initBytecode` copies them into the
        // thunk. Only wider captures spill to a stable slice.
        if (upvalues.len <= BytecodeThunk.INLINE_CAP) {
            return self.add(.{ .thunk = Thunk.initBytecode(chunk_id, upvalues) });
        }
        // Spilled upvalues are a bare slice held by the thunk AND cached in the
        // executing frame's `upvalues` — both would dangle if the range were
        // evacuated. Born tenured (never moves), so neither ever moves.
        const range = try self.appendValuesTenured(upvalues);
        errdefer self.values.rollback(range);
        return self.add(.{ .thunk = Thunk.initBytecode(chunk_id, self.values.slice(range)) });
    }

    /// A deferred-compile thunk (lazy per-attr compilation). Same inline
    /// (<= INLINE_CAP) vs. spilled-slice storage split as `addBytecodeThunk`.
    pub fn addDeferredThunk(self: *ObjectHeap, deferred_id: u32, env: []const Value) !ObjectId {
        if (env.len <= DeferredThunk.INLINE_CAP) {
            return self.add(.{ .thunk = Thunk.initDeferred(deferred_id, env) });
        }
        const range = try self.appendValuesTenured(env); // stable: see addBytecodeThunk
        errdefer self.values.rollback(range);
        return self.add(.{ .thunk = Thunk.initDeferred(deferred_id, self.values.slice(range)) });
    }

    /// Wrap `value` in a pre-resolved, undemanded thunk. Used by the
    /// compiler to make eagerly-built attrsets/lists/lambdas appear
    /// lazy to renderers (XML) while skipping the chunk-registration
    /// + bytecode-dispatch roundtrip of a real lazy thunk.
    pub fn addLazyShell(self: *ObjectHeap, value: Value) !ObjectId {
        return self.add(.{ .thunk = Thunk.initLazyShell(value) });
    }

    pub fn beginBytecodeThunk(self: *ObjectHeap, chunk_id: ChunkId, upvalue_count: usize) !PendingBytecodeThunk {
        const range = try self.reserveValuesLocal(@intCast(upvalue_count));
        return .{
            .chunk_id = chunk_id,
            .range = range,
        };
    }

    pub fn pendingBytecodeThunkUpvalues(self: *ObjectHeap, pending: PendingBytecodeThunk) []Value {
        return self.values.sliceMut(pending.range);
    }

    pub fn commitBytecodeThunk(self: *ObjectHeap, pending: PendingBytecodeThunk) !ObjectId {
        errdefer self.values.rollback(pending.range);
        // Spilled (>INLINE_CAP) upvalues become the thunk's stable backing slice
        // and are cached in executing frames; if the pending range is young it
        // must be copied to the tenured region so it never moves. Inline (<=2)
        // upvalues are copied into the thunk, so the young pending range is
        // harmless (reclaimed by the next nursery reset).
        if (comptime build_options.gc) {
            if (pending.range.len > BytecodeThunk.INLINE_CAP and self.values.isYoung(pending.range)) {
                const t = try self.values.reserve(self.allocator, pending.range.len);
                @memcpy(self.values.sliceMut(t), self.values.slice(pending.range));
                return self.add(.{ .thunk = Thunk.initBytecode(pending.chunk_id, self.values.slice(t)) });
            }
        }
        return self.add(.{ .thunk = Thunk.initBytecode(pending.chunk_id, self.values.slice(pending.range)) });
    }

    pub fn rollbackBytecodeThunk(self: *ObjectHeap, pending: PendingBytecodeThunk) void {
        self.values.rollback(pending.range);
    }

    fn appendValues(self: *ObjectHeap, items: []const Value) !ValueRange {
        const range = try self.reserveValuesLocal(@intCast(items.len));
        @memcpy(self.values.sliceMut(range), items);
        return range;
    }

    /// Like `appendValues` but always tenured (bypasses the nursery). For
    /// storage that must never be evacuated because a bare slice into it is
    /// held outside the object graph — spilled thunk upvalues (see
    /// `addBytecodeThunk`).
    fn appendValuesTenured(self: *ObjectHeap, items: []const Value) !ValueRange {
        // Without an active copying nursery, TLAB ranges are just as stable
        // as direct tenured reservations (StableSegments never relocates) —
        // use the per-worker TLAB and skip the store's global `write_mu`.
        // This is the thunk/closure spilled-upvalue path (every capture
        // wider than INLINE_CAP), so at high worker counts the direct
        // `values.reserve` was a spinlock convoy dominating the profile.
        // Mirrors `appendAttrEntriesTenured`'s guard.
        if (comptime !build_options.gc) return self.appendValues(items);
        if (!self.gc_collect_enabled) return self.appendValues(items);
        const range = try self.values.reserve(self.allocator, @intCast(items.len));
        @memcpy(self.values.sliceMut(range), items);
        return range;
    }

    fn appendAttrEntries(self: *ObjectHeap, entries: []const AttrEntry) !AttrRange {
        const range = try self.reserveAttrsLocal(@intCast(entries.len));
        @memcpy(self.attrs.sliceMut(range), entries);
        return range;
    }

    /// Tenured attr append — for a context-string's `context`, whose raw slice
    /// (`contextEntriesForValue`) is held across forces in string builtins and
    /// would dangle if evacuated. See `addContextString`.
    fn appendAttrEntriesTenured(self: *ObjectHeap, entries: []const AttrEntry) !AttrRange {
        if (comptime !build_options.gc) return self.appendAttrEntries(entries);
        if (!self.gc_collect_enabled) return self.appendAttrEntries(entries);
        const range = try self.attrs.reserve(self.allocator, @intCast(entries.len));
        @memcpy(self.attrs.sliceMut(range), entries);
        return range;
    }

    fn appendAttrPositions(self: *ObjectHeap, positions: []const AttrPosEntry) !AttrPosRange {
        const range = try self.reserveAttrPositionsLocal(@intCast(positions.len));
        @memcpy(self.attr_positions.sliceMut(range), positions);
        return range;
    }

    fn sortAttrs(self: *ObjectHeap, range: AttrRange) void {
        std.mem.sort(AttrEntry, self.attrs.sliceMut(range), {}, attrEntryLessThan);
    }

    fn sortAttrPositions(self: *ObjectHeap, range: AttrPosRange) void {
        std.mem.sort(AttrPosEntry, self.attr_positions.sliceMut(range), {}, attrPosEntryLessThan);
    }

    fn rejectDuplicateAttrs(self: *const ObjectHeap, range: AttrRange) !void {
        const entries = self.attrs.slice(range);
        if (entries.len < 2) return;

        for (entries[1..], 1..) |entry, i| {
            if (entry.name == entries[i - 1].name) {
                return error.DuplicateAttribute;
            }
        }
    }

    fn findAttrPos(self: *const ObjectHeap, range: AttrPosRange, name: InternId) ?SourcePos {
        const entries = self.attr_positions.slice(range);
        var lo: usize = 0;
        var hi: usize = entries.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = entries[mid];
            if (entry.name == name) return entry.pos;
            if (entry.name < name) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return null;
    }

    /// Merge the source positions of two attrsets being `//`-combined.
    /// Returns an `AttrPosRange` (empty — `len == 0` — when neither side
    /// carries positions, which is the common case for builtin-built
    /// attrsets).
    fn mergeAttrPositions(
        self: *ObjectHeap,
        left_id: ObjectId,
        right_id: ObjectId,
        right_attrs: []const AttrEntry,
    ) !AttrPosRange {
        const left_positions = self.attrPositionsSlice(left_id);
        const right_positions = self.attrPositionsSlice(right_id);
        if (left_positions.len == 0 and right_positions.len == 0) return EMPTY_ATTR_POS;

        var merged = try std.ArrayListUnmanaged(AttrPosEntry).initCapacity(
            self.allocator,
            left_positions.len + right_positions.len,
        );
        defer merged.deinit(self.allocator);

        for (left_positions) |position| {
            if (!attrEntriesContainName(right_attrs, position.name)) {
                merged.appendAssumeCapacity(position);
            }
        }
        for (right_positions) |position| {
            if (attrEntriesContainName(right_attrs, position.name)) {
                merged.appendAssumeCapacity(position);
            }
        }

        if (merged.items.len == 0) return EMPTY_ATTR_POS;
        const range = try self.appendAttrPositions(merged.items);
        self.sortAttrPositions(range);
        return range;
    }

    /// Borrow an attrset's source-position entries (empty slice when it
    /// has none or `id` is not an attrset).
    fn attrPositionsSlice(self: *const ObjectHeap, id: ObjectId) []const AttrPosEntry {
        return switch (self.getConst(id).*) {
            .attrs => |a| if (a.positions.len == 0) &.{} else self.attr_positions.slice(a.positions),
            else => &.{},
        };
    }
};

fn bucketInt(buckets: *[5]u32, value: Value) void {
    // Boxed ints are by definition outside i48 inline range; count them
    // in bucket 4 without a heap lookup. Inline ints get magnitude-binned.
    if (value.isBoxedInt()) {
        buckets[4] += 1;
        return;
    }
    if (!value.isInt()) return;
    const x = value.asInt();
    if (x == 0) {
        buckets[0] += 1;
        return;
    }
    const mag: u64 = @abs(x);
    const idx: usize = if (mag < (@as(u64, 1) << 15))
        1
    else if (mag < (@as(u64, 1) << 31))
        2
    else if (mag < (@as(u64, 1) << 47))
        3
    else
        4;
    buckets[idx] += 1;
}

fn binarySearchAttr(entries: []const AttrEntry, name: InternId) ?Value {
    const idx = binarySearchAttrIndex(entries, name) orelse return null;
    return entries[idx].value;
}

/// Detector sentinel: `poisonYoung` stamps freed young attr entries with this
/// name. Any name scan that observes it is reading a dangling attr slice held
/// across a collection — the panic's stack trace names the buggy caller.
const GC_POISON_NAME: InternId = std.math.maxInt(InternId) - 7;

inline fn gcAssertNotPoisonName(name: InternId) void {
    if (comptime !gc_debug) return;
    if (name == GC_POISON_NAME) @panic("gc: read poisoned attr name — dangling attr slice held across a collection");
}

fn binarySearchAttrIndex(entries: []const AttrEntry, name: InternId) ?usize {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry_name = entries[mid].name;
        gcAssertNotPoisonName(entry_name);
        if (entry_name == name) return mid;
        if (entry_name < name) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

fn attrEntryLessThan(_: void, lhs: AttrEntry, rhs: AttrEntry) bool {
    return lhs.name < rhs.name;
}

fn attrPosEntryLessThan(_: void, lhs: AttrPosEntry, rhs: AttrPosEntry) bool {
    return lhs.name < rhs.name;
}

fn attrEntriesContainName(entries: []const AttrEntry, name: InternId) bool {
    var lo: usize = 0;
    var hi: usize = entries.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = entries[mid];
        if (entry.name == name) return true;
        if (entry.name < name) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    return false;
}

test {
    _ = @import("heap/tests.zig");
}
