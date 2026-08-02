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
const types = @import("types.zig");

/// Deterministic use-after-free detector (ReleaseSafe only): when
/// on, freed object slots are NOT reused and every object read asserts the
/// slot's alloc-bit is set — so a collection that frees a still-live object
/// traps at the first stale read with a stack trace, instead of a
/// nondeterministic segfault much later. Off in ReleaseFast (production).
pub const gc_debug = builtin.mode == .ReleaseSafe;
const segments = @import("base").segments;
const hugetlb = @import("base").hugetlb;
const sync = @import("base").sync;
const worker_id_mod = @import("base").worker_id;
const Value = @import("value.zig").Value;
pub const ValueType = @import("value.zig").ValueType;
const Thunk = @import("thunk.zig").Thunk;
const BytecodeThunk = @import("thunk.zig").BytecodeThunk;
const DeferredThunk = @import("thunk.zig").DeferredThunk;
const FailureStore = @import("failure.zig").FailureStore;
const inspection = @import("heap/inspection.zig");
const reuse = @import("heap/reuse.zig");
const RangeFreeList = reuse.RangeFreeList;
const nextSetBit = reuse.nextSetBit;
const nextClearBit = reuse.nextClearBit;
pub const ValueRef = inspection.ValueRef;
pub const HeapReference = inspection.HeapReference;
pub const ThunkState = inspection.ThunkState;
pub const ThunkTargetInfo = inspection.ThunkTargetInfo;
pub const ThunkInfo = inspection.ThunkInfo;
pub const ObjectInfo = inspection.ObjectInfo;
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

/// Per-heap collector diagnostics. Atomics keep worker and coordinator updates
/// data-race-free.
pub const GcReportState = struct {
    collections: std.atomic.Value(u64) = .init(0),
    minor_collections: std.atomic.Value(u64) = .init(0),
    major_collections: std.atomic.Value(u64) = .init(0),
    objects_freed_total: std.atomic.Value(u64) = .init(0),
    last_live_bytes: std.atomic.Value(u64) = .init(0),
    /// Per-field maxima from full-heap marks: objects, values, attrs,
    /// attr-positions, and aggregate bytes.
    peak_major_live: [5]std.atomic.Value(u64) = @splat(.init(0)),
    peak_total_bytes: std.atomic.Value(u64) = .init(0),
    final_total_bytes: std.atomic.Value(u64) = .init(0),
    mark_ns_total: std.atomic.Value(u64) = .init(0),
    sweep_ns_total: std.atomic.Value(u64) = .init(0),
    barrier_ns_total: std.atomic.Value(u64) = .init(0),
    reset_ns_total: std.atomic.Value(u64) = .init(0),
    roots_ns_total: std.atomic.Value(u64) = .init(0),
    remset_ns_total: std.atomic.Value(u64) = .init(0),
    drain_ns_total: std.atomic.Value(u64) = .init(0),
    remset_sources_total: std.atomic.Value(u64) = .init(0),
    breakdown: [8]std.atomic.Value(u64) = @splat(.init(0)),
};

/// The object store is backed by a single mmap-reserved contiguous
/// region rather than geometric segments: it is referenced *only* by
/// flat ObjectId (never via an externally-handed-out `Range`/`slice`,
/// unlike the value/attr stores), so `get(id)` collapses to one load —
/// `base[id]` — with no segment decode (`clz` + shifts) and no per-access
/// atomic segment-pointer load. `object_max_slots` is a sparse virtual
/// reservation (`MAP_NORESERVE`), so unused slots consume no physical memory.
pub const object_max_slots: u32 = 1 << 30;
const mem_tag = @import("mem_tag.zig");
const ObjectStore = segments.FlatStore(Object, .{ .max_slots = object_max_slots, .vma_tag = .objects }, mem_tag.vma);
// Large tail segments use sparse mappings with a chunk-grown hugetlb prefix.
// Their cursors advance only under `write_mu`, as the overlay requires.
const ValueStore = segments.StableSegments(Value, .{ .first_segment_size = value_chunk_size, .vma_tag = .values, .huge_overlay_min = 64 << 20 }, mem_tag.vma);
const AttrStore = segments.StableSegments(AttrEntry, .{ .first_segment_size = attr_chunk_size, .vma_tag = .attrs, .huge_overlay_min = 64 << 20 }, mem_tag.vma);
const AttrPosStore = segments.StableSegments(AttrPosEntry, .{ .first_segment_size = attr_position_chunk_size, .vma_tag = .attrpos, .huge_overlay_min = 64 << 20 }, mem_tag.vma);

pub var next_heap_token: std.atomic.Value(u64) = .init(1);

pub const ValueRange = ValueStore.Range;
pub const AttrRange = AttrStore.Range;
pub const AttrPosRange = AttrPosStore.Range;

/// A zero-length attr-position range: the attrset carries no source
/// positions. Sliced only after a `len == 0` guard, so the (possibly
/// segment-less) store is never indexed.
pub const empty_attr_positions: AttrPosRange = .{ .segment = 0, .offset = 0, .len = 0 };

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

/// Sorted attr entries plus optional source positions for diagnostics.
/// `positions.len == 0` means no positions and is never sliced.
///
/// Immutable after publication: readers copy the containing union by value
/// on every lookup, so no mutable byte may live here. The sibling-sweep
/// dedup mark that once did sits in `ObjectHeap.sweep_filter` instead.
pub const AttrsObject = struct {
    range: AttrRange,
    positions: AttrPosRange = empty_attr_positions,
};

/// A lazy, layered `//` (update) result: `base // overlay`, both attrset
/// objects (either may itself be a `attrs_merge`, forming a chain). The
/// Module and overlay fixpoints build large attrsets through repeated `//`.
/// Layering records a large update in O(1). `//` is shallow and
/// right-biased, so lookup checks `overlay` then `base`; the (obj,name)
/// inline cache absorbs repeated lookups. The chain is flattened (one
/// real merge) once `depth` exceeds `merge_flatten_depth`, bounding both
/// lookup depth and the chain length any single flatten must walk.
/// `flattened` memoizes the flattened plain-attrs object (no_flattened_attrs until
/// first `materializeAttrs`/iteration forces it).
pub const MergeAttrsObject = struct {
    base: ObjectId,
    overlay: ObjectId,
    depth: u16,
    flattened: std.atomic.Value(ObjectId),
};

/// Sentinel for `MergeAttrsObject.flattened` meaning "not yet flattened".
pub const no_flattened_attrs: ObjectId = std.math.maxInt(ObjectId);

/// Only layer `a // b` when `a` is at least this large — small merges
/// (literal `{..} // {..}`) stay eager so the common cheap case keeps its
/// flat single-binary-search lookup and pays no indirection.
const merge_layer_min_size: u32 = 32;

/// Flatten a layer chain once it gets this deep, so `getAttrValue` walks
/// at most this many overlays and each flatten merges a bounded chain.
const merge_flatten_depth: u16 = 8;

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
/// All four stores TLAB their allocation: a worker reserves a chunk under the
/// store mutex, then hands out slots lock-free. The `objects` store also
/// supports reserving a slot up front (`reserveObjectSlot`/`fillObjectSlot`) so
/// a value can learn its own ObjectId before the object exists — how
/// `buildAttrSet` builds the `builtins.builtins` self-reference.
const object_chunk_size: u32 = 8192;
const value_chunk_size: u32 = 8192;
const attr_chunk_size: u32 = 8192;
const attr_position_chunk_size: u32 = 4096;

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
    /// Monotonic count of thunks this worker has created. One plain add
    /// on a cache line the allocation already touches; used by the
    /// sibling-sweep diagnostics (`FIX_SIBLING_LOG`) to attribute
    /// evaluation cascades to individual speculative member forces.
    thunks_created: u64 = 0,
    /// Creation-context flag: true while the fiber currently running on
    /// this worker thread is doing SPECULATIVE work (any
    /// `forceValueSpeculative`, including nested import VMs it spawns),
    /// false on the demand chain. Maintained by `Worker.runFiber` (from
    /// the resumed fiber's `vm.speculation.active`) and toggled by
    /// `forceValueSpeculative` itself. Single-writer (the owning thread);
    /// read at thunk creation to tag demand-created thunks for the
    /// `-Dprof-main` creation-context probe.
    spec_ctx: bool = false,
    // Per-worker reclamation caches. Minor sweep returns each allocation
    // worker's dead storage to that same worker, then the STW coordinator
    // publishes unused entries to shared overflow. Only the owning mutator
    // reads/writes these lists outside a collection, so allocation and
    // thunk-spill release need no local lock or peer probes.
    gc_free_objects: std.ArrayListUnmanaged(ObjectId) = .empty,
    gc_free_values: RangeFreeList = .{},
    gc_free_attrs: RangeFreeList = .{},
    gc_free_attr_pos: RangeFreeList = .{},
    /// Old objects that gained a young reference since the last minor. The
    /// worker-owned write barrier appends without locking; the next stop-the-
    /// world mark drains and clears the list.
    gc_remset: std.ArrayListUnmanaged(ObjectId) = .empty,
    /// This worker's young objects since the last minor (every id from
    /// `reserveObjectSlot`, including reused slots). The STW minor iterates
    /// exactly these — O(young) — and clears the list. Reuse- and TLAB-tail-
    /// safe, unlike an id-range frontier.
    gc_young_slots: std.ArrayListUnmanaged(ObjectId) = .empty,
    /// Range-reuse diagnostics. Single-writer (this worker's allocation
    /// path), read only after evaluation has quiesced for `--mem-report`.
    range_reuse_exact: [3]u64 = @splat(0),
    range_reuse_split: [3]u64 = @splat(0),
    range_reuse_miss: [3]u64 = @splat(0),
    range_reuse_miss_slots: [3]u64 = @splat(0),
    range_fresh_refills: [3]u64 = @splat(0),
    range_fresh_slots: [3]u64 = @splat(0),
    object_reuse_hits: u64 = 0,
    object_reuse_misses: u64 = 0,
    object_fresh_refills: u64 = 0,

    fn deinit(self: *HeapLocal, allocator: std.mem.Allocator) void {
        self.gc_free_objects.deinit(allocator);
        self.gc_free_values.deinit(allocator);
        self.gc_free_attrs.deinit(allocator);
        self.gc_free_attr_pos.deinit(allocator);
        self.gc_remset.deinit(allocator);
        self.gc_young_slots.deinit(allocator);
    }
};

/// GC collect hook. The heap can't reach the
/// evaluator's roots, so the evaluator registers a mark+sweep callback the
/// heap fires from `gcRunCollect` at a safepoint. Type-erased to keep the
/// heap free of an `eval`/`gc` import cycle. `collector_id` is the worker
/// that won the collection (its marker slot in the parallel mark).
pub const GcHook = struct {
    ctx: *anyopaque,
    sample: *const fn (*anyopaque, collector_id: u8) void,
};

pub const HeapCollectionState = struct {
    hook: ?GcHook = null,
    collect_requested: bool = false,
    threshold_bytes: u64 = std.math.maxInt(u64),
    step_bytes: u64 = 0,
    budget_bytes: u64 = 0,
    disable_reuse: bool = false,
    report: GcReportState = .{},
    promoted_since_major: u64 = 0,
    major_gate: u64,
    collect_enabled: bool = false,
    track_from: ObjectId = 0,
    bootstrap_end: ObjectId = 0,
    root_always: bool = false,
    root_active: bool = false,
    alloc_bits: []u64 = &.{},
    old_bits: []u64 = &.{},
    minor_sweep_open: std.atomic.Value(bool) = .init(false),
    minor_sweep_next: std.atomic.Value(u32) = .init(0),
    minor_sweep_done: std.atomic.Value(u32) = .init(0),
    minor_sweep_count: u32 = 0,
    mark_slot: std.atomic.Value(u32) = .init(0),
    /// Set before opening a parallel full mark so helpers skip the minor-only
    /// young-list sweep after they drain their marker slot. The mark-open
    /// release/acquire handshake publishes this non-atomic phase bit.
    collecting_major: bool = false,
    minor_sweep_promoted: std.atomic.Value(u64) = .init(0),
    minor_sweep_freed: std.atomic.Value(u64) = .init(0),
    /// Armed after a collection leaves a worthwhile object-id reserve. The
    /// first allocation that exhausts that reserve requests another collection
    /// instead of silently bumping until unrelated range-store growth reaches
    /// the global byte threshold.
    object_miss_collect_armed: std.atomic.Value(bool) = .init(false),
    object_miss_collect_requests: std.atomic.Value(u64) = .init(0),
};

pub const ObjectHeap = struct {
    allocator: std.mem.Allocator,
    /// Unique owner for immutable failures borrowed by thunks, imports, and
    /// fiber exception carriers. Lives exactly as long as this heap.
    failures: FailureStore,
    objects: ObjectStore,
    values: ValueStore,
    attrs: AttrStore,
    attr_positions: AttrPosStore,
    /// One entry per worker (including the main thread). Indexed by
    /// `worker_id_mod.currentId()`.
    worker_locals: []HeapLocal,
    /// Demand-sibling sweep dedup (`FIX_SIBLING`): one atomic bit per hashed
    /// ObjectId. This lives OUTSIDE the object store because attrs objects
    /// are copied by value on every lookup — a mutable byte inside the union
    /// is a data race with those plain reads (caught by TSan on real
    /// workloads). The filter is approximate by design: a hash collision or
    /// a GC-recycled id can skip one prefetch or admit one duplicate sweep,
    /// both benign (sweep tasks are idempotent via the per-thunk claim CAS).
    sweep_filter: []std.atomic.Value(u64),
    /// Cross-worker overflow for reclaimed object ids. Mutators refill their
    /// lock-free local stack in large batches, so imbalance costs one lock per
    /// thousands of allocations rather than one lock (plus peer probes) per
    /// allocation. Collection publishes local leftovers here at STW.
    gc_shared_free_objects: std.ArrayListUnmanaged(ObjectId),
    gc_shared_free_mu: sync.SpinMutex,
    gc_shared_free_count: std.atomic.Value(usize),
    /// Central overflow for range classes. Worker-local lists are mutator
    /// caches; collection publishes their leftovers here, and mutators refill
    /// a compatible class in batches. The per-store maximum is a stable
    /// lock-avoidance hint between collections/refills.
    gc_shared_free_values: RangeFreeList,
    gc_shared_free_attrs: RangeFreeList,
    gc_shared_free_attr_pos: RangeFreeList,
    gc_shared_free_range_mu: sync.SpinMutex,
    gc_shared_free_range_max: [3]std.atomic.Value(u32),
    /// Unique-per-init id for cache invalidation. Same trick as the
    /// intern table: thread-local caches outlive an Engine, and the
    /// allocator can reuse heap addresses, so a stale slot would match
    /// pointer equality even though it refers to a freed heap.
    token: u64,
    /// Collection policy, barriers, bitmaps, and parallel minor-sweep state.
    collection: HeapCollectionState,
    /// Shared immutable singletons for `[]` and `{}`: every empty list/attrs
    /// literal (and every builtin that produces one) returns these ids instead
    /// of allocating a fresh slot. Both are created once by
    /// `ensureEmptySingletons` at bootstrap — before GC arming, so they land
    /// below `collection.bootstrap_end` and the collector pins them for the
    /// heap's lifetime (never marked-out, never swept). Lists and attrsets are
    /// immutable, so sharing is safe: value equality is unaffected (and the
    /// `asObjectId() == asObjectId()` fast path now fires for `[] == []` /
    /// `{} == {}`), and the value printer already renders empty containers in
    /// full *before* its «repeated» identity check (see `print.writeList`).
    /// Null until bootstrapped: direct-heap unit tests that skip the bootstrap
    /// keep the old fresh-allocation behavior.
    empty_list_id: ?ObjectId = null,
    empty_attrs_id: ?ObjectId = null,
    /// Object-slot `[start, end)` ranges reserved into a worker TLAB but
    /// discarded (never filled) when `armTracking` reset the TLABs at GC
    /// arming. They sit below the tracking floor — pinned, never reused — so
    /// the heap census (`stats`, `objectSnapshot`, `usage`) must exclude them;
    /// otherwise their zeroed memory reads as live empty `[ ]` (the object
    /// union's tag-0 variant). See `discardObjectTLABs`.
    discarded_object_tails: std.ArrayListUnmanaged([2]ObjectId) = .empty,

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !ObjectHeap {
        return initWithMemoryPolicy(allocator, worker_count, null);
    }

    pub fn initWithMemoryPolicy(
        allocator: std.mem.Allocator,
        worker_count: u8,
        huge_policy: ?*hugetlb.Policy,
    ) !ObjectHeap {
        var objects = try ObjectStore.initWithPolicy(huge_policy);
        errdefer objects.deinit(allocator);
        var values: ValueStore = .empty;
        values.setHugePolicy(huge_policy);
        var attrs: AttrStore = .empty;
        attrs.setHugePolicy(huge_policy);
        var attr_positions: AttrPosStore = .empty;
        attr_positions.setHugePolicy(huge_policy);
        const locals = try allocator.alloc(HeapLocal, @max(worker_count, 1));
        errdefer allocator.free(locals);
        for (locals) |*l| l.* = .{};
        const sweep_filter = try allocator.alloc(std.atomic.Value(u64), sweep_filter_words);
        for (sweep_filter) |*word| word.* = .init(0);
        return .{
            .allocator = allocator,
            .failures = FailureStore.init(allocator),
            .objects = objects,
            .values = values,
            .attrs = attrs,
            .attr_positions = attr_positions,
            .worker_locals = locals,
            .sweep_filter = sweep_filter,
            .gc_shared_free_objects = .empty,
            .gc_shared_free_mu = .{},
            .gc_shared_free_count = .init(0),
            .gc_shared_free_values = .{},
            .gc_shared_free_attrs = .{},
            .gc_shared_free_attr_pos = .{},
            .gc_shared_free_range_mu = .{},
            .gc_shared_free_range_max = .{ .init(0), .init(0), .init(0) },
            .token = next_heap_token.fetchAdd(1, .monotonic),
            .collection = .{ .major_gate = gc_major_gate_floor },
        };
    }

    pub fn deinit(self: *ObjectHeap) void {
        self.failures.deinit();
        self.discarded_object_tails.deinit(self.allocator);
        self.allocator.free(self.collection.alloc_bits);
        self.allocator.free(self.collection.old_bits);
        for (self.worker_locals) |*l| l.deinit(self.allocator);
        self.allocator.free(self.worker_locals);
        self.allocator.free(self.sweep_filter);
        self.gc_shared_free_objects.deinit(self.allocator);
        self.gc_shared_free_values.deinit(self.allocator);
        self.gc_shared_free_attrs.deinit(self.allocator);
        self.gc_shared_free_attr_pos.deinit(self.allocator);
        self.attr_positions.deinit(self.allocator);
        self.attrs.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    pub const Counts = struct {
        objects: u32,
        values: u32,
        attrs: u32,
        attr_positions: u32,
    };

    /// Append the discarded-TLAB tails to an object-store `SkipSet` (from
    /// `collectUnfilled(.object)`) so slot scans skip their zeroed payload.
    /// Both lists are bounded by worker count, so the fixed `SkipSet` capacity
    /// is never a constraint in practice; excess is dropped defensively.
    fn addDiscardedObjectTails(self: *const ObjectHeap, set: *SkipSet) void {
        for (self.discarded_object_tails.items) |r| {
            if (set.len >= set.starts.len) break;
            set.starts[set.len] = r[0];
            set.ends[set.len] = r[1];
            set.len += 1;
        }
    }

    /// Discard every worker's partially-used object TLAB at GC arming: the
    /// reserved ids below the new tracking boundary must not be handed out
    /// again (so subsequent allocations enter the young-slot lists). Record
    /// each discarded `[cursor, end)` tail first — those slots stay reserved
    /// but forever unfilled, and `stats`/`objectSnapshot` must exclude them or
    /// they masquerade as live empty lists. Called at STW by `armTracking`.
    pub fn discardObjectTLABs(self: *ObjectHeap) void {
        for (self.worker_locals) |*l| {
            if (l.object.end > l.object.cursor) {
                const start = ObjectStore.globalIdOf(l.object.segment, l.object.cursor);
                const end = ObjectStore.globalIdOf(l.object.segment, l.object.end);
                self.discarded_object_tails.append(self.allocator, .{ start, end }) catch {};
            }
            l.object = .{};
        }
    }

    /// Bitset snapshot of currently filled object slots. The explorer keeps
    /// one bit per slot and discovers rows lazily.
    /// Build and use this only while evaluation is idle.
    pub const ObjectSnapshot = struct {
        allocator: std.mem.Allocator,
        live_bits: []u64,
        high_water: ObjectId,
        live_count: u32,

        pub fn deinit(self: *ObjectSnapshot) void {
            self.allocator.free(self.live_bits);
            self.* = undefined;
        }

        pub fn isLive(self: *const ObjectSnapshot, id: ObjectId) bool {
            if (id >= self.high_water) return false;
            return self.live_bits[id >> 6] & (@as(u64, 1) << @intCast(id & 63)) != 0;
        }

        pub fn nextLive(self: *const ObjectSnapshot, start: ObjectId) ?ObjectId {
            if (start >= self.high_water) return null;
            var word_index: usize = start >> 6;
            var word = self.live_bits[word_index] & (~@as(u64, 0) << @intCast(start & 63));
            while (true) {
                if (word != 0) {
                    const id: ObjectId = @intCast(word_index * 64 + @ctz(word));
                    return if (id < self.high_water) id else null;
                }
                word_index += 1;
                if (word_index >= self.live_bits.len) return null;
                word = self.live_bits[word_index];
            }
        }

        /// One past the greatest live id, excluding a reserved or reclaimed
        /// tail. Tree ranges use this instead of `high_water`, which is the
        /// backing-store reservation frontier rather than a meaningful record
        /// boundary.
        pub fn liveExtent(self: *const ObjectSnapshot) ObjectId {
            var word_index = self.live_bits.len;
            while (word_index > 0) {
                word_index -= 1;
                const word = self.live_bits[word_index];
                if (word == 0) continue;
                const top_bit: usize = @bitSizeOf(u64) - 1 - @clz(word);
                return @min(
                    self.high_water,
                    @as(ObjectId, @intCast(word_index * 64 + top_bit + 1)),
                );
            }
            return 0;
        }
    };

    pub fn objectSnapshot(self: *const ObjectHeap, allocator: std.mem.Allocator) !ObjectSnapshot {
        const high_water = self.objects.count();
        const words = (@as(usize, high_water) + 63) >> 6;
        const bits = try allocator.alloc(u64, words);
        @memset(bits, ~@as(u64, 0));
        if (words > 0 and high_water & 63 != 0) {
            bits[words - 1] = (@as(u64, 1) << @intCast(high_water & 63)) - 1;
        }

        const unfilled = self.collectUnfilled(.object);
        for (unfilled.starts[0..unfilled.len], unfilled.ends[0..unfilled.len]) |start, end| {
            clearSnapshotRange(bits, start, @min(end, high_water));
        }
        // Object TLAB tails discarded at GC arming: reserved, never filled.
        for (self.discarded_object_tails.items) |r| {
            clearSnapshotRange(bits, r[0], @min(r[1], high_water));
        }
        for (self.worker_locals) |*local| {
            for (local.gc_free_objects.items) |id| clearSnapshotBit(bits, id);
        }
        for (self.gc_shared_free_objects.items) |id| clearSnapshotBit(bits, id);

        // In the detector build reclaimed ids deliberately never enter a free
        // list. Its authoritative allocation bitmap supplies those holes.
        if (comptime gc_debug) if (self.collection.collect_enabled) {
            const floor = self.gcSweepFloor();
            var id = floor;
            while (id < high_water) : (id += 1) {
                if (!self.gcAllocBitSet(id)) clearSnapshotBit(bits, id);
            }
        };

        var live: u32 = 0;
        for (bits) |word| live += @intCast(@popCount(word));
        return .{ .allocator = allocator, .live_bits = bits, .high_water = high_water, .live_count = live };
    }

    /// Live-slot bitmap for a range-allocated store (values/attrs/attr_positions),
    /// mirroring `objectSnapshot`: every reserved id minus GC-freed ranges minus
    /// each worker's unfilled TLAB tail. Lets the explorer browse only the real
    /// records instead of the reserved backing capacity. Reuses `ObjectSnapshot`
    /// (a plain id bitmap).
    fn rangeStoreSnapshot(
        self: *const ObjectHeap,
        allocator: std.mem.Allocator,
        comptime StoreT: type,
        comptime store_field: []const u8,
        comptime local_free_field: []const u8,
        comptime shared_free_field: []const u8,
        comptime tlab_field: []const u8,
    ) !ObjectSnapshot {
        const high_water = @field(self, store_field).count();
        const words = (@as(usize, high_water) + 63) >> 6;
        const bits = try allocator.alloc(u64, words);
        @memset(bits, ~@as(u64, 0));
        if (words > 0 and high_water & 63 != 0) {
            bits[words - 1] = (@as(u64, 1) << @intCast(high_water & 63)) - 1;
        }

        if (high_water > 0) {
            const freed = try allocator.alloc(u64, words);
            defer allocator.free(freed);
            @memset(freed, 0);
            @field(self, shared_free_field).markBitmap(StoreT, freed, high_water);
            for (self.worker_locals) |*local| @field(local, local_free_field).markBitmap(StoreT, freed, high_water);
            for (bits, freed) |*b, f| b.* &= ~f;
        }

        for (self.worker_locals) |*local| {
            const chunk = @field(local, tlab_field);
            if (chunk.cursor >= chunk.end) continue;
            const start = StoreT.globalIdOf(chunk.segment, chunk.cursor);
            const end = StoreT.globalIdOf(chunk.segment, chunk.end);
            clearSnapshotRange(bits, start, @min(end, high_water));
        }

        var live: u32 = 0;
        for (bits) |word| live += @intCast(@popCount(word));
        return .{ .allocator = allocator, .live_bits = bits, .high_water = high_water, .live_count = live };
    }

    pub fn valueSnapshot(self: *const ObjectHeap, allocator: std.mem.Allocator) !ObjectSnapshot {
        return self.rangeStoreSnapshot(allocator, ValueStore, "values", "gc_free_values", "gc_shared_free_values", "value");
    }

    pub fn attrSnapshot(self: *const ObjectHeap, allocator: std.mem.Allocator) !ObjectSnapshot {
        return self.rangeStoreSnapshot(allocator, AttrStore, "attrs", "gc_free_attrs", "gc_shared_free_attrs", "attr");
    }

    pub fn attrPosSnapshot(self: *const ObjectHeap, allocator: std.mem.Allocator) !ObjectSnapshot {
        return self.rangeStoreSnapshot(allocator, AttrPosStore, "attr_positions", "gc_free_attr_pos", "gc_shared_free_attr_pos", "attr_pos");
    }

    pub fn inspectObject(self: *const ObjectHeap, snapshot: *const ObjectSnapshot, id: ObjectId) !ObjectInfo {
        if (!snapshot.isLive(id)) return error.InvalidObjectId;
        return switch (self.objects.get(id).*) {
            .list => |range| .{ .list = .{ .len = range.len } },
            .attrs => |attrs| .{ .attrs = .{
                .len = attrs.range.len,
                .positions = attrs.positions.len,
                .sibling_swept = self.siblingSweepMarked(id),
            } },
            .merge_attrs => |merge| .{ .merge_attrs = .{
                .base = merge.base,
                .overlay = merge.overlay,
                .depth = merge.depth,
                .flattened = blk: {
                    const flat = merge.flattened.load(.acquire);
                    break :blk if (flat == no_flattened_attrs) null else flat;
                },
            } },
            .closure => |closure| .{ .closure = .{ .chunk = closure.chunk_id, .upvalues = closure.upvalues.len } },
            .builtin_closure => |closure| .{ .builtin_closure = .{ .builtin = closure.builtin_id, .args = closure.args.len } },
            .thunk => |*thunk| .{ .thunk = inspectThunk(thunk) },
            .context_string => |string| .{ .context_string = .{ .text = string.text, .context = string.context.len } },
            .boxed_int => |value| .{ .boxed_int = value },
            .partial_app => |partial| .{ .partial_app = .{ .function = inspectValue(partial.func), .args = partial.args.len } },
        };
    }

    /// Collect the direct object/chunk references held by one live object.
    ///
    /// This is a tooling-only, non-forcing walk over already-published payloads.
    /// It intentionally does not flatten merge attrs, force thunks, compile
    /// deferred bodies, or recursively traverse children.
    pub fn collectObjectReferences(
        self: *const ObjectHeap,
        snapshot: *const ObjectSnapshot,
        id: ObjectId,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(HeapReference),
    ) !void {
        if (!snapshot.isLive(id)) return error.InvalidObjectId;
        const object = self.objects.get(id);
        switch (object.*) {
            .list => |range| try self.collectValueRangeReferences(range, allocator, out),
            .attrs => |attrs| try self.collectAttrRangeReferences(attrs.range, allocator, out),
            .merge_attrs => |merge| {
                try out.append(allocator, .{ .object = merge.base });
                try out.append(allocator, .{ .object = merge.overlay });
                const flattened = merge.flattened.load(.acquire);
                if (flattened != no_flattened_attrs)
                    try out.append(allocator, .{ .object = flattened });
            },
            .closure => |closure| {
                try out.append(allocator, .{ .chunk = closure.chunk_id });
                try self.collectValueRangeReferences(closure.upvalues, allocator, out);
            },
            .builtin_closure => |closure| try self.collectValueRangeReferences(closure.args, allocator, out),
            .context_string => |string| try self.collectAttrRangeReferences(string.context, allocator, out),
            .partial_app => |partial| {
                try collectValueReference(partial.func, allocator, out);
                try self.collectValueRangeReferences(partial.args, allocator, out);
            },
            .boxed_int => {},
            .thunk => |*thunk| try collectThunkReferences(thunk, allocator, out),
        }
    }

    fn collectValueReference(
        value: Value,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(HeapReference),
    ) !void {
        switch (inspectValue(value).target) {
            .object => |target| try out.append(allocator, .{ .object = target }),
            .chunk => |target| try out.append(allocator, .{ .chunk = target }),
            .none, .intern, .builtin => {},
        }
    }

    fn collectValueRangeReferences(
        self: *const ObjectHeap,
        range: ValueRange,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(HeapReference),
    ) !void {
        for (self.values.slice(range)) |value|
            try collectValueReference(value, allocator, out);
    }

    fn collectAttrRangeReferences(
        self: *const ObjectHeap,
        range: AttrRange,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(HeapReference),
    ) !void {
        for (self.attrs.slice(range)) |entry|
            try collectValueReference(entry.value, allocator, out);
    }

    fn collectThunkReferences(
        thunk: *const Thunk,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(HeapReference),
    ) !void {
        const raw_state = thunk.future.state.load(.acquire);
        const state: ThunkState = @enumFromInt(@min(raw_state, @intFromEnum(ThunkState.errored)));
        switch (state) {
            .resolved => try collectValueReference(thunk.payload.result, allocator, out),
            // These states do not contain a readable Value payload.
            .errored, .blackhole => {},
            .unresolved, .evaluating => switch (thunk.targetKind()) {
                .closure => try collectValueReference(thunk.payload.target.closure, allocator, out),
                .pass_through => try collectValueReference(thunk.payload.target.pass_through, allocator, out),
                .attr_access => try collectValueReference(thunk.payload.target.attr_access.base, allocator, out),
                .bytecode => {
                    const target = &thunk.payload.target.bytecode;
                    try out.append(allocator, .{ .chunk = target.chunk_id });
                    for (target.upvalues()) |value|
                        try collectValueReference(value, allocator, out);
                },
                .deferred => {
                    for (thunk.payload.target.deferred.env()) |value|
                        try collectValueReference(value, allocator, out);
                },
            },
        }
    }

    fn inspectThunk(thunk: *const Thunk) ThunkInfo {
        const raw_state = thunk.future.state.load(.acquire);
        const state: ThunkState = @enumFromInt(@min(raw_state, @intFromEnum(ThunkState.errored)));
        const body: @TypeOf(@as(ThunkInfo, undefined).body) = switch (state) {
            .resolved => .{ .result = inspectValue(thunk.payload.result) },
            .errored => .{ .error_name = @errorName(thunk.cachedFailure().err()) },
            .unresolved, .evaluating, .blackhole => .{ .target = switch (thunk.targetKind()) {
                .closure => .{ .closure = inspectValue(thunk.payload.target.closure) },
                .bytecode => .{ .bytecode = .{
                    .chunk = thunk.payload.target.bytecode.chunk_id,
                    .captures = thunk.payload.target.bytecode.upvalue_count,
                } },
                .pass_through => .{ .pass_through = inspectValue(thunk.payload.target.pass_through) },
                .attr_access => .{ .attr_access = .{
                    .base = inspectValue(thunk.payload.target.attr_access.base),
                    .name = thunk.payload.target.attr_access.name,
                } },
                .deferred => .{ .deferred = .{
                    .id = thunk.payload.target.deferred.deferred_id,
                    .captures = thunk.payload.target.deferred.env_count,
                } },
            } },
        };
        return .{ .state = state, .demanded = thunk.isDemanded(), .body = body };
    }

    pub fn inspectValue(value: Value) ValueRef {
        const kind = value.kind();
        const target: ValueRef.Target = switch (kind) {
            .list, .attrs, .thunk, .builtin_closure, .string_context, .boxed_int, .partial_app => .{ .object = value.asObjectId() },
            .closure => if (value.isFunction()) .{ .chunk = value.asFunctionChunkId() } else .{ .object = value.asObjectId() },
            .string, .path => .{ .intern = value.asInternId() },
            .builtin => .{ .builtin = value.asBuiltinId() },
            else => .none,
        };
        return .{ .kind = kind, .target = target };
    }

    fn clearSnapshotBit(bits: []u64, id: ObjectId) void {
        const word = id >> 6;
        if (word >= bits.len) return;
        bits[word] &= ~(@as(u64, 1) << @intCast(id & 63));
    }

    fn clearSnapshotRange(bits: []u64, start: ObjectId, end: ObjectId) void {
        var id = start;
        while (id < end) : (id += 1) clearSnapshotBit(bits, id);
    }

    /// Constant-time backing-store reservation counts for interactive
    /// inspection. Unlike `stats`, this does not walk object/value slots.
    pub fn counts(self: *const ObjectHeap) Counts {
        return .{
            .objects = self.objects.count(),
            .values = self.values.count(),
            .attrs = self.attrs.count(),
            .attr_positions = self.attr_positions.count(),
        };
    }

    /// Direct access to a store slot by id, for the VM explorer's per-record
    /// browsing. Ids below `count()` sit in allocated segments (dense append),
    /// so a slot may hold current or GC-stale data — the explorer labels it as a
    /// raw store slot rather than claiming reachability.
    pub fn valueAt(self: *const ObjectHeap, id: u32) ?*const Value {
        if (id >= self.values.count()) return null;
        var next: u32 = id + 1;
        return self.values.getIfAllocated(id, &next);
    }

    pub fn attrAt(self: *const ObjectHeap, id: u32) ?*const AttrEntry {
        if (id >= self.attrs.count()) return null;
        var next: u32 = id + 1;
        return self.attrs.getIfAllocated(id, &next);
    }

    pub fn attrPosAt(self: *const ObjectHeap, id: u32) ?*const AttrPosEntry {
        if (id >= self.attr_positions.count()) return null;
        var next: u32 = id + 1;
        return self.attr_positions.getIfAllocated(id, &next);
    }

    pub const Stats = struct {
        objects: u32,
        values: u32,
        attrs: u32,
        attr_positions: u32,
        variant_counts: [9]u32,
        thunk_states: [5]u32,
        /// Of the `resolved` thunks (thunk_states[2]), the split by
        /// `Thunk.demanded`: `resolved_demanded` were observed by a real
        /// (demand) caller; `resolved_undemanded` were pre-forced by
        /// speculation / fan-out and never observed — the speculative-waste
        /// fraction. See docs/perf/probes.md (instrument I1).
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
                3 => "builtin closure",
                4 => "thunk",
                5 => "context string",
                6 => "boxed int",
                7 => "attrs merge",
                8 => "partial application",
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
        var obj_skip = self.collectUnfilled(.object);
        self.addDiscardedObjectTails(&obj_skip);
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
                        if (t.isDemanded()) {
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
        // Skip unallocated segments in sparse stores.
        var vid: u32 = 0;
        scan_val: while (vid < result.values) : (vid += 1) {
            if (val_skip.skipPast(vid)) |next| {
                vid = next - 1;
                continue :scan_val;
            }
            var next_vid: u32 = undefined;
            const v = self.values.getIfAllocated(vid, &next_vid) orelse {
                vid = next_vid - 1;
                continue :scan_val;
            };
            bucketInt(&result.int_buckets, v.*);
        }
        var aid: u32 = 0;
        scan_attr: while (aid < result.attrs) : (aid += 1) {
            if (attr_skip.skipPast(aid)) |next| {
                aid = next - 1;
                continue :scan_attr;
            }
            var next_aid: u32 = undefined;
            const a = self.attrs.getIfAllocated(aid, &next_aid) orelse {
                aid = next_aid - 1;
                continue :scan_attr;
            };
            bucketInt(&result.int_buckets, a.value);
        }
        return result;
    }

    // ---- `-Dprof-main` demand-prediction censuses ----
    //
    // Exit-time heap walks report:
    //   - creation census: thunks by creation context (demand chain vs.
    //     speculative work) × final observation state — the selection
    //     precision of creation-context speculation policy.
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
        var obj_skip = self.collectUnfilled(.object);
        self.addDiscardedObjectTails(&obj_skip);
        var id: u32 = 0;
        const total = self.objects.count();
        scan: while (id < total) : (id += 1) {
            if (obj_skip.skipPast(id)) |next| {
                id = next - 1;
                continue :scan;
            }
            switch (self.objects.get(id).*) {
                .thunk => |t| {
                    const cell = &cells[if (t.created_demand) 0 else 1];
                    cell.n += 1;
                    const state = t.future.state.load(.acquire);
                    if (t.isDemanded()) {
                        if (t.demanded_old) cell.dem_old += 1 else cell.dem_young += 1;
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
                    c.dem_old,
                    profPct(c.dem_old, c.n),
                    c.dem_young,
                    profPct(c.dem_young, c.n),
                    c.never_resolved_spec,
                    profPct(c.never_resolved_spec, c.n),
                    c.never_unresolved,
                    profPct(c.never_unresolved, c.n),
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
        var obj_skip = self.collectUnfilled(.object);
        self.addDiscardedObjectTails(&obj_skip);
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
                        if (t.isDemanded()) {
                            if (t.demanded_old) dem_old += 1 else dem_young += 1;
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
                    bucket_lo[i],                        b.sets,                        b.touched,                        b.all_demanded_sets,             b.members,
                    b.dem_old,                           profPct(b.dem_old, b.members), b.dem_young,                      profPct(b.dem_young, b.members), b.spec_resolved,
                    profPct(b.spec_resolved, b.members), b.unresolved,                  profPct(b.unresolved, b.members),
                },
            );
        }
        std.debug.print(
            "  TOTAL     : sets={d} touched={d} all_dem={d} members={d} dem_old={d} ({d:.1}%) dem_young={d} ({d:.1}%) spec_res={d} ({d:.1}%) unres={d} ({d:.1}%)\n",
            .{
                tot.sets,          tot.touched,                             tot.all_demanded_sets, tot.members,
                tot.dem_old,       profPct(tot.dem_old, tot.members),       tot.dem_young,         profPct(tot.dem_young, tot.members),
                tot.spec_resolved, profPct(tot.spec_resolved, tot.members), tot.unresolved,        profPct(tot.unresolved, tot.members),
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
        return &self.worker_locals[worker_id_mod.currentId()];
    }

    /// Update this worker thread's creation-context flag (see
    /// `HeapLocal.spec_ctx`). One store to the worker's own cache line.
    pub inline fn setSpecCtx(self: *ObjectHeap, spec: bool) void {
        self.currentLocal().spec_ctx = spec;
    }

    /// `sweep_filter` geometry: 2^22 bits (512 KiB) — comfortably above the
    /// count of size-gated sweep candidates in a large eval, so collisions
    /// stay rare. Fibonacci hashing spreads the sequential store ids.
    const sweep_filter_bits_log2 = 22;
    const sweep_filter_words = (1 << sweep_filter_bits_log2) / 64;

    inline fn sweepFilterBit(id: ObjectId) struct { usize, u64 } {
        const h = (@as(u64, id) *% 0x9e37_79b9_7f4a_7c15) >> (64 - sweep_filter_bits_log2);
        return .{ @intCast(h >> 6), @as(u64, 1) << @intCast(h & 63) };
    }

    /// Whether `id`'s sweep-filter bit is set (inspection only).
    pub fn siblingSweepMarked(self: *const ObjectHeap, id: ObjectId) bool {
        const word, const mask = sweepFilterBit(id);
        return self.sweep_filter[word].load(.monotonic) & mask != 0;
    }

    /// Demand-sibling prefetch admission (`FIX_SIBLING`): true iff `id`
    /// is a plain attrset with entry count in `[min, max)` whose filter
    /// bit was not yet set — and claims that bit, so each set's sweep is
    /// submitted once. `attrs_merge` layers are excluded: sweeping them
    /// would force a flatten on the demand path.
    pub fn trySiblingSweep(self: *ObjectHeap, id: ObjectId, min: u32, max: u32) bool {
        switch (self.get(id).*) {
            .attrs => |a| {
                if (a.range.len < min or a.range.len >= max) return false;
                const word, const mask = sweepFilterBit(id);
                if (self.sweep_filter[word].load(.monotonic) & mask != 0) return false;
                return self.sweep_filter[word].fetchOr(mask, .monotonic) & mask == 0;
            },
            else => return false,
        }
    }

    /// Undo `trySiblingSweep`'s claim when the sweep task could not be
    /// submitted (queue full / no helpers) — otherwise the set becomes
    /// permanently unsweepable on a transient rejection. May clear a
    /// colliding set's bit, which only re-admits an idempotent sweep.
    pub fn clearSiblingSwept(self: *ObjectHeap, id: ObjectId) void {
        const word, const mask = sweepFilterBit(id);
        _ = self.sweep_filter[word].fetchAnd(~mask, .monotonic);
    }

    /// TLAB reserve shared by the three range stores. Callers first try an
    /// exact-size free range when collection is active; fresh reservations use
    /// this per-worker chunk and poll the collection threshold on refill.
    inline fn reserveRangeLocal(
        self: *ObjectHeap,
        comptime StoreT: type,
        store: *StoreT,
        chunk: *LocalChunk,
        free_list: *RangeFreeList,
        store_index: usize,
        chunk_size: u32,
        n: u32,
    ) !StoreT.Range {
        if (chunk.fits(n)) {
            const r = chunk.take(n);
            return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
        }
        // A variable-size request can leave a tail too small for the next
        // request. It has no owning object, so sweep can never discover it;
        // publish it explicitly before replacing this TLAB once reclaim is
        // active. Constrained mode has root_active from startup; the roomy
        // lazy path retains its zero-free-list-tax pre-arm phase.
        if (chunk.cursor < chunk.end) {
            if (self.collection.collect_enabled or self.collection.root_active)
                free_list.push(self.allocator, chunk.segment, chunk.cursor, chunk.end - chunk.cursor);
            chunk.* = .{};
        }
        if (n > chunk_size) {
            const range = try store.reserve(self.allocator, n);
            const local = self.currentLocal();
            local.range_fresh_refills[store_index] += 1;
            local.range_fresh_slots[store_index] += n;
            self.gcCheckThreshold();
            return range;
        }
        const refilled = try store.reserve(self.allocator, chunk_size);
        const local = self.currentLocal();
        local.range_fresh_refills[store_index] += 1;
        local.range_fresh_slots[store_index] += chunk_size;
        self.gcCheckThreshold();
        chunk.segment = refilled.segment;
        chunk.cursor = refilled.offset;
        chunk.end = refilled.offset + refilled.len;
        const r = chunk.take(n);
        return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
    }

    const gc_object_refill_batch: usize = 4096;

    /// Reuse from the worker-owned stack. On empty, refill it from the shared
    /// overflow in one bulk copy. The mutex is therefore cold (roughly once per
    /// 4K successful reuses), and an empty global pool costs one lock per local
    /// batch exhaustion rather than peer probes on every allocation.
    fn gcReuseObject(self: *ObjectHeap, local: *HeapLocal) ?ObjectId {
        if (local.gc_free_objects.pop()) |id| return id;
        // No object ids enter the overflow between collections, so zero is a
        // stable negative hint for the rest of this mutator phase. This keeps
        // bump allocation completely off the mutex once reuse is exhausted.
        if (self.gc_shared_free_count.load(.acquire) == 0) return null;
        self.gc_shared_free_mu.lock();
        defer self.gc_shared_free_mu.unlock();
        const available = self.gc_shared_free_objects.items.len;
        const fair_share = (available + self.worker_locals.len - 1) / self.worker_locals.len;
        const take = @min(gc_object_refill_batch, fair_share);
        if (take == 0) return null;
        local.gc_free_objects.ensureUnusedCapacity(self.allocator, take) catch {
            const id = self.gc_shared_free_objects.pop();
            self.gc_shared_free_count.store(self.gc_shared_free_objects.items.len, .release);
            return id;
        };
        const start = self.gc_shared_free_objects.items.len - take;
        local.gc_free_objects.appendSliceAssumeCapacity(self.gc_shared_free_objects.items[start..]);
        self.gc_shared_free_objects.items.len = start;
        self.gc_shared_free_count.store(start, .release);
        return local.gc_free_objects.pop();
    }

    const gc_range_refill_batch: usize = 256;

    /// Reuse a worker-owned freed range of at least `n` slots from `field`.
    /// An exact match wins; otherwise the list splits a larger range. On a
    /// local miss, refill one compatible size class from the central overflow
    /// in bulk. The fast path remains lock-free, while no worker can strand an
    /// entire shard of ranges that another worker needs.
    fn gcReuseRange(self: *ObjectHeap, local: *HeapLocal, comptime field: []const u8, n: u32) ?RangeFreeList.Loc {
        const store_index = comptime if (std.mem.eql(u8, field, "gc_free_values"))
            0
        else if (std.mem.eql(u8, field, "gc_free_attrs"))
            1
        else if (std.mem.eql(u8, field, "gc_free_attr_pos"))
            2
        else
            @compileError("unknown GC range store");
        const shared_field = comptime if (std.mem.eql(u8, field, "gc_free_values"))
            "gc_shared_free_values"
        else if (std.mem.eql(u8, field, "gc_free_attrs"))
            "gc_shared_free_attrs"
        else
            "gc_shared_free_attr_pos";
        if (@field(local, field).pop(self.allocator, n)) |hit| {
            if (hit.split) local.range_reuse_split[store_index] += 1 else local.range_reuse_exact[store_index] += 1;
            return hit.loc;
        }
        if (n > self.gc_shared_free_range_max[store_index].load(.acquire)) {
            if (n > 0) {
                local.range_reuse_miss[store_index] += 1;
                local.range_reuse_miss_slots[store_index] += n;
            }
            return null;
        }
        self.gc_shared_free_range_mu.lock();
        const shared = &@field(self, shared_field);
        // Claim this request and transfer its surplus fair-share batch as one
        // locked operation. The old refill returned only a boolean, unlocked,
        // then asserted that a second worker-list pop succeeded; repeated
        // parallel collection exposed that handoff as an invalid invariant.
        const hit = shared.moveBestFitBatchAndClaim(
            &@field(local, field),
            self.allocator,
            n,
            gc_range_refill_batch,
            self.worker_locals.len,
        );
        self.gc_shared_free_range_max[store_index].store(shared.maxLen(), .release);
        self.gc_shared_free_range_mu.unlock();
        if (hit) |claimed| {
            if (claimed.split) local.range_reuse_split[store_index] += 1 else local.range_reuse_exact[store_index] += 1;
            return claimed.loc;
        }
        if (n > 0) {
            local.range_reuse_miss[store_index] += 1;
            local.range_reuse_miss_slots[store_index] += n;
        }
        return null;
    }

    pub const RangeReuseCounts = struct {
        exact: u64 = 0,
        split: u64 = 0,
        miss: u64 = 0,
        miss_slots: u64 = 0,
        fresh_refills: u64 = 0,
        fresh_slots: u64 = 0,
    };

    pub const RangeReuseStats = struct {
        values: RangeReuseCounts = .{},
        attrs: RangeReuseCounts = .{},
        attr_pos: RangeReuseCounts = .{},
    };

    pub const FreeRangeStats = RangeFreeList.Stats;

    pub const FreeRangesStats = struct {
        objects: u64 = 0,
        values: FreeRangeStats = .{},
        attrs: FreeRangeStats = .{},
        attr_pos: FreeRangeStats = .{},
    };

    /// Aggregate diagnostics after evaluation has quiesced.
    pub fn rangeReuseStats(self: *const ObjectHeap) RangeReuseStats {
        var total: RangeReuseStats = .{};
        for (self.worker_locals) |*local| {
            inline for (.{ &total.values, &total.attrs, &total.attr_pos }, 0..) |dst, i| {
                dst.exact += local.range_reuse_exact[i];
                dst.split += local.range_reuse_split[i];
                dst.miss += local.range_reuse_miss[i];
                dst.miss_slots += local.range_reuse_miss_slots[i];
                dst.fresh_refills += local.range_fresh_refills[i];
                dst.fresh_slots += local.range_fresh_slots[i];
            }
        }
        return total;
    }

    pub const ObjectReuseStats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        fresh_refills: u64 = 0,
        collect_requests: u64 = 0,
    };

    pub fn objectReuseStats(self: *const ObjectHeap) ObjectReuseStats {
        var total: ObjectReuseStats = .{};
        for (self.worker_locals) |*local| {
            total.hits += local.object_reuse_hits;
            total.misses += local.object_reuse_misses;
            total.fresh_refills += local.object_fresh_refills;
        }
        total.collect_requests = self.collection.object_miss_collect_requests.load(.monotonic);
        return total;
    }

    pub fn freeRangesStats(self: *const ObjectHeap) FreeRangesStats {
        var total: FreeRangesStats = .{ .objects = self.gc_shared_free_objects.items.len };
        total.values.add(self.gc_shared_free_values.stats());
        total.attrs.add(self.gc_shared_free_attrs.stats());
        total.attr_pos.add(self.gc_shared_free_attr_pos.stats());
        for (self.worker_locals) |*local| {
            total.objects += local.gc_free_objects.items.len;
            total.values.add(local.gc_free_values.stats());
            total.attrs.add(local.gc_free_attrs.stats());
            total.attr_pos.add(local.gc_free_attr_pos.stats());
        }
        return total;
    }

    /// Publish every worker's unused local object-id batch to the shared
    /// overflow while the world is stopped. If growing the shared vector fails,
    /// leave all locals untouched; correctness and reuse remain local.
    fn gcPoolFreeObjects(self: *ObjectHeap) void {
        var publish_count: usize = 0;
        for (self.worker_locals) |*local| publish_count += local.gc_free_objects.items.len;
        self.gc_shared_free_objects.ensureUnusedCapacity(self.allocator, publish_count) catch return;
        for (self.worker_locals) |*local| {
            self.gc_shared_free_objects.appendSliceAssumeCapacity(local.gc_free_objects.items);
            local.gc_free_objects.clearRetainingCapacity();
        }
        self.gc_shared_free_count.store(self.gc_shared_free_objects.items.len, .release);
    }

    /// Re-arm the object-pool exhaustion trigger only when the completed
    /// collection produced enough reusable slots to amortize another pause.
    /// If a growing live set leaves little or nothing free, the ordinary byte
    /// headroom remains the sole trigger and prevents collection thrashing.
    pub fn gcArmObjectMissCollection(self: *ObjectHeap) void {
        const min_reclaimed_slots: usize = 1 << 16;
        var available = self.gc_shared_free_count.load(.acquire);
        for (self.worker_locals) |*local| available += local.gc_free_objects.items.len;
        self.collection.object_miss_collect_armed.store(available >= min_reclaimed_slots, .release);
    }

    /// Stop-the-world publication for worker-owned free lists. With one worker,
    /// preserve the original local-only path. With multiple workers, unused
    /// local cache contents become central overflow so future demand, rather
    /// than the previous interval's worker assignment, controls distribution.
    pub fn gcRebalanceFreeLists(self: *ObjectHeap) void {
        if (self.worker_locals.len < 2) return;
        gcPoolFreeObjects(self);
        inline for (.{
            .{ "gc_free_values", "gc_shared_free_values", 0 },
            .{ "gc_free_attrs", "gc_shared_free_attrs", 1 },
            .{ "gc_free_attr_pos", "gc_shared_free_attr_pos", 2 },
        }) |fields| {
            for (self.worker_locals) |*local|
                @field(local, fields[0]).moveAllTo(&@field(self, fields[1]), self.allocator);
            self.gc_shared_free_range_max[fields[2]].store(@field(self, fields[1]).maxLen(), .release);
        }
    }

    /// At a full-heap stop-the-world boundary, merge adjacent intervals that
    /// accumulated in different collections, worker shards, or size classes.
    ///
    /// This deliberately starts from the existing free lists rather than from
    /// the complement of the live set. Consequently it cannot mistake an
    /// unpublished allocation or an active TLAB tail for free storage. One bit
    /// per reserved slot avoids sorting tens of millions of tiny intervals;
    /// stores are processed sequentially, bounding temporary memory to the
    /// largest store's bitmap.
    pub fn gcCoalesceFreeRanges(self: *ObjectHeap) void {
        inline for (.{
            .{ ValueStore, "values", "gc_free_values", "gc_shared_free_values", 0 },
            .{ AttrStore, "attrs", "gc_free_attrs", "gc_shared_free_attrs", 1 },
            .{ AttrPosStore, "attr_positions", "gc_free_attr_pos", "gc_shared_free_attr_pos", 2 },
        }) |fields| self.gcCoalesceRangeStore(fields[0], fields[1], fields[2], fields[3], fields[4]);
    }

    fn gcCoalesceRangeStore(
        self: *ObjectHeap,
        comptime StoreT: type,
        comptime store_field: []const u8,
        comptime local_field: []const u8,
        comptime shared_field: []const u8,
        comptime store_index: usize,
    ) void {
        const slot_count = @field(self, store_field).count();
        if (slot_count == 0) return;
        const word_count = (@as(usize, slot_count) + 63) >> 6;
        const bitmap = self.allocator.alloc(u64, word_count) catch return;
        defer self.allocator.free(bitmap);
        @memset(bitmap, 0);

        @field(self, shared_field).markBitmap(StoreT, bitmap, slot_count);
        for (self.worker_locals) |*local|
            @field(local, local_field).markBitmap(StoreT, bitmap, slot_count);

        // The bitmap is now a complete snapshot of known-free storage. Only
        // after that succeeds do we destructively replace the fragmented form.
        @field(self, shared_field).clearRetainingCapacity();
        for (self.worker_locals) |*local|
            @field(local, local_field).clearRetainingCapacity();

        const dst = if (self.worker_locals.len == 1)
            &@field(self.worker_locals[0], local_field)
        else
            &@field(self, shared_field);
        const last_segment = StoreT.locationOf(slot_count - 1).segment;
        var segment: u32 = 0;
        while (segment <= last_segment) : (segment += 1) {
            const segment_start = StoreT.globalIdOf(segment, 0);
            const segment_end = if (segment == last_segment)
                slot_count
            else
                StoreT.globalIdOf(segment + 1, 0);
            const segment_start_usize: usize = segment_start;
            const segment_end_usize: usize = segment_end;
            var cursor = segment_start_usize;
            while (nextSetBit(bitmap, cursor, segment_end_usize)) |run_start| {
                const run_end = nextClearBit(bitmap, run_start, segment_end_usize);
                dst.push(
                    self.allocator,
                    segment,
                    @intCast(run_start - segment_start_usize),
                    @intCast(run_end - run_start),
                );
                cursor = run_end;
            }
        }
        // Coalescing changes the range-length distribution. Drop the empty
        // vectors for obsolete classes (including emptied worker shards)
        // instead of retaining every distribution's historical peak forever.
        @field(self, shared_field).releaseEmptyCapacity(self.allocator);
        for (self.worker_locals) |*local|
            @field(local, local_field).releaseEmptyCapacity(self.allocator);
        self.gc_shared_free_range_max[store_index].store(@field(self, shared_field).maxLen(), .release);
    }

    fn reserveValuesLocal(self: *ObjectHeap, n: u32) !ValueRange {
        const local = self.currentLocal();
        // NON-MOVING reuse: a swept dead range of at least `n` is reused (and
        // split when larger) before touching the bump cursor. Ranges never
        // relocate, so the returned slice remains stable across forces.
        if (self.collection.collect_enabled) {
            if (self.gcReuseRange(local, "gc_free_values", n)) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
        }
        return self.reserveRangeLocal(ValueStore, &self.values, &local.value, &local.gc_free_values, 0, value_chunk_size, n);
    }

    /// Reserve `n` slots of attr storage for a merge in progress.
    /// Caller writes into the returned range via `attrsMutSlice` and
    /// publishes the final entry count with `publishMergedAttrs`. Used
    /// by attr-set merge primitives to skip a per-merge ArrayList +
    /// extra copy.
    pub fn reserveAttrsForMerge(self: *ObjectHeap, n: u32) !AttrRange {
        return self.reserveAttrsLocal(n);
    }

    pub fn attrsMutSlice(self: *ObjectHeap, range: AttrRange) []AttrEntry {
        return self.attrs.sliceMut(range);
    }

    /// Commit a partially-filled reservation as a new attrs object. Return the
    /// unused suffix immediately: it has no owner for sweep to find later.
    pub fn publishMergedAttrs(self: *ObjectHeap, range: AttrRange, actual: u32) !ObjectId {
        self.releaseAttrsTail(range, actual);
        if (actual == 0) if (self.empty_attrs_id) |id| return id;
        const trimmed: AttrRange = .{
            .segment = range.segment,
            .offset = range.offset,
            .len = actual,
        };
        return self.add(.{ .attrs = .{ .range = trimmed } });
    }

    fn reserveAttrsLocal(self: *ObjectHeap, n: u32) !AttrRange {
        const local = self.currentLocal();
        if (self.collection.collect_enabled) {
            if (self.gcReuseRange(local, "gc_free_attrs", n)) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
        }
        return self.reserveRangeLocal(AttrStore, &self.attrs, &local.attr, &local.gc_free_attrs, 1, attr_chunk_size, n);
    }

    fn reserveAttrPositionsLocal(self: *ObjectHeap, n: u32) !AttrPosRange {
        const local = self.currentLocal();
        if (self.collection.collect_enabled) {
            if (self.gcReuseRange(local, "gc_free_attr_pos", n)) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
        }
        return self.reserveRangeLocal(AttrPosStore, &self.attr_positions, &local.attr_pos, &local.gc_free_attr_pos, 2, attr_position_chunk_size, n);
    }

    fn releaseAttrsTail(self: *ObjectHeap, range: AttrRange, actual: u32) void {
        std.debug.assert(actual <= range.len);
        if (actual == range.len) return;
        if (!self.collection.collect_enabled and !self.collection.root_active) return;
        self.currentLocal().gc_free_attrs.push(
            self.allocator,
            range.segment,
            range.offset + actual,
            range.len - actual,
        );
    }

    /// Threshold hook: once reserved bytes cross `collection.threshold_bytes`, request a
    /// (non-moving) collection to run at the next forceThunk safepoint — it marks
    /// live, promotes survivors in place, and frees dead ranges to the free lists.
    inline fn gcCheckThreshold(self: *ObjectHeap) void {
        if (self.totalReservedBytes() >= self.collection.threshold_bytes) self.collection.collect_requested = true;
    }

    /// Register the collect callback. Fired at
    /// a safepoint via `gcRunCollect` when a collection has been requested.
    pub fn setGcHook(self: *ObjectHeap, hook: GcHook) void {
        self.collection.hook = hook;
    }

    /// Allocate the shared empty-`[]`/`{}` singletons if not already present.
    /// Call once at bootstrap (see `Engine.ensureBuiltins`), on the main
    /// thread and before GC arming, so both ids fall below
    /// `collection.bootstrap_end` and stay pinned. Idempotent. The `addList`/
    /// `addAttrs` calls below observe `empty_*_id == null` and allocate real
    /// slots, which we then cache; every later empty returns these ids.
    pub fn ensureEmptySingletons(self: *ObjectHeap) !void {
        // Complete either half independently so an allocation failure between
        // the two assignments cannot leave future calls believing bootstrap
        // finished.
        if (self.empty_list_id == null)
            self.empty_list_id = try self.addList(&.{});
        if (self.empty_attrs_id == null)
            self.empty_attrs_id = try self.addAttrs(&.{});
    }

    pub fn add(self: *ObjectHeap, object: Object) !ObjectId {
        const id = try self.reserveObjectSlot();
        self.fillObjectSlot(id, object);
        if (object == .thunk) self.currentLocal().thunks_created += 1;
        // `-Dprof-main` creation-context probe: tag the thunk with whether
        // it was created on the demand chain (vs. inside speculative work).
        // Post-fill, pre-publish — no reader can observe the slot yet.
        if (comptime prof_census_enabled) {
            if (object == .thunk)
                self.objects.getMut(id).thunk.created_demand = !self.currentLocal().spec_ctx;
        }
        return id;
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
            // Reuse a slot freed by a prior collection (own shard, else
            // work-steal from a peer). Detector leaves freed slots unused so
            // use-after-free is caught.
            if (self.collection.collect_enabled and !self.collection.disable_reuse and !gc_debug) {
                if (self.gcReuseObject(local)) |rid| {
                    local.object_reuse_hits += 1;
                    break :blk rid;
                }
                local.object_reuse_misses += 1;
                if (self.collection.object_miss_collect_armed.swap(false, .acq_rel)) {
                    self.collection.collect_requested = true;
                    _ = self.collection.object_miss_collect_requests.fetchAdd(1, .monotonic);
                }
            }
            const chunk = &local.object;
            if (chunk.cursor < chunk.end) {
                const cid = ObjectStore.globalIdOf(chunk.segment, chunk.cursor);
                chunk.cursor += 1;
                break :blk cid;
            }
            const refilled = try self.objects.reserve(self.allocator, object_chunk_size);
            local.object_fresh_refills += 1;
            chunk.segment = refilled.segment;
            chunk.cursor = refilled.offset;
            chunk.end = refilled.offset + refilled.len;
            const cid = ObjectStore.globalIdOf(chunk.segment, chunk.cursor);
            chunk.cursor += 1;
            break :blk cid;
        };
        // Record the id in this worker's young-slot list: the minor iterates
        // exactly these (O(young)), and it's robust to slot reuse and the
        // reserved-vs-filled TLAB tail (both of which broke an id-range frontier).
        if (self.collection.collect_enabled)
            local.gc_young_slots.append(self.allocator, id) catch @panic("gc young-object tracking exhausted");
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
            // `collection.root_active` (not `collection.collect_enabled`): in constrained mode
            // bits go live from eval start so the pre-arming region [bootstrap_
            // end, track_from) has precise per-object bits for the major sweep +
            // assert. Non-constrained: identical to gating on collect_enabled.
            if (self.collection.root_active) self.gcSetAllocBit(id);
        }
    }

    // --- GC allocation and reclamation state ---

    /// Floor on the major-collection gate (see `collection.major_gate`): promote at
    /// least this many objects since the last major before the next one, so a
    /// small heap never major-thrashes. Above the floor the gate tracks the
    /// live set (major when the old gen has roughly doubled with tenurings).
    pub const gc_major_gate_floor: u64 = 1 << 20;
    /// Headroom of genuinely-fresh committed pages between collections
    /// (additive, anchored to the cursor at last collect — see
    /// `gcAfterCollect`). Keeps peak RSS near live + a constant.
    pub const gc_headroom: u64 = 1024 << 20;

    /// A/B knob (`FIX_GC_NOREUSE`): skip free-list reuse on the allocation hot
    /// paths (bump-allocate instead). Measurement only — loses the RSS bound.
    /// Lets us isolate reclaim's reuse cost/benefit. Set from the evaluator.
    pub fn gcSetDisableReuse(self: *ObjectHeap, v: bool) void {
        self.collection.disable_reuse = v;
    }

    /// Is the alloc-bit set for `id`? (Detector helper.) Atomic load — the
    /// bitmap is written concurrently by other workers' fills at --workers>1
    /// (pre-sized in `gcEnableCollect`, so the array never moves).
    fn gcAllocBitSet(self: *const ObjectHeap, id: ObjectId) bool {
        const word = id >> 6;
        if (word >= self.collection.alloc_bits.len) return false;
        const w = @atomicLoad(u64, &self.collection.alloc_bits[word], .monotonic);
        return w & (@as(u64, 1) << @intCast(id & 63)) != 0;
    }

    /// Test-only liveness observation after an explicit collection. The GC
    /// bitmap access is compile-time absent from non-test builds.
    pub fn isObjectAllocatedForTest(self: *const ObjectHeap, id: ObjectId) bool {
        if (comptime !builtin.is_test) return false;
        if (id < self.gcSweepFloor()) return true;
        return self.gcAllocBitSet(id);
    }

    /// Detector: trap if a *tracked* slot is read after being freed.
    inline fn gcAssertLive(self: *const ObjectHeap, id: ObjectId) void {
        if (comptime !gc_debug) return;
        if (self.collection.collect_enabled and id >= self.gcSweepFloor() and !self.gcAllocBitSet(id)) {
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
            @as(u64, self.values.count()) * @sizeOf(Value) +
            @as(u64, self.attrs.count()) * @sizeOf(AttrEntry) +
            @as(u64, self.attr_positions.count()) * @sizeOf(AttrPosEntry);
    }

    pub fn gcCollectRequested(self: *const ObjectHeap) bool {
        return self.collection.collect_requested;
    }

    /// Rebuild the alloc bitmap (which slots are filled-and-live) from
    /// scratch at a collection safepoint, so the per-alloc fast path needn't
    /// set bits incrementally. Filled = every tracked id `[track_from,
    /// count)` MINUS (a) each worker's reserved-but-unfilled object-chunk
    /// tail and (b) the currently-free slots. Relies on the object id space
    /// being dense with no gaps other than every worker's current-chunk tail.
    /// Release builds only; the detector build keeps the incremental bitmap
    /// (it asserts liveness on every read, between collections).
    /// Lowest ObjectId a major sweep may reclaim: the pre-arming boundary in
    /// constrained mode (`collection.root_always`), else the arming boundary (pre-arming
    /// region pinned). Doubles as the detector's read-after-free assert floor.
    inline fn gcSweepFloor(self: *const ObjectHeap) ObjectId {
        return if (self.collection.root_always) self.collection.bootstrap_end else self.collection.track_from;
    }

    /// Detector build: size the alloc bitmap to the whole object id space so
    /// per-fill bit-sets never realloc under a concurrent reader/setter at
    /// --workers>1. Debug only. Called at arming, or earlier at
    /// gcEnableBudget in constrained mode (bits go live from eval start there).
    pub fn gcPresizeAllocBits(self: *ObjectHeap) void {
        if (comptime !gc_debug) return;
        const words = (@as(usize, object_max_slots) + 63) >> 6;
        self.collection.alloc_bits = self.allocator.realloc(self.collection.alloc_bits, words) catch self.collection.alloc_bits;
        @memset(self.collection.alloc_bits, 0);
    }

    pub fn gcReconstructAllocBits(self: *ObjectHeap) void {
        const n = self.objects.count();
        const words = (@as(usize, n) + 63) >> 6;
        if (self.collection.alloc_bits.len < words) {
            const old_len = self.collection.alloc_bits.len;
            self.collection.alloc_bits = self.allocator.realloc(self.collection.alloc_bits, words) catch return;
            @memset(self.collection.alloc_bits[old_len..words], 0);
        }
        @memset(self.collection.alloc_bits[0..words], 0);
        gcSetBitRange(self.collection.alloc_bits, self.gcSweepFloor(), n);
        // Exclude each worker's reserved-but-unfilled current object chunk.
        for (self.worker_locals) |*wl| {
            const lo = ObjectStore.globalIdOf(wl.object.segment, wl.object.cursor);
            const hi = ObjectStore.globalIdOf(wl.object.segment, wl.object.end);
            if (hi > lo) gcClearBitRange(self.collection.alloc_bits, lo, hi);
        }
        // Exclude slots already on any worker's object free list (freed by a
        // prior collection, not yet reused).
        for (self.worker_locals) |*wl| {
            for (wl.gc_free_objects.items) |id| {
                const word = id >> 6;
                if (word < self.collection.alloc_bits.len) self.collection.alloc_bits[word] &= ~(@as(u64, 1) << @intCast(id & 63));
            }
        }
        for (self.gc_shared_free_objects.items) |id| {
            const word = id >> 6;
            if (word < self.collection.alloc_bits.len) self.collection.alloc_bits[word] &= ~(@as(u64, 1) << @intCast(id & 63));
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
        if (word >= self.collection.alloc_bits.len) return;
        _ = @atomicRmw(u64, &self.collection.alloc_bits[word], .Or, @as(u64, 1) << @intCast(id & 63), .monotonic);
    }

    // ===================================================================
    // Generational collection
    // ===================================================================

    /// Is object `id` young? Old ⇒ its bit is set (promoted in a prior minor);
    /// young ⇒ clear or beyond the (STW-grown) bitmap. No allocation barrier.
    pub inline fn gcIsYoung(self: *const ObjectHeap, id: ObjectId) bool {
        // Bootstrap objects are pinned and treated as old so later edges from
        // them to young objects enter the remembered set.
        if (id < self.collection.track_from) return false;
        const word = id >> 6;
        if (word >= self.collection.old_bits.len) return true;
        return self.collection.old_bits[word] & (@as(u64, 1) << @intCast(id & 63)) == 0;
    }

    pub inline fn gcSetOld(self: *ObjectHeap, id: ObjectId) void {
        const word = id >> 6;
        if (word >= self.collection.old_bits.len) return;
        // Parallel minor sweepers may promote ids in the same bitmap word.
        _ = @atomicRmw(u64, &self.collection.old_bits[word], .Or, @as(u64, 1) << @intCast(id & 63), .monotonic);
    }

    /// Grow the generation bitmap to cover `[0, count)` (new words zeroed ⇒
    /// young). STW only, so plain (non-atomic).
    pub fn gcGrowOldBits(self: *ObjectHeap, count: u32) void {
        const words = (@as(usize, count) + 63) >> 6;
        if (self.collection.old_bits.len < words) {
            const old_len = self.collection.old_bits.len;
            self.collection.old_bits = self.allocator.realloc(self.collection.old_bits, words) catch return;
            @memset(self.collection.old_bits[old_len..words], 0);
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
    pub inline fn gcRecordEdge(self: *ObjectHeap, source: ObjectId, referent: Value) void {
        if (!self.collection.collect_enabled) return;
        const ref_id = gcHeapId(referent) orelse return;
        if (!self.gcIsYoung(ref_id)) return; // referent already old
        if (self.gcIsYoung(source)) return; // source young → not old→young
        // Dropping an old→young edge permits a live young object to be swept
        // during the next minor collection. The remembered set is therefore
        // correctness metadata, not an optional optimization.
        self.currentLocal().gc_remset.append(self.allocator, source) catch @panic("gc remembered set exhausted");
    }

    /// GC minor-collect statistics; populated by the collector
    /// driver in `heap/collector.zig`.
    pub const MinorStats = struct { promoted: u64 = 0, freed: u64 = 0 };

    /// Grab the next marker slot for this worker (collector or peer). A slot
    /// `>= marker_count` means "don't participate — park idle". Called by both
    /// the collector and the parallel-mark helper hook.
    pub fn gcMarkSlotGrab(self: *ObjectHeap) u32 {
        return self.collection.mark_slot.fetchAdd(1, .acq_rel);
    }

    /// Post-major-sweep reconciliation of the generational state. A full sweep
    /// reclaimed every unmarked object (young AND old), so the surviving set is
    /// exactly `mark_bits`. Tenure all of them (a full collection is a total
    /// tenure) and empty the per-worker young lists, so the young generation
    /// restarts empty: no live young objects, hence no old→young edges, hence
    /// the caller can drop the remembered set. STW-only.
    pub fn gcMajorReconcile(self: *ObjectHeap, mark_bits: []const u64) void {
        const n = self.objects.count();
        self.gcGrowOldBits(n);
        // Clear the whole generation bitmap first, THEN re-tenure survivors: a
        // just-freed OLD slot must lose its old bit, or when the allocator reuses
        // it the object is wrongly seen as old — the write barrier skips its
        // old→young edges and the next minor never scans it (use-after-free).
        // Bootstrap ids below the tracking boundary are old via that check, not
        // the bit, so clearing them here is harmless. STW only.
        const words = (@as(usize, n) + 63) >> 6;
        @memset(self.collection.old_bits[0..@min(words, self.collection.old_bits.len)], 0);
        for (mark_bits, 0..) |word, wi| {
            var w = word;
            while (w != 0) {
                const bit = @ctz(w);
                self.gcSetOld(@intCast(wi * 64 + @as(usize, bit)));
                w &= w - 1;
            }
        }
        for (self.worker_locals) |*wl| wl.gc_young_slots.clearRetainingCapacity();
        // Constrained mode: this major swept the pre-arming region too, so unify
        // the tracked frontier down to the bootstrap boundary. gcIsYoung's hard
        // floor is the tracking boundary; lowering it lets a
        // reused pre-arming slot be correctly young-eligible instead of
        // mis-tagged permanently-old (which would skip its write barrier → UAF).
        if (self.collection.root_always) self.collection.track_from = self.collection.bootstrap_end;
    }

    /// Major-collection policy hooks (see `collection.major_gate`).
    /// Should the next in-eval collection be a MAJOR? True once enough objects
    /// have tenured since the last major that the old generation likely holds a
    /// live-set's worth of reclaimable garbage.
    pub fn gcShouldMajor(self: *const ObjectHeap) bool {
        // Constrained mode keeps precise transient roots from evaluation start
        // specifically so the pre-arming half-budget can be reclaimed. Until
        // one major reconciles it, `track_from` still points at the later
        // arming boundary; don't leave that large region pinned merely because
        // a short allocation-heavy run never reaches the promotion gate.
        if (self.collection.root_always and self.collection.track_from != self.collection.bootstrap_end) return true;
        return self.collection.promoted_since_major >= self.collection.major_gate;
    }

    /// A minor tenured `promoted` objects; charge them against the major gate.
    pub fn gcNoteMinorPromoted(self: *ObjectHeap, promoted: u64) void {
        self.collection.promoted_since_major += promoted;
    }

    /// A major just ran, leaving `live_objects` alive (all now tenured). Reset
    /// the promotion counter and re-arm the gate to the new live set (floored),
    /// so the next major fires once the old gen has ~doubled again.
    pub fn gcNoteMajor(self: *ObjectHeap, live_objects: u64) void {
        self.collection.promoted_since_major = 0;
        self.collection.major_gate = @max(gc_major_gate_floor, live_objects);
    }

    pub fn getMut(self: *ObjectHeap, id: ObjectId) *Object {
        self.gcAssertLive(id);
        return self.objects.getMut(id);
    }

    pub fn get(self: *const ObjectHeap, id: ObjectId) *const Object {
        self.gcAssertLive(id);
        return self.objects.get(id);
    }

    pub fn getList(self: *const ObjectHeap, id: ObjectId) ![]const Value {
        return switch (self.get(id).*) {
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

    /// Return a flat, sorted attr slice, materializing a layered `//` merge
    /// when necessary. Materialization allocates and atomically publishes a
    /// memoized heap object; callers that only need one name should use
    /// `getAttrValueOpt` to keep the operation read-only.
    pub fn materializeAttrs(self: *ObjectHeap, id: ObjectId) ![]const AttrEntry {
        // Pointer captures here and below: a by-value union read would
        // memcpy the whole arm storage, racing the atomic `flattened`
        // memoization CAS embedded in live merge nodes.
        return switch (self.get(id).*) {
            .attrs => |*a| self.attrs.slice(a.range),
            .merge_attrs => self.attrs.slice(self.get(try self.flattenMerge(id)).attrs.range),
            else => error.InvalidObjectType,
        };
    }

    pub fn getAttrValue(self: *const ObjectHeap, id: ObjectId, name: InternId) !Value {
        return (try self.getAttrValueOpt(id, name)) orelse error.MissingAttribute;
    }

    /// Right-biased attr lookup returning null for a missing key. Walks a
    /// `attrs_merge` chain overlay-first without flattening (read-only, so
    /// it stays const and feeds the hot inline cache). Once a node has
    /// been flattened it delegates to the flat object's binary search.
    pub fn getAttrValueOpt(self: *const ObjectHeap, id: ObjectId, name: InternId) anyerror!?Value {
        return switch (self.get(id).*) {
            .attrs => |*a| binarySearchAttr(self.attrs.slice(a.range), name),
            .merge_attrs => |*m| {
                const flat = m.flattened.load(.acquire);
                if (flat != no_flattened_attrs) {
                    return binarySearchAttr(self.attrs.slice(self.get(flat).attrs.range), name);
                }
                if (try self.getAttrValueOpt(m.overlay, name)) |v| return v;
                return self.getAttrValueOpt(m.base, name);
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getAttrPos(self: *const ObjectHeap, id: ObjectId, name: InternId) ?SourcePos {
        return switch (self.get(id).*) {
            .attrs => |*a| if (a.positions.len == 0) null else self.findAttrPos(a.positions, name),
            // `//` is right-biased; report the overlay's position if it
            // defines the name, else the base's. Walks the chain rather
            // than flattening (flattening drops positions).
            .merge_attrs => |*m| if (self.attrContains(m.overlay, name))
                self.getAttrPos(m.overlay, name)
            else
                self.getAttrPos(m.base, name),
            else => null,
        };
    }

    fn attrContains(self: *const ObjectHeap, id: ObjectId, name: InternId) bool {
        return switch (self.get(id).*) {
            .attrs => |*a| binarySearchAttrIndex(self.attrs.slice(a.range), name) != null,
            .merge_attrs => |*m| self.attrContains(m.overlay, name) or self.attrContains(m.base, name),
            else => false,
        };
    }

    /// `left // right` as a (possibly layered) attrset. Large left
    /// operands are wrapped in a `attrs_merge` node instead of copied;
    /// small ones and over-deep chains fall back to the eager flat merge.
    pub fn mergeAttrsLayered(self: *ObjectHeap, left_id: ObjectId, right_id: ObjectId) !ObjectId {
        // `{} // x = x` / `x // {} = x`: an empty operand contributes nothing
        // to the right-biased merge, so return the other id instead of
        // building a merge node or copying. An empty attrset is always a
        // plain `.attrs` of range.len 0 (merges of non-empties are never
        // empty). `{} // x` in the module fixpoint is common — see census.
        const l = self.get(left_id);
        if (l.* == .attrs and l.attrs.range.len == 0) return right_id;
        const r = self.get(right_id);
        if (r.* == .attrs and r.attrs.range.len == 0) return left_id;

        const next_depth: u16 = switch (l.*) {
            .attrs => |*a| if (a.range.len < merge_layer_min_size) 0 else 1,
            .merge_attrs => |*m| if (m.depth + 1 > merge_flatten_depth) 0 else m.depth + 1,
            else => 0,
        };
        if (next_depth == 0) return self.addMergedAttrs(left_id, right_id);
        return self.add(.{ .merge_attrs = .{
            .base = left_id,
            .overlay = right_id,
            .depth = next_depth,
            .flattened = .init(no_flattened_attrs),
        } });
    }

    /// Materialize (memoized) a `attrs_merge` chain into a flat attrs
    /// object and return its id. Collects the whole chain's leaves in
    /// precedence order and does ONE k-way right-biased merge — avoiding
    /// the O(depth·N) intermediate attrs objects a recursive pairwise
    /// flatten would allocate.
    fn flattenMerge(self: *ObjectHeap, id: ObjectId) anyerror!ObjectId {
        const cached = self.getMut(id).merge_attrs.flattened.load(.acquire);
        if (cached != no_flattened_attrs) return cached;

        var leaves: std.ArrayListUnmanaged(ObjectId) = .empty;
        defer leaves.deinit(self.allocator);
        try self.collectMergeLeaves(id, &leaves);
        const flat = try self.kwayMergeLeaves(leaves.items);

        const prev = self.getMut(id).merge_attrs.flattened.cmpxchgStrong(no_flattened_attrs, flat, .acq_rel, .acquire);
        // old→young barrier: the (possibly old) merge node now points at its
        // flattened attrs object. Only the CAS winner installed the edge.
        if (prev == null) self.gcRecordEdge(id, Value.attrs(flat));
        return prev orelse flat;
    }

    /// Append the plain-attrs leaves of a `attrs_merge` subtree to `out`
    /// in left-to-right (oldest-base → newest-overlay) precedence order.
    /// An already-flattened node contributes its cached flat leaf.
    fn collectMergeLeaves(self: *ObjectHeap, id: ObjectId, out: *std.ArrayListUnmanaged(ObjectId)) anyerror!void {
        switch (self.get(id).*) {
            .attrs => try out.append(self.allocator, id),
            .merge_attrs => |*m| {
                const f = m.flattened.load(.acquire);
                if (f != no_flattened_attrs) {
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
        if (leaves.len > @bitSizeOf(usize)) {
            // Leaf sets wider than the cursor bitmask reduce in machine-word
            // chunks through the fast path below, then k-way the
            // intermediates (recursing until they fit). Chunks are
            // contiguous in precedence order and the outer merge is
            // right-biased across chunks, so the result is identical to
            // the flat one-pass merge. Cost is O(N·k/64 + N·chunks).
            var reduced: std.ArrayListUnmanaged(ObjectId) = .empty;
            defer reduced.deinit(self.allocator);
            var start: usize = 0;
            while (start < leaves.len) : (start += @bitSizeOf(usize)) {
                const end = @min(leaves.len, start + @bitSizeOf(usize));
                try reduced.append(self.allocator, try self.kwayMergeLeaves(leaves[start..end]));
            }
            return self.kwayMergeLeaves(reduced.items);
        }
        const n = leaves.len;
        const slices = try self.allocator.alloc([]const AttrEntry, n);
        defer self.allocator.free(slices);
        const cursors = try self.allocator.alloc(usize, n);
        defer self.allocator.free(cursors);

        var cap: u32 = 0;
        for (leaves, 0..) |leaf, i| {
            slices[i] = self.attrs.slice(self.get(leaf).attrs.range);
            cursors[i] = 0;
            cap += @intCast(slices[i].len);
        }

        const reserved = try self.reserveAttrsLocal(cap);
        const dst = self.attrs.sliceMut(reserved);
        var out: usize = 0;
        while (true) {
            // One scan: the smallest name across all cursors, the set of
            // leaves sitting on it (bitmask — depth is bounded, so k is
            // small), and the smallest name any OTHER leaf is at (`next`).
            // Every remaining name < `next` lives only in min-name leaves
            // (a leaf's cursor is its minimum remaining name).
            var min_name: InternId = undefined;
            var mask: usize = 0;
            var next: InternId = std.math.maxInt(InternId);
            for (slices, cursors, 0..) |s, c, i| {
                if (c >= s.len) continue;
                const nm = s[c].name;
                if (mask == 0 or nm < min_name) {
                    if (mask != 0 and min_name < next) next = min_name;
                    min_name = nm;
                    mask = @as(usize, 1) << @intCast(i);
                } else if (nm == min_name) {
                    mask |= @as(usize, 1) << @intCast(i);
                } else if (nm < next) {
                    next = nm;
                }
            }
            if (mask == 0) break;
            // Highest-indexed (newest) leaf at `min_name` wins its entry.
            const winner: usize = @bitSizeOf(usize) - 1 - @clz(mask);
            if (mask & (mask - 1) == 0) {
                // `min_name` is unique to one leaf: every entry with a name
                // < `next` is too. Bulk-copy that whole run instead of
                // re-scanning all cursors per entry — overlay leaves are
                // typically tiny next to the accumulated base, so runs are
                // long and this skips almost all per-entry scans.
                const s = slices[winner];
                var end = cursors[winner] + 1;
                // Gallop: exponential probe, then binary search for the
                // first entry >= `next`.
                var step: usize = 1;
                while (end + step <= s.len and s[end + step - 1].name < next) {
                    end += step;
                    step *= 2;
                }
                var hi = @min(end + step - 1, s.len);
                while (end < hi) {
                    const mid = end + (hi - end) / 2;
                    if (s[mid].name < next) end = mid + 1 else hi = mid;
                }
                const run = s[cursors[winner]..end];
                @memcpy(dst[out..][0..run.len], run);
                out += run.len;
                cursors[winner] = end;
            } else {
                dst[out] = slices[winner][cursors[winner]];
                out += 1;
                var rest = mask;
                while (rest != 0) {
                    const i = @ctz(rest);
                    cursors[i] += 1;
                    rest &= rest - 1;
                }
            }
        }

        self.releaseAttrsTail(reserved, @intCast(out));
        if (out == 0) if (self.empty_attrs_id) |id| return id;
        const range: AttrRange = .{ .segment = reserved.segment, .offset = reserved.offset, .len = @intCast(out) };
        return self.add(.{ .attrs = .{ .range = range } });
    }

    pub fn getClosure(self: *const ObjectHeap, id: ObjectId) !Closure {
        return switch (self.get(id).*) {
            .closure => |closure| .{
                .chunk_id = closure.chunk_id,
                .upvalues = self.values.slice(closure.upvalues),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getBuiltinClosure(self: *const ObjectHeap, id: ObjectId) !BuiltinClosure {
        return switch (self.get(id).*) {
            .builtin_closure => |closure| .{
                .builtin_id = closure.builtin_id,
                .args = self.values.slice(closure.args),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getPartialApp(self: *const ObjectHeap, id: ObjectId) !PartialApp {
        return switch (self.get(id).*) {
            .partial_app => |pa| .{
                .func = pa.func,
                .args = self.values.slice(pa.args),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getContextString(self: *const ObjectHeap, id: ObjectId) !ContextString {
        return switch (self.get(id).*) {
            .context_string => |string| .{
                .text = string.text,
                .context = self.attrs.slice(string.context),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getThunk(self: *ObjectHeap, id: ObjectId) !*Thunk {
        return switch (self.getMut(id).*) {
            .thunk => |*thunk| thunk,
            else => error.InvalidObjectType,
        };
    }

    /// Skip the tagged-union dispatch when the caller has already
    /// observed `Value.discriminant == .thunk` and can therefore prove
    /// the object slot is a thunk. Address the union payload directly: a
    /// safety-mode `.thunk` projection emits a wide tag-check load which can
    /// overlap the thunk's independently updated atomic fields. The payload of
    /// every Zig union starts at the union address; the caller supplies the
    /// otherwise-generated tag proof.
    pub fn getThunkAssumeValid(self: *ObjectHeap, id: ObjectId) *Thunk {
        return @ptrCast(@alignCast(self.getMut(id)));
    }

    pub fn addList(self: *ObjectHeap, items: []const Value) !ObjectId {
        if (items.len == 0) if (self.empty_list_id) |id| return id;
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

    /// Concatenate already-validated list Values directly into one heap
    /// range. Unlike staging through an ArrayList and then `addList`, every
    /// element is copied exactly once. Empty inputs are identities; if only
    /// one input is non-empty its immutable list object is reused.
    pub fn addConcatenatedListValues(self: *ObjectHeap, lists: []const Value) !ObjectId {
        if (lists.len == 0) return self.addList(&.{});

        var total: usize = 0;
        var non_empty: usize = 0;
        var sole_non_empty: ObjectId = undefined;
        for (lists) |list| {
            std.debug.assert(list.isList());
            const id = list.asObjectId();
            const items = try self.getList(id);
            total = try std.math.add(usize, total, items.len);
            if (items.len != 0) {
                non_empty += 1;
                sole_non_empty = id;
            }
        }
        if (non_empty == 0) return lists[lists.len - 1].asObjectId();
        if (non_empty == 1) return sole_non_empty;

        const range = try self.reserveValuesLocal(@intCast(total));
        const dst = self.values.sliceMut(range);
        var out: usize = 0;
        for (lists) |list| {
            // Re-fetch after reserving: heap storage may have grown or reused
            // a range, while the operand objects remain rooted by the caller.
            const items = try self.getList(list.asObjectId());
            @memcpy(dst[out..][0..items.len], items);
            out += items.len;
        }
        return self.add(.{ .list = range });
    }

    pub fn addAttrs(self: *ObjectHeap, entries: []const AttrEntry) !ObjectId {
        if (entries.len == 0) if (self.empty_attrs_id) |id| return id;
        const range = try self.prepareAttrsRange(entries);
        return self.add(.{ .attrs = .{ .range = range } });
    }

    /// Same as `addAttrs` but the caller guarantees `entries` is already
    /// sorted by `name` and contains no duplicates. Skips the sort and
    /// duplicate-check that `prepareAttrsRange` runs on unsorted input.
    /// Use this from merge-walk style builders (`mergeAttrs`,
    /// `intersectAttrs`) whose output is sorted+unique by construction.
    pub fn addAttrsSorted(self: *ObjectHeap, entries: []const AttrEntry) !ObjectId {
        if (entries.len == 0) if (self.empty_attrs_id) |id| return id;
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
        const range = try self.appendAttrEntries(context);
        errdefer self.attrs.rollback(range);
        self.sortAttrs(range);
        try self.rejectDuplicateAttrs(range);
        return self.add(.{ .context_string = .{ .text = text, .context = range } });
    }

    pub fn addMergedAttrs(self: *ObjectHeap, left_id: ObjectId, right_id: ObjectId) !ObjectId {
        const left = try self.materializeAttrs(left_id);
        const right = try self.materializeAttrs(right_id);

        // Reserve worst-case capacity and write the merge directly into heap
        // storage. Inputs are both sorted and deduplicated, so
        // the in-order walk produces sorted+unique output by
        // construction.
        //
        // Reserve the no-overlap upper bound. Any suffix made unnecessary by
        // duplicate names is returned to the range free list below.
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
        self.releaseAttrsTail(reserved, range.len);
        // Both operands empty (`{} // {}` strict): the tail release above
        // already returned the reserved storage; hand back the shared `{ }`.
        if (range.len == 0 and positions.len == 0) if (self.empty_attrs_id) |id| return id;
        return self.add(.{ .attrs = .{ .range = range, .positions = positions } });
    }

    pub fn addAttrsFromStackPairs(self: *ObjectHeap, pairs: []const Value) !ObjectId {
        return self.addAttrsFromStackPairsImpl(pairs, &.{}, false);
    }

    /// Build an attrset from parallel (names, values): names are compile-time
    /// interned ids in ascending order with no duplicates (the attrs_new_named*
    /// contract); values are the N stack slots. Positions arrive pre-sorted.
    pub fn addAttrsFromValuesSorted(
        self: *ObjectHeap,
        names: []const InternId,
        values: []const Value,
        positions: []const AttrPosEntry,
    ) !ObjectId {
        std.debug.assert(names.len == values.len);
        if (names.len == 0) if (self.empty_attrs_id) |id| return id;
        const range = try self.reserveAttrsLocal(@intCast(names.len));
        const entries = self.attrs.sliceMut(range);
        for (entries, names, values) |*e, n, v| e.* = .{ .name = n, .value = v };
        std.debug.assert(attrEntriesSortedUnique(entries));
        if (positions.len == 0) return self.add(.{ .attrs = .{ .range = range } });
        std.debug.assert(positionsSortedByName(positions));
        const pos_range = try self.appendAttrPositions(positions);
        errdefer self.attr_positions.rollback(pos_range);
        return self.add(.{ .attrs = .{ .range = range, .positions = pos_range } });
    }

    /// `attrs_new_srt` fast path: the compiler guarantees the pairs
    /// are already in ascending interned-name order with no duplicates
    /// (static attrset literals are grouped — duplicates rejected — and
    /// emitted name-sorted at compile time), so the per-construction
    /// sort + duplicate scan is skipped. Debug builds re-verify.
    pub fn addAttrsFromStackPairsSorted(
        self: *ObjectHeap,
        pairs: []const Value,
        positions: []const AttrPosEntry,
    ) !ObjectId {
        return self.addAttrsFromStackPairsImpl(pairs, positions, true);
    }

    fn addAttrsFromStackPairsImpl(
        self: *ObjectHeap,
        pairs: []const Value,
        positions: []const AttrPosEntry,
        comptime presorted: bool,
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
        // Every key was a dynamic `null` (or there were no pairs): `{ }`.
        if (count == 0) if (self.empty_attrs_id) |id| return id;

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

        if (comptime presorted) {
            std.debug.assert(attrEntriesSortedUnique(entries));
        } else {
            self.sortAttrs(range);
            try self.rejectDuplicateAttrs(range);
        }

        if (positions.len == 0) return self.add(.{ .attrs = .{ .range = range } });

        // Positions arrive pre-sorted by name: the only producer is the
        // compiler's `emitBuildAttrs`, which bakes them sorted. No
        // runtime sort needed (findAttrPos binary-searches by name).
        std.debug.assert(positionsSortedByName(positions));
        const pos_range = try self.appendAttrPositions(positions);
        errdefer self.attr_positions.rollback(pos_range);
        return self.add(.{ .attrs = .{ .range = range, .positions = pos_range } });
    }

    fn attrEntriesSortedUnique(entries: []const AttrEntry) bool {
        if (entries.len < 2) return true;
        for (entries[1..], 1..) |entry, i| {
            if (entry.name <= entries[i - 1].name) return false;
        }
        return true;
    }

    fn positionsSortedByName(positions: []const AttrPosEntry) bool {
        if (positions.len < 2) return true;
        for (positions[1..], positions[0 .. positions.len - 1]) |cur, prev| {
            if (cur.name < prev.name) return false;
        }
        return true;
    }

    pub fn addClosure(self: *ObjectHeap, chunk_id: ChunkId, upvalues: []const Value) !ObjectId {
        const range = try self.appendValues(upvalues);
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
        return switch (self.get(id).*) {
            .boxed_int => |v| v,
            else => error.InvalidObjectType,
        };
    }

    pub fn addBytecodeThunk(self: *ObjectHeap, chunk_id: ChunkId, upvalues: []const Value) !ObjectId {
        // Inline-storage thunks (<= inline_capacity upvalues) need no
        // `values`-store allocation — `initBytecode` copies them into the
        // thunk. Only wider captures spill to a stable slice.
        if (upvalues.len <= BytecodeThunk.inline_capacity) {
            return self.add(.{ .thunk = Thunk.initBytecode(chunk_id, upvalues) });
        }
        const range = try self.appendValues(upvalues);
        errdefer self.values.rollback(range);
        return self.add(.{ .thunk = Thunk.initBytecodeSpilled(chunk_id, self.values.slice(range), range.segment, range.offset) });
    }

    /// A deferred-compile thunk (lazy per-attr compilation). Same inline
    /// (<= inline_capacity) vs. spilled-slice storage split as `addBytecodeThunk`.
    pub fn addDeferredThunk(self: *ObjectHeap, deferred_id: u32, env: []const Value) !ObjectId {
        if (env.len <= DeferredThunk.inline_capacity) {
            return self.add(.{ .thunk = Thunk.initDeferred(deferred_id, env) });
        }
        const range = try self.appendValues(env);
        errdefer self.values.rollback(range);
        return self.add(.{ .thunk = Thunk.initDeferredSpilled(deferred_id, self.values.slice(range), range.segment, range.offset) });
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
        const upvalues = self.values.slice(pending.range);
        if (upvalues.len <= BytecodeThunk.inline_capacity)
            return self.add(.{ .thunk = Thunk.initBytecode(pending.chunk_id, upvalues) });
        return self.add(.{ .thunk = Thunk.initBytecodeSpilled(pending.chunk_id, upvalues, pending.range.segment, pending.range.offset) });
    }

    /// Return a thunk target's spilled captures once evaluation has unwound
    /// and the caller is about to overwrite the target with a result/error.
    /// The running worker owns this shard; collections only touch it while all
    /// mutators are stopped, so publication needs no synchronization here.
    pub fn gcReleaseThunkSpill(self: *ObjectHeap, thunk: *const Thunk) void {
        if (!self.collection.root_active) return;
        const range = thunk.targetSpillRange() orelse return;
        const local = self.currentLocal();
        local.gc_free_values.push(self.allocator, range.segment, range.offset, range.len);
    }

    pub fn rollbackBytecodeThunk(self: *ObjectHeap, pending: PendingBytecodeThunk) void {
        self.values.rollback(pending.range);
    }

    fn appendValues(self: *ObjectHeap, items: []const Value) !ValueRange {
        const range = try self.reserveValuesLocal(@intCast(items.len));
        @memcpy(self.values.sliceMut(range), items);
        return range;
    }

    fn appendAttrEntries(self: *ObjectHeap, entries: []const AttrEntry) !AttrRange {
        const range = try self.reserveAttrsLocal(@intCast(entries.len));
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
        if (left_positions.len == 0 and right_positions.len == 0) return empty_attr_positions;

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

        if (merged.items.len == 0) return empty_attr_positions;
        const range = try self.appendAttrPositions(merged.items);
        self.sortAttrPositions(range);
        return range;
    }

    /// Borrow an attrset's source-position entries (empty slice when it
    /// has none or `id` is not an attrset).
    fn attrPositionsSlice(self: *const ObjectHeap, id: ObjectId) []const AttrPosEntry {
        return switch (self.get(id).*) {
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
const gc_poison_name: InternId = std.math.maxInt(InternId) - 7;

inline fn gcAssertNotPoisonName(name: InternId) void {
    if (comptime !gc_debug) return;
    if (name == gc_poison_name) @panic("gc: read poisoned attr name — dangling attr slice held across a collection");
}

fn binarySearchAttrIndex(entries: []const AttrEntry, name: InternId) ?usize {
    // Most compulsory lookups are into tiny attrsets. Spell out the same
    // binary-search decision tree for up to four entries so those searches
    // avoid loop bookkeeping and midpoint arithmetic.
    switch (entries.len) {
        0 => return null,
        1 => {
            const n0 = entries[0].name;
            gcAssertNotPoisonName(n0);
            return if (n0 == name) 0 else null;
        },
        2 => {
            const n1 = entries[1].name;
            gcAssertNotPoisonName(n1);
            if (n1 == name) return 1;
            if (name > n1) return null;
            const n0 = entries[0].name;
            gcAssertNotPoisonName(n0);
            return if (n0 == name) 0 else null;
        },
        3 => {
            const n1 = entries[1].name;
            gcAssertNotPoisonName(n1);
            if (n1 == name) return 1;
            const index: usize = if (name < n1) 0 else 2;
            const candidate = entries[index].name;
            gcAssertNotPoisonName(candidate);
            return if (candidate == name) index else null;
        },
        4 => {
            const n2 = entries[2].name;
            gcAssertNotPoisonName(n2);
            if (n2 == name) return 2;
            if (name > n2) {
                const n3 = entries[3].name;
                gcAssertNotPoisonName(n3);
                return if (n3 == name) 3 else null;
            }
            const n1 = entries[1].name;
            gcAssertNotPoisonName(n1);
            if (n1 == name) return 1;
            if (name > n1) return null;
            const n0 = entries[0].name;
            gcAssertNotPoisonName(n0);
            return if (n0 == name) 0 else null;
        },
        else => {},
    }

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

test "binary attr search covers unrolled tiny sets" {
    const entries = [_]AttrEntry{
        .{ .name = 2, .value = Value.int(2) },
        .{ .name = 4, .value = Value.int(4) },
        .{ .name = 6, .value = Value.int(6) },
        .{ .name = 8, .value = Value.int(8) },
        .{ .name = 10, .value = Value.int(10) },
    };
    const missing = [_]InternId{ 1, 3, 5, 7, 9, 11 };

    for (0..entries.len + 1) |len| {
        for (entries[0..len], 0..) |entry, index|
            try std.testing.expectEqual(index, binarySearchAttrIndex(entries[0..len], entry.name).?);
        for (missing) |name|
            try std.testing.expectEqual(@as(?usize, null), binarySearchAttrIndex(entries[0..len], name));
    }
}

test {
    _ = @import("heap/tests.zig");
}
