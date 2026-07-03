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
const gc_debug = build_options.gc and builtin.mode == .ReleaseSafe;
const stable = @import("stable_segments.zig");
const worker_id_mod = @import("worker_id.zig");
const struct_census = @import("struct_census.zig");
const Value = @import("value.zig").Value;
const Thunk = @import("thunk.zig").Thunk;
const BytecodeThunk = @import("thunk.zig").BytecodeThunk;
const DeferredThunk = @import("thunk.zig").DeferredThunk;
const ErrorInfo = @import("thunk.zig").ErrorInfo;

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
const OBJECT_MAX_SLOTS: u32 = 1 << 30;
const ObjectStore = stable.FlatStore(Object, .{ .max_slots = OBJECT_MAX_SLOTS });
const ValueStore = stable.StableSegments(Value, .{ .first_segment_size = 1024 });
const AttrStore = stable.StableSegments(AttrEntry, .{ .first_segment_size = 512 });
const AttrPosStore = stable.StableSegments(AttrPosEntry, .{ .first_segment_size = 512 });

var next_heap_token: std.atomic.Value(u64) = .init(1);

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
const NO_FLAT: ObjectId = std.math.maxInt(ObjectId);

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
};

/// GC Phase 0 sampling hook (gated behind `-Dgc`). The heap can't reach
/// the evaluator's roots, so the evaluator registers a callback the
/// allocation path fires every `gc_sample_interval` object allocations.
/// Type-erased to keep the heap free of an `eval`/`gc` import cycle.
pub const GcHook = struct {
    ctx: *anyopaque,
    sample: *const fn (*anyopaque) void,
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

    fn push(self: *RangeFreeList, allocator: std.mem.Allocator, segment: u32, offset: u32, len: u32) void {
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
    gc_free_objects: if (build_options.gc) std.ArrayListUnmanaged(ObjectId) else void = if (build_options.gc) .empty else {},
    gc_free_values: if (build_options.gc) RangeFreeList else void = if (build_options.gc) .{} else {},
    gc_free_attrs: if (build_options.gc) RangeFreeList else void = if (build_options.gc) .{} else {},
    gc_free_attr_pos: if (build_options.gc) RangeFreeList else void = if (build_options.gc) .{} else {},
    /// Guards free-list reuse pops from concurrent worker allocation paths
    /// (`--workers>1`). Pushes run only during a stop-the-world (single
    /// collector), so it's the alloc-path pops that contend. Uncontended at
    /// `--workers=1`.
    gc_free_mu: if (build_options.gc) stable.SpinMutex else void = if (build_options.gc) .{} else {},

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !ObjectHeap {
        var objects = try ObjectStore.init();
        errdefer objects.deinit(allocator);
        const locals = try allocator.alloc(HeapLocal, @max(worker_count, 1));
        for (locals) |*l| l.* = .{};
        return .{
            .allocator = allocator,
            .objects = objects,
            .values = .empty,
            .attrs = .empty,
            .attr_positions = .empty,
            .worker_locals = locals,
            .errored_infos = .empty,
            .errored_infos_mu = .{},
            .token = next_heap_token.fetchAdd(1, .monotonic),
        };
    }

    pub fn deinit(self: *ObjectHeap) void {
        self.freeErroredInfos();
        if (comptime build_options.gc) {
            self.allocator.free(self.gc_alloc_bits);
            self.gc_free_objects.deinit(self.allocator);
            self.gc_free_values.deinit(self.allocator);
            self.gc_free_attrs.deinit(self.allocator);
            self.gc_free_attr_pos.deinit(self.allocator);
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

    const Store = enum { object, value, attr };
    const SkipSet = struct {
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

    fn collectUnfilled(self: *const ObjectHeap, comptime store: Store) SkipSet {
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

    inline fn currentLocal(self: *ObjectHeap) *HeapLocal {
        return &self.worker_locals[worker_id_mod.current];
    }

    fn reserveValuesLocal(self: *ObjectHeap, n: u32) !ValueRange {
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled and !gc_debug and n > 0) {
                self.gc_free_mu.lock();
                const reused = self.gc_free_values.pop(n);
                self.gc_free_mu.unlock();
                if (reused) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
            }
        }
        const local = self.currentLocal();
        const chunk = &local.value;
        if (chunk.fits(n)) {
            const r = chunk.take(n);
            return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
        }
        if (n > VALUE_CHUNK_SIZE) return self.values.reserve(self.allocator, n);
        const refilled = try self.values.reserve(self.allocator, VALUE_CHUNK_SIZE);
        chunk.segment = refilled.segment;
        chunk.cursor = refilled.offset;
        chunk.end = refilled.offset + refilled.len;
        const r = chunk.take(n);
        return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
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
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled and !gc_debug and n > 0) {
                self.gc_free_mu.lock();
                const reused = self.gc_free_attrs.pop(n);
                self.gc_free_mu.unlock();
                if (reused) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
            }
        }
        const local = self.currentLocal();
        const chunk = &local.attr;
        if (chunk.fits(n)) {
            const r = chunk.take(n);
            return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
        }
        if (n > ATTR_CHUNK_SIZE) return self.attrs.reserve(self.allocator, n);
        const refilled = try self.attrs.reserve(self.allocator, ATTR_CHUNK_SIZE);
        chunk.segment = refilled.segment;
        chunk.cursor = refilled.offset;
        chunk.end = refilled.offset + refilled.len;
        const r = chunk.take(n);
        return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
    }

    fn reserveAttrPositionsLocal(self: *ObjectHeap, n: u32) !AttrPosRange {
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled and !gc_debug and n > 0) {
                self.gc_free_mu.lock();
                const reused = self.gc_free_attr_pos.pop(n);
                self.gc_free_mu.unlock();
                if (reused) |loc| return .{ .segment = loc.segment, .offset = loc.offset, .len = n };
            }
        }
        const local = self.currentLocal();
        const chunk = &local.attr_pos;
        if (chunk.fits(n)) {
            const r = chunk.take(n);
            return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
        }
        if (n > ATTR_POS_CHUNK_SIZE) return self.attr_positions.reserve(self.allocator, n);
        const refilled = try self.attr_positions.reserve(self.allocator, ATTR_POS_CHUNK_SIZE);
        chunk.segment = refilled.segment;
        chunk.cursor = refilled.offset;
        chunk.end = refilled.offset + refilled.len;
        const r = chunk.take(n);
        return .{ .segment = r.segment, .offset = r.offset, .len = r.len };
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
                .list => struct_census.recordAlloc(id, .list),
                .attrs, .merge_attrs => struct_census.recordAlloc(id, .attrs),
                else => {},
            }
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
        if (comptime build_options.gc) {
            // Detector keeps freed slots unused so use-after-free is caught.
            if (self.gc_collect_enabled and !gc_debug) {
                self.gc_free_mu.lock();
                const reused = self.gc_free_objects.pop();
                self.gc_free_mu.unlock();
                if (reused) |id| return id;
            }
        }
        const local = self.currentLocal();
        const chunk = &local.object;
        if (chunk.cursor < chunk.end) {
            const id = ObjectStore.globalIdOf(chunk.segment, chunk.cursor);
            chunk.cursor += 1;
            return id;
        }
        const refilled = try self.objects.reserve(self.allocator, OBJECT_CHUNK_SIZE);
        chunk.segment = refilled.segment;
        chunk.cursor = refilled.offset;
        chunk.end = refilled.offset + refilled.len;
        // GC threshold check lives here on the chunk-refill slow path (once
        // per OBJECT_CHUNK_SIZE allocs), never on the per-alloc fast path.
        // While the heap is growing (free lists empty) every chunk refills,
        // so the byte threshold is sampled finely; once collecting starts
        // and slots are reused, refills — and this check — go quiet.
        if (comptime build_options.gc) {
            if (self.gc_collect_enabled and !self.gc_collect_requested and
                self.totalReservedBytes() > self.gc_threshold_bytes)
            {
                self.gc_collect_requested = true;
            }
        }
        const id = ObjectStore.globalIdOf(chunk.segment, chunk.cursor);
        chunk.cursor += 1;
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
    pub const GC_MIN_THRESHOLD: u64 = 64 << 20;
    /// Headroom of genuinely-fresh committed pages between collections
    /// (additive, anchored to the cursor at last collect — see
    /// `gcAfterCollect`). Keeps peak RSS near live + a constant.
    pub const GC_HEADROOM: u64 = 32 << 20;

    /// Validation knob (`FIX_GC_STEP_MB`, `-Dgc` only): when > 0, collect
    /// every this-many MB of fresh allocation instead of the normal additive-
    /// headroom policy. Drives many collections so the detector exercises
    /// every builtin loop. 0 = normal policy. Set from the evaluator (which
    /// owns the env map) via the `step_bytes` arg to `gcEnableCollect`.
    var gc_step_bytes: u64 = 0;

    /// Turn on reclaim (alloc-bitmap maintenance + free-list reuse +
    /// sweep) with an initial threshold. The evaluator calls this only at
    /// `--workers=1` (alloc-bitmap maintenance isn't yet thread-safe).
    pub fn gcEnableCollect(self: *ObjectHeap, initial_threshold: u64, step_bytes: u64) void {
        if (comptime !build_options.gc) return;
        self.gc_collect_enabled = true;
        gc_step_bytes = step_bytes;
        self.gc_threshold_bytes = if (gc_step_bytes > 0)
            self.totalReservedBytes() + gc_step_bytes
        else
            initial_threshold;
        self.gc_track_from = self.objects.count();
        // Detector build: pre-size the alloc bitmap to the whole object id
        // space so the incremental per-fill bit-set never reallocs (which
        // would free the array under a concurrent reader/setter at
        // --workers>1). With a stable array, set uses atomic-or and read uses
        // atomic-load — no lock on the hot detector paths. ~128 MB, debug only.
        if (comptime gc_debug) {
            const words = (@as(usize, OBJECT_MAX_SLOTS) + 63) >> 6;
            self.gc_alloc_bits = self.allocator.realloc(self.gc_alloc_bits, words) catch self.gc_alloc_bits;
            @memset(self.gc_alloc_bits, 0);
        }
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
            @as(u64, self.values.count()) * @sizeOf(Value) +
            @as(u64, self.attrs.count()) * @sizeOf(AttrEntry) +
            @as(u64, self.attr_positions.count()) * @sizeOf(AttrPosEntry);
    }

    pub fn gcCollectRequested(self: *const ObjectHeap) bool {
        if (comptime !build_options.gc) return false;
        return self.gc_collect_requested;
    }

    /// Run a collection now via the registered callback (the evaluator's
    /// mark+sweep). Caller must be at a safepoint.
    pub fn gcRunCollect(self: *ObjectHeap) void {
        if (comptime !build_options.gc) return;
        if (self.gc_hook) |h| h.sample(h.ctx);
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
    pub fn gcAfterCollect(self: *ObjectHeap, live_bytes: u64) void {
        if (comptime !build_options.gc) return;
        _ = live_bytes;
        self.gc_collect_requested = false;
        self.gc_threshold_bytes = if (gc_step_bytes > 0)
            self.totalReservedBytes() + gc_step_bytes
        else
            @max(GC_MIN_THRESHOLD, self.totalReservedBytes() + GC_HEADROOM);
        // Invalidate all thread-local caches (thunk memo, attr IC, call IC)
        // that key on `token`: they hold Values weakly (not GC roots), so a
        // swept object could still be reachable through a stale cache slot.
        // A fresh unique token makes every existing slot miss. This is why
        // caches needn't be traced (see docs/plans/gc-plan.md).
        self.token = next_heap_token.fetchAdd(1, .monotonic);
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
        // Exclude slots already on the object free list.
        for (self.gc_free_objects.items) |id| {
            const word = id >> 6;
            if (word < self.gc_alloc_bits.len) self.gc_alloc_bits[word] &= ~(@as(u64, 1) << @intCast(id & 63));
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
        if (comptime gc_debug) self.gcVerifyMarkClosed(mark_bits);
        const n = self.objects.count();
        var id: ObjectId = 0;
        while (id < n) : (id += 1) {
            const word = id >> 6;
            if (word >= self.gc_alloc_bits.len) break;
            const bit = @as(u64, 1) << @intCast(id & 63);
            if (self.gc_alloc_bits[word] & bit == 0) continue; // unfilled / already free
            const marked = word < mark_bits.len and (mark_bits[word] & bit != 0);
            if (marked) continue;
            self.gcFreeObjectRanges(self.objects.get(id));
            self.gc_alloc_bits[word] &= ~bit;
            self.gc_free_objects.append(self.allocator, id) catch {};
            st.objects_freed += 1;
        }
        return st;
    }

    /// Debug: verify the mark is closed — no MARKED object may reference an
    /// unmarked filled object. A violation means the tracer missed an edge
    /// (systematic bug); silence means marking is complete and any swept
    /// object is genuinely unreachable (held only by a Zig local / untracked
    /// root). Prints up to a few violations. STW-only.
    fn gcVerifyMarkClosed(self: *ObjectHeap, mark_bits: []const u64) void {
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
        const n = self.objects.count();
        while (id < n and shown < 8) : (id += 1) {
            if (!marked(mark_bits, self.gc_alloc_bits, id)) continue;
            const obj = self.objects.get(id);
            switch (obj.*) {
                .list => |r| for (self.values.slice(r)) |v| check(self, mark_bits, id, v, &shown),
                .attrs => |a| for (self.attrs.slice(a.range)) |e| check(self, mark_bits, id, e.value, &shown),
                .closure => |c| for (self.values.slice(c.upvalues)) |v| check(self, mark_bits, id, v, &shown),
                .builtin_closure => |c| for (self.values.slice(c.args)) |v| check(self, mark_bits, id, v, &shown),
                .partial_app => |p| {
                    check(self, mark_bits, id, p.func, &shown);
                    for (self.values.slice(p.args)) |v| check(self, mark_bits, id, v, &shown);
                },
                .context_string => |c| for (self.attrs.slice(c.context)) |e| check(self, mark_bits, id, e.value, &shown),
                .merge_attrs => |m| {
                    check(self, mark_bits, id, Value.attrs(m.base), &shown);
                    check(self, mark_bits, id, Value.attrs(m.overlay), &shown);
                },
                .thunk => |*t| {
                    if (@as(@import("thunk.zig").FutureState, @enumFromInt(t.future.state.load(.monotonic))) == .resolved)
                        check(self, mark_bits, id, t.payload.result, &shown);
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
    /// `merge_attrs`/`boxed_int` own no ranges.
    fn gcFreeObjectRanges(self: *ObjectHeap, obj: *const Object) void {
        // Detector: poison the freed range so a dangling raw `getList`/`getAttrs`
        // slice (owner swept while a Zig local held the slice — the class the
        // reuse-off object-read assert can't see) traps on next access instead
        // of silently reading stale-but-valid data. Poison is a thunk to an
        // unallocated id, so forcing/reading a poisoned element hits gcAssertLive.
        if (comptime gc_debug) {
            const poison = Value.thunk(OBJECT_MAX_SLOTS - 1);
            switch (obj.*) {
                .list => |r| for (self.values.sliceMut(r)) |*v| {
                    v.* = poison;
                },
                .attrs => |a| for (self.attrs.sliceMut(a.range)) |*e| {
                    e.value = poison;
                },
                .builtin_closure => |c| for (self.values.sliceMut(c.args)) |*v| {
                    v.* = poison;
                },
                .partial_app => |p| for (self.values.sliceMut(p.args)) |*v| {
                    v.* = poison;
                },
                .context_string => |c| for (self.attrs.sliceMut(c.context)) |*e| {
                    e.value = poison;
                },
                else => {},
            }
        }
        switch (obj.*) {
            .list => |r| if (r.len > 0) self.gc_free_values.push(self.allocator, r.segment, r.offset, r.len),
            .attrs => |a| {
                if (a.range.len > 0) self.gc_free_attrs.push(self.allocator, a.range.segment, a.range.offset, a.range.len);
                if (a.positions.len > 0) self.gc_free_attr_pos.push(self.allocator, a.positions.segment, a.positions.offset, a.positions.len);
            },
            .builtin_closure => |c| if (c.args.len > 0) self.gc_free_values.push(self.allocator, c.args.segment, c.args.offset, c.args.len),
            .partial_app => |p| if (p.args.len > 0) self.gc_free_values.push(self.allocator, p.args.segment, p.args.offset, p.args.len),
            .context_string => |c| if (c.context.len > 0) self.gc_free_attrs.push(self.allocator, c.context.segment, c.context.offset, c.context.len),
            // NOT reclaimed yet: an executing frame aliases its
            // `upvalues` slice, which is owned by the .closure object (or a
            // .thunk's spilled storage). Freeing the range while a frame
            // runs would dangle it. Reclaiming these needs the frame to
            // root its executing closure/thunk (a follow-up RSS opt);
            // until then their ranges leak. `merge_attrs`/`boxed_int` own
            // no reclaimable range.
            .closure, .thunk, .merge_attrs, .boxed_int => {},
        }
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
        const right = try self.getList(right_id);

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
        const range = try self.appendAttrEntries(context);
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
        const range = try self.appendValues(upvalues);
        errdefer self.values.rollback(range);
        return self.add(.{ .thunk = Thunk.initBytecode(chunk_id, self.values.slice(range)) });
    }

    /// A deferred-compile thunk (lazy per-attr compilation). Same inline
    /// (<= INLINE_CAP) vs. spilled-slice storage split as `addBytecodeThunk`.
    pub fn addDeferredThunk(self: *ObjectHeap, deferred_id: u32, env: []const Value) !ObjectId {
        if (env.len <= DeferredThunk.INLINE_CAP) {
            return self.add(.{ .thunk = Thunk.initDeferred(deferred_id, env) });
        }
        const range = try self.appendValues(env);
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

fn binarySearchAttrIndex(entries: []const AttrEntry, name: InternId) ?usize {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry_name = entries[mid].name;
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
