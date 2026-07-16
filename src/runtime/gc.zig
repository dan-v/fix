//! Garbage collector. Non-moving, stop-the-world mark-sweep — see
//! docs/plans/gc-plan.md for the architecture (and why moving / refcounting are
//! ruled out, and why the end goal is concurrent SATB).
//!
//! `fix`'s stores are append-only bump allocators, so without reclamation
//! peak RSS tracks *total* allocation, not the *live* set. Phase 0
//! measured ~81% of the nixos_toplevel heap is reclaimable garbage with a
//! stable ~228 MB live plateau. This module provides the marker; the heap
//! (heap.zig) provides the sweep + free lists; the evaluator (eval.zig)
//! drives a collection at a forceThunk safepoint when the byte threshold
//! is crossed. Single-threaded (`--workers=1`) for now.
//!
//! The `Tracer` is precise — it follows exactly the heap edges (the trace
//! map in docs/plans/gc-plan.md) — and is the reusable marker for the later
//! parallel/concurrent phases.

const std = @import("std");
const builtin = @import("builtin");
const containers = @import("base");
const heap_mod = @import("heap.zig");
const value_mod = @import("value.zig");
const thunk_mod = @import("thunk.zig");
const types = @import("types.zig");

const ObjectHeap = heap_mod.ObjectHeap;
const Value = value_mod.Value;
const ObjectId = types.ObjectId;
const FutureState = thunk_mod.FutureState;

/// A `attrs_merge` whose `flattened` memo equals this has no flattened
/// object to follow. Single source of truth in `heap.zig`.
const NO_FLAT: ObjectId = heap_mod.NO_FLAT;

/// Live-set tally accumulated by one mark pass: object slots reached, the
/// value/attr/attr-pos store slots they own, and the total live bytes
/// (object slots + owned ranges).
pub const LiveStats = struct {
    objects: u64 = 0,
    values: u64 = 0,
    attrs: u64 = 0,
    attr_pos: u64 = 0,
    bytes: u64 = 0,

    /// Accumulate another tally (summing per-marker stats after a parallel mark).
    pub fn add(self: *LiveStats, other: LiveStats) void {
        self.objects += other.objects;
        self.values += other.values;
        self.attrs += other.attrs;
        self.attr_pos += other.attr_pos;
        self.bytes += other.bytes;
    }
};

/// Set the mark bit for `id` **atomically** (parallel mark: many markers may
/// race the same object). Returns true iff this call is the one that newly
/// set the bit — the caller then enqueues `id` for scanning, so exactly one
/// marker ever scans a given object. An atomic OR + old-bit test; `.acq_rel`
/// so a marker that loses the race still synchronizes-with the winner's write
/// (the winner will scan the object and mark its children).
fn atomicTestAndSet(mark_bits: []u64, id: ObjectId) bool {
    const word = id >> 6;
    if (word >= mark_bits.len) return false; // allocated after reset
    const mask = @as(u64, 1) << @intCast(id & 63);
    const prev = @atomicRmw(u64, &mark_bits[word], .Or, mask, .acq_rel);
    return prev & mask == 0;
}

/// One parallel marker: a private never-drop worklist (`GrowableDeque` — a
/// dropped element is a swept live object) plus a private `LiveStats` tally
/// (summed after termination; a shared atomic per object would cache-line
/// bounce and erase the parallel win). All markers share the one atomic
/// mark-bitmap (`mark_bits`, aliased from the owning `Tracer`).
///
/// `Marker` doubles as a `scanObject` **sink**: it exposes the same
/// `markValue`/`markObject`/`count*` methods the serial `SerialSink` does, so
/// the single generic edge-walk (`scanObject`) is the ONE place the heap trace
/// map lives — serial and parallel marking can never drift.
pub const Marker = struct {
    deque: containers.GrowableDeque(ObjectId),
    stats: LiveStats = .{},
    /// Shared with every other marker and the Tracer; set in `resetParallel`.
    mark_bits: []u64 = &.{},
    allocator: std.mem.Allocator,
    /// Minor-collection young-gate (set by `resetParallelMinor`): stop the
    /// trace at old objects. Matches `Tracer.minor_gate` for the serial path.
    minor_gate: bool = false,

    inline fn markValue(self: *Marker, heap: *const ObjectHeap, v: Value) void {
        if (hasObjectRef(v)) self.markObject(heap, v.asObjectId());
    }
    inline fn markObject(self: *Marker, heap: *const ObjectHeap, id: ObjectId) void {
        // Minor collection: the trace stops at old objects (their young
        // referents arrive via the remembered set). Same gate as the serial
        // `Tracer.markObject`, so parallel and serial minors agree.
        if (self.minor_gate and !heap.gcIsYoung(id)) return;
        // OOM: undercount rather than crash, matching the serial path. In
        // practice the worklist peaks near the live-set size and never OOMs.
        if (atomicTestAndSet(self.mark_bits, id)) self.deque.push(self.allocator, id) catch {};
    }
    inline fn countObject(self: *Marker) void {
        self.stats.objects += 1;
        self.stats.bytes += @sizeOf(heap_mod.Object);
    }
    inline fn countValues(self: *Marker, n: u64) void {
        self.stats.values += n;
        self.stats.bytes += n * @sizeOf(Value);
    }
    inline fn countAttrs(self: *Marker, n: u64) void {
        self.stats.attrs += n;
        self.stats.bytes += n * @sizeOf(heap_mod.AttrEntry);
    }
    inline fn countAttrPos(self: *Marker, n: u64) void {
        self.stats.attr_pos += n;
        self.stats.bytes += n * @sizeOf(heap_mod.AttrPosEntry);
    }
};

/// Precise marker over the heap object graph. Holds a mark-bitmap indexed
/// by ObjectId and an explicit work stack (no recursion — the module
/// fixpoint builds graphs far too deep for the native stack). Reused
/// across collections; `reset` grows the bitmap to the current object
/// count and clears it.
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    /// One bit per ObjectId; bit set == marked. Shared (aliased) by every
    /// `Marker` in the parallel path; set with `atomicTestAndSet` there.
    mark_bits: []u64 = &.{},
    /// Serial (`--workers=1`) worklist of marked-but-not-yet-scanned objects.
    stack: std.ArrayListUnmanaged(ObjectId) = .empty,
    stats: LiveStats = .{},

    // --- parallel mark (`--workers>1`; see resetParallel/drainParallel) ---
    /// One `Marker` per worker (slot == worker_id). Allocated lazily on the
    /// first parallel collection and reused across collections (deques keep
    /// their grown capacity; `resetParallel` just clears them).
    markers: []Marker = &.{},
    /// Number of markers participating in the current collection (== worker
    /// count). Termination target for `active_idle`.
    marker_count: u32 = 0,
    /// Work-stealing termination counter (HotSpot ParallelTaskTerminator
    /// shape): count of markers currently offering termination. Mark is done
    /// iff this reaches `marker_count` — which can only happen when every
    /// deque is empty and no scan is in flight (a producing marker is active,
    /// hence not offering). Bumped per idle-transition, NOT per object.
    /// INVARIANT: a marker must count itself ACTIVE (retracted) for the entire
    /// window in which it holds or scans stolen work — see `drainParallel`'s
    /// idle loop, which retracts before probing. Scanning while counted idle
    /// would let a peer observe a spurious all-idle and abandon pushed children.
    active_idle: std.atomic.Value(u32) = .init(0),
    /// When non-null, `markObject`/`markValue` seed into this marker's deque
    /// (atomic bitmap) instead of the serial `stack`. Set only by the lone
    /// collector during the single-threaded root-scan (`beginSeeding`), so a
    /// plain field — no concurrency — is safe.
    parallel_seed: ?*Marker = null,
    /// Minor-collection mode (copying nursery): when armed, `markObject` stops
    /// at OLD objects — the mark reaches only the young generation. Old objects
    /// are assumed live; the young objects they reference arrive via the
    /// remembered set (`markRemsetSource`), not by tracing through old.
    minor_gate: bool = false,

    pub fn init(allocator: std.mem.Allocator) Tracer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tracer) void {
        self.allocator.free(self.mark_bits);
        self.stack.deinit(self.allocator);
        for (self.markers) |*m| m.deque.deinit(self.allocator);
        self.allocator.free(self.markers);
    }

    /// Prepare for a fresh mark over `[0, object_count)`: grow + clear the
    /// bitmap, empty the work stack, zero the stats.
    pub fn reset(self: *Tracer, object_count: u32) !void {
        const words = (@as(usize, object_count) + 63) >> 6;
        if (words > self.mark_bits.len) {
            self.mark_bits = try self.allocator.realloc(self.mark_bits, words);
        }
        @memset(self.mark_bits[0..words], 0);
        self.stack.clearRetainingCapacity();
        self.stats = .{};
    }

    /// Set the mark bit for `id`; return true if it was newly set (caller
    /// then pushes it for scanning).
    fn testAndSet(self: *Tracer, id: ObjectId) bool {
        const word = id >> 6;
        if (word >= self.mark_bits.len) return false; // allocated after reset
        const mask = @as(u64, 1) << @intCast(id & 63);
        if (self.mark_bits[word] & mask != 0) return false;
        self.mark_bits[word] |= mask;
        return true;
    }

    /// Is `id` already marked? (Oracle: detect what precise roots missed.)
    pub fn isMarked(self: *const Tracer, id: ObjectId) bool {
        const word = id >> 6;
        if (word >= self.mark_bits.len) return false;
        return self.mark_bits[word] & (@as(u64, 1) << @intCast(id & 63)) != 0;
    }

    /// Mark the heap object a Value references, if any. Non-heap Values
    /// (int/float/bool/null/string/path/builtin) are ignored.
    pub fn markValue(self: *Tracer, heap: *const ObjectHeap, v: Value) void {
        if (!hasObjectRef(v)) return;
        self.markObject(heap, v.asObjectId());
    }

    /// Mark `id` for later scanning. The caller runs `drain`/`drainParallel`
    /// once after all roots are marked, so the graph is walked iteratively
    /// (the worklist), never by native recursion. During a parallel
    /// collection's single-threaded root-scan, `parallel_seed` is set and the
    /// root is seeded into that marker's deque instead of the serial stack.
    pub fn markObject(self: *Tracer, heap: *const ObjectHeap, id: ObjectId) void {
        // Minor collection: the trace stops at old objects (they're live; their
        // young referents come via the remembered set). Young-only keeps the
        // pause proportional to the young survivors, not the whole heap.
        if (self.minor_gate and !heap.gcIsYoung(id)) return;
        if (self.parallel_seed) |m| {
            m.markObject(heap, id);
            return;
        }
        if (!self.testAndSet(id)) return;
        self.stack.append(self.allocator, id) catch return; // OOM: undercount, don't crash
    }

    /// Serial drain (`--workers=1`): process the work stack until empty via the
    /// shared generic edge-walk. `SerialSink` pushes children to `self.stack`
    /// and accumulates into `self.stats`. The trace map itself lives ONCE, in
    /// `scanObject` — serial and parallel marking can never disagree.
    pub fn drain(self: *Tracer, heap: *const ObjectHeap) void {
        var sink = SerialSink{ .tr = self };
        while (self.stack.pop()) |id| scanObject(SerialSink, &sink, heap, id);
    }

    // --- minor collection (copying nursery, young-gated) ---

    /// Prepare a young-gated mark over `[0, object_count)`.
    pub fn resetMinor(self: *Tracer, object_count: u32) !void {
        try self.reset(object_count);
        self.minor_gate = true;
    }

    /// Seed the young referents of a remembered old `source` (an old→young
    /// edge). Scans the source's outgoing edges via the shared trace map;
    /// young children are marked+queued (the gate drops old ones), and the old
    /// source itself is never added to the live set. Call for each remembered
    /// source before `drainMinor`.
    pub fn markRemsetSource(self: *Tracer, heap: *const ObjectHeap, source: ObjectId) void {
        var sink = SerialSink{ .tr = self };
        scanObject(SerialSink, &sink, heap, source);
    }

    /// Drain the young-gated mark to its transitive closure, then disarm the
    /// gate.
    pub fn drainMinor(self: *Tracer, heap: *const ObjectHeap) void {
        self.drain(heap);
        self.minor_gate = false;
    }

    // --- major collection (full, non-gated mark) ---

    /// Prepare a FULL mark over `[0, object_count)`: like `reset`, but also
    /// clears the young-gate (a prior parallel minor may have left it armed) and
    /// the parallel-seed hook, so the serial mark traces the whole graph —
    /// through old objects, not just the young generation.
    pub fn resetMajor(self: *Tracer, object_count: u32) !void {
        try self.reset(object_count);
        self.minor_gate = false;
        self.parallel_seed = null;
    }

    // --- parallel mark ---

    /// Prepare for a parallel mark over `[0, object_count)` with `marker_count`
    /// markers (== worker count). Grows + clears the shared bitmap, (re)sizes
    /// the marker roster reusing deques across collections, clears each deque
    /// and per-marker stats, and resets the termination counter. Call at a
    /// stop-the-world safepoint, before seeding roots.
    pub fn resetParallel(self: *Tracer, object_count: u32, marker_count: u32) !void {
        const words = (@as(usize, object_count) + 63) >> 6;
        if (words > self.mark_bits.len)
            self.mark_bits = try self.allocator.realloc(self.mark_bits, words);
        @memset(self.mark_bits[0..words], 0);
        self.stats = .{};
        // Grow the roster once (worker count is fixed within a run); reuse
        // the deques (with their grown capacity) on later collections.
        if (self.markers.len < marker_count) {
            const old = self.markers.len;
            self.markers = try self.allocator.realloc(self.markers, marker_count);
            for (self.markers[old..]) |*m| m.* = .{
                .deque = try containers.GrowableDeque(ObjectId).init(self.allocator, 1024),
                .allocator = self.allocator,
            };
        }
        for (self.markers[0..marker_count]) |*m| {
            m.deque.clear();
            m.stats = .{};
            m.mark_bits = self.mark_bits;
            // Default to a FULL (non-gated) mark; `resetParallelMinor` re-arms
            // the gate. Without this a parallel major inherits a leftover
            // young-gate from the previous minor and misses old objects.
            m.minor_gate = false;
        }
        self.marker_count = marker_count;
        self.active_idle = .init(0);
        self.parallel_seed = null;
        self.minor_gate = false;
    }

    /// Like `resetParallel` but young-gated (minor collection): the serial
    /// root-seed path (`Tracer.markObject`) and every parallel `Marker` stop the
    /// trace at old objects. Roots + remembered-set seeds reach the young set;
    /// old objects are assumed live.
    pub fn resetParallelMinor(self: *Tracer, object_count: u32, marker_count: u32) !void {
        try self.resetParallel(object_count, marker_count);
        self.minor_gate = true;
        for (self.markers[0..marker_count]) |*m| m.minor_gate = true;
    }

    /// Seed subsequent `markObject`/`markValue` root marks into marker `id`'s
    /// deque (collector-only, single-threaded). Paired with `endSeeding`.
    pub fn beginSeeding(self: *Tracer, id: usize) void {
        self.parallel_seed = &self.markers[id];
    }
    pub fn endSeeding(self: *Tracer) void {
        self.parallel_seed = null;
    }

    /// Parallel marker `id`: drain own deque (LIFO), steal from peers when
    /// empty, and cooperatively detect termination. Returns only when the
    /// whole mark is complete (`active_idle == marker_count`). Safe to run on
    /// every worker concurrently. See the `active_idle` field for the
    /// termination-correctness argument.
    pub fn drainParallel(self: *Tracer, heap: *const ObjectHeap, id: usize) void {
        const me = &self.markers[id];
        while (true) {
            // Phase A: drain everything in our own deque first (LIFO).
            while (me.deque.pop()) |oid| scanObject(Marker, me, heap, oid);
            // Phase B: our deque is empty. Try to steal one item and scan it;
            // if that fails, offer termination. We are still ACTIVE here (not
            // yet counted idle), so scanning the stolen item — which pushes
            // children into our deque — is safe.
            if (self.stealOneAndScan(heap, id)) continue;
            _ = self.active_idle.fetchAdd(1, .acq_rel); // announce idle
            while (true) {
                if (self.active_idle.load(.acquire) == self.marker_count) return; // all done
                // CORRECTNESS: while offering termination we only PEEK peers for
                // work (a non-removing size probe) — we never steal-and-scan
                // here. A scan pushes children; doing it while counted idle let
                // a peer observe `active_idle == marker_count` mid-scan and
                // terminate the whole mark, abandoning those children — a live
                // object left unmarked, then swept by the minor (the w>1 UAF /
                // free-list corruption). On seeing work we RETRACT to active
                // first, then break back to the active steal-and-scan path
                // (Phase B above), so no scan is ever in flight while we're
                // idle. Invariant restored: termination observed ⇒ every deque
                // empty (an idle marker drained its own in Phase A; a non-empty
                // deque belongs to an active, non-offering marker) AND no scan
                // in flight. A stale peek (item stolen before we re-steal) just
                // costs a retract + re-idle; peeking (not stealing) keeps us
                // counted idle so all-idle alignment — hence termination —
                // converges promptly even at high marker counts.
                if (self.anyPeerHasWork(id)) {
                    _ = self.active_idle.fetchSub(1, .acq_rel); // retract to active
                    break; // re-enter Phase A/B and steal-and-scan while active
                }
                std.atomic.spinLoopHint();
            }
        }
    }

    /// Steal one object from some peer's deque and scan it into marker `id`'s
    /// own deque. Returns true iff an item was stolen (and scanned). Visits
    /// peers in a rotated order to spread steal contention. Caller must be
    /// counted ACTIVE (not offering termination) — the scan produces work.
    fn stealOneAndScan(self: *Tracer, heap: *const ObjectHeap, id: usize) bool {
        const n = self.marker_count;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const j = (id + k) % n;
            if (self.markers[j].deque.steal()) |oid| {
                scanObject(Marker, &self.markers[id], heap, oid);
                return true;
            }
        }
        return false;
    }

    /// Non-removing probe: does any peer's deque appear to hold stealable work?
    /// Used only by the idle loop to decide whether to retract to active and
    /// re-enter the steal path — it never removes an item, so it cannot leave
    /// unscanned work "in flight" while the marker is counted idle. A false
    /// positive (item gone by the time we re-steal) is harmless; a false
    /// negative (a just-pushed item not yet visible) is safe too, because the
    /// pushing marker is still active and drains its own deque in Phase A.
    fn anyPeerHasWork(self: *Tracer, id: usize) bool {
        const n = self.marker_count;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const j = (id + k) % n;
            if (self.markers[j].deque.approxLen() > 0) return true;
        }
        return false;
    }

    /// Sum the per-marker stats into `self.stats` after a parallel mark
    /// terminates. Call once, single-threaded, before recording/sweeping.
    pub fn sumStats(self: *Tracer) void {
        self.stats = .{};
        for (self.markers[0..self.marker_count]) |*m| self.stats.add(m.stats);
    }

    /// Collect every currently-marked ObjectId (the live set) into a fresh
    /// slice. For the later parallel-mark phase (partition work across
    /// threads). Caller owns the returned memory.
    pub fn collectLiveIds(self: *Tracer, allocator: std.mem.Allocator) ![]ObjectId {
        var list: std.ArrayListUnmanaged(ObjectId) = .empty;
        errdefer list.deinit(allocator);
        try list.ensureTotalCapacity(allocator, self.stats.objects);
        for (self.mark_bits, 0..) |word, wi| {
            var w = word;
            while (w != 0) {
                const bit = @ctz(w);
                list.appendAssumeCapacity(@intCast(wi * 64 + bit));
                w &= w - 1;
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

/// Serial-mark sink (`--workers=1`): the `scanObject` counterpart of `Marker`.
/// Pushes children to the Tracer's `stack` (plain, non-atomic `testAndSet`)
/// and accumulates into the Tracer's `stats`. Same method surface as `Marker`
/// so the one generic edge-walk drives both.
const SerialSink = struct {
    tr: *Tracer,

    inline fn markValue(self: *SerialSink, heap: *const ObjectHeap, v: Value) void {
        self.tr.markValue(heap, v);
    }
    inline fn markObject(self: *SerialSink, heap: *const ObjectHeap, id: ObjectId) void {
        self.tr.markObject(heap, id);
    }
    inline fn countObject(self: *SerialSink) void {
        self.tr.stats.objects += 1;
        self.tr.stats.bytes += @sizeOf(heap_mod.Object);
    }
    inline fn countValues(self: *SerialSink, n: u64) void {
        self.tr.stats.values += n;
        self.tr.stats.bytes += n * @sizeOf(Value);
    }
    inline fn countAttrs(self: *SerialSink, n: u64) void {
        self.tr.stats.attrs += n;
        self.tr.stats.bytes += n * @sizeOf(heap_mod.AttrEntry);
    }
    inline fn countAttrPos(self: *SerialSink, n: u64) void {
        self.tr.stats.attr_pos += n;
        self.tr.stats.bytes += n * @sizeOf(heap_mod.AttrPosEntry);
    }
};

// --- the trace map (edge-walk), written exactly once ---
//
// `scanObject` and its helpers are generic over the `Sink` (`SerialSink` or
// `Marker`), so the mapping from each heap object to its outgoing edges — the
// GC correctness invariant — has a single source of truth. A missed edge here
// is a swept live object (use-after-free) at BOTH --workers=1 and --workers>1,
// so both mark paths always agree by construction. See docs/plans/gc-plan.md.

/// Account object `id`'s slot and follow its outgoing edges via `sink`.
fn scanObject(comptime Sink: type, sink: *Sink, heap: *const ObjectHeap, id: ObjectId) void {
    sink.countObject();
    const obj = heap.objects.get(id);
    switch (obj.*) {
        .list => |r| scanValues(Sink, sink, heap, r),
        .attrs => |a| {
            scanAttrs(Sink, sink, heap, a.range);
            sink.countAttrPos(a.positions.len);
        },
        .merge_attrs => |m| {
            sink.markObject(heap, m.base);
            sink.markObject(heap, m.overlay);
            const flat = m.flattened.load(.monotonic);
            if (flat != NO_FLAT) sink.markObject(heap, flat);
        },
        .closure => |c| scanValues(Sink, sink, heap, c.upvalues),
        .builtin_closure => |c| scanValues(Sink, sink, heap, c.args),
        .partial_app => |p| {
            sink.markValue(heap, p.func);
            scanValues(Sink, sink, heap, p.args);
        },
        .context_string => |c| scanAttrs(Sink, sink, heap, c.context),
        .boxed_int => {},
        .thunk => scanThunk(Sink, sink, heap, &obj.thunk),
    }
}

fn scanValues(comptime Sink: type, sink: *Sink, heap: *const ObjectHeap, range: heap_mod.ValueRange) void {
    sink.countValues(range.len);
    for (heap.values.slice(range)) |v| sink.markValue(heap, v);
}

fn scanAttrs(comptime Sink: type, sink: *Sink, heap: *const ObjectHeap, range: heap_mod.AttrRange) void {
    sink.countAttrs(range.len);
    for (heap.attrs.slice(range)) |entry| sink.markValue(heap, entry.value);
}

fn scanThunk(comptime Sink: type, sink: *Sink, heap: *const ObjectHeap, t: *const thunk_mod.Thunk) void {
    switch (@as(FutureState, @enumFromInt(t.future.state.load(.monotonic)))) {
        .resolved => sink.markValue(heap, t.payload.result),
        // `.errored` reuses the result bits as a `*ErrorInfo` (heap-owned
        // out-of-band, swept separately); `.blackhole` is terminal. Neither
        // holds a Value to follow.
        .errored, .blackhole => {},
        .unresolved, .evaluating => switch (t.future.target_kind) {
            .closure => sink.markValue(heap, t.payload.target.closure),
            .pass_through => sink.markValue(heap, t.payload.target.pass_through),
            .attr_access => sink.markValue(heap, t.payload.target.attr_access.base),
            .bytecode => {
                const bt = &t.payload.target.bytecode;
                const ups = bt.upvalues();
                // Spilled upvalues live in the value store and belong to this
                // thunk; inline ones are inside the slot.
                if (bt.upvalue_count > thunk_mod.BytecodeThunk.INLINE_CAP)
                    sink.countValues(ups.len);
                for (ups) |v| sink.markValue(heap, v);
            },
            .deferred => {
                const dt = &t.payload.target.deferred;
                const env = dt.env();
                if (dt.env_count > thunk_mod.DeferredThunk.INLINE_CAP)
                    sink.countValues(env.len);
                for (env) |v| sink.markValue(heap, v);
            },
        },
    }
}

/// Does this Value carry a heap ObjectId a marker must follow?
pub inline fn hasObjectRef(v: Value) bool {
    return v.isList() or v.isAttrs() or v.isThunk() or v.isClosure() or
        v.isBuiltinClosure() or v.isContextString() or v.isBoxedInt() or
        v.isPartialApp();
}

// --- collection stats (global; single-threaded for now) ---

var collections: u64 = 0;
var objects_freed_total: u64 = 0;
var last_live_bytes: u64 = 0;
var peak_total_bytes: u64 = 0;
var final_total_bytes: u64 = 0;
var mark_ns_total: u64 = 0;
var sweep_ns_total: u64 = 0;
/// Wall time the collector spends in the STW barrier NOT marking/sweeping:
/// waiting for every worker to reach a safepoint (time-to-safepoint) plus the
/// post-collection release handshake. At --workers>1 this busy-spins, so it is
/// the dominant cost of a w>1 collection — see docs/plans/gc-parallel-mark-plan.md.
var barrier_ns_total: u64 = 0;

/// Monotonic nanosecond clock for GC timing (collector + barrier).
pub fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub const Breakdown = struct {
    obj_live: u64,
    obj_reserved: u64,
    val_live: u64,
    val_reserved: u64,
    attr_live: u64,
    attr_reserved: u64,
};
var last_breakdown: Breakdown = std.mem.zeroes(Breakdown);

pub fn recordTiming(mark_ns: u64, sweep_ns: u64) void {
    mark_ns_total += mark_ns;
    sweep_ns_total += sweep_ns;
}

// Mark-phase breakdown (w=1 serial path): bitmap reset / root scan /
// remembered-set seeding / transitive drain. Answers "where does the
// pause go" without a profiler run.
var reset_ns_total: u64 = 0;
var roots_ns_total: u64 = 0;
var remset_ns_total: u64 = 0;
var drain_ns_total: u64 = 0;
var remset_sources_total: u64 = 0;

pub fn recordMarkPhases(reset_ns: u64, roots_ns: u64, remset_ns: u64, drain_ns: u64, remset_sources: u64) void {
    reset_ns_total += reset_ns;
    roots_ns_total += roots_ns;
    remset_ns_total += remset_ns;
    drain_ns_total += drain_ns;
    remset_sources_total += remset_sources;
}

/// Record barrier wall time (time-to-safepoint + release) for one collection.
pub fn recordBarrier(ns: u64) void {
    barrier_ns_total += ns;
}

pub fn recordBreakdown(b: Breakdown) void {
    last_breakdown = b;
}

/// Record one completed collection: objects freed, surviving live bytes,
/// and total reserved bytes (the committed-RSS high-water for this cycle).
pub fn recordCollection(objects_freed: u64, live_bytes: u64, total_after: u64) void {
    collections += 1;
    objects_freed_total += objects_freed;
    last_live_bytes = live_bytes;
    if (total_after > peak_total_bytes) peak_total_bytes = total_after;
}

/// Live collector counters for the progress indicator: how many collections
/// have run, the surviving live bytes after the last one, and the cumulative
/// objects freed. Cheap (plain global loads); all zero in a build that never
/// collects. See `observ/progress.zig`.
pub const LiveReport = struct {
    collections: u64,
    live_bytes: u64,
    freed_objects: u64,
};

pub fn liveReport() LiveReport {
    return .{
        .collections = collections,
        .live_bytes = last_live_bytes,
        .freed_objects = objects_freed_total,
    };
}

pub fn recordFinalTotal(total: u64) void {
    final_total_bytes = total;
    if (total > peak_total_bytes) peak_total_bytes = total;
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn pct(live: u64, reserved: u64) f64 {
    if (reserved == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(live)) / @as(f64, @floatFromInt(reserved));
}

/// Peak resident set size in bytes (kernel high-water, never decreases).
pub fn peakRssBytes() u64 {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: u64 = @intCast(ru.maxrss);
    // ru_maxrss units differ by OS: KiB on Linux/BSD, bytes on Darwin.
    return if (comptime builtin.os.tag.isDarwin()) maxrss else maxrss * 1024;
}

// Hugetlb-backed bytes are invisible to every kernel RSS figure (ru_maxrss,
// VmRSS/VmHWM, statm) — with `--hugetlb` most of the heap moves off-RSS, so
// any consumer that means "how much memory is this process using" must use
// the footprint variants below, which fold in the hugetlb byte tracking
// from base/hugetlb.zig. (The GC budget itself is immune: it gates on
// `ObjectHeap.totalReservedBytes()`, internal slot counting.)

/// `currentRssBytes` + currently mapped hugetlb bytes.
pub fn currentFootprintBytes() u64 {
    return currentRssBytes() + containers.hugetlb.mappedBytes();
}

/// `peakRssBytes` + the hugetlb high-water. The two peaks need not have
/// coincided in time, so this can overshoot slightly — acceptable for the
/// reporting consumers (a truthful lower bound is impossible post-hoc).
pub fn peakFootprintBytes() u64 {
    return peakRssBytes() + containers.hugetlb.peakMappedBytes();
}

/// Current resident set size in bytes, read from /proc/self/statm (field 2
/// = resident pages). Returns 0 if unavailable.
///
/// Linux-only via procfs. On Darwin a precise current RSS needs mach
/// `task_info(TASK_BASIC_INFO)` (libc/mach, not wired here), so we fall back
/// to the peak high-water — an over-approximation, but keeps footprint
/// reporting meaningful rather than zero. Other OSes report 0.
pub fn currentRssBytes() u64 {
    if (comptime builtin.os.tag != .linux) {
        return if (comptime builtin.os.tag.isDarwin()) peakRssBytes() else 0;
    }
    var buf: [128]u8 = undefined;
    const linux = std.os.linux;
    const fd_raw = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_raw)));
    if (fd < 0) return 0;
    defer _ = linux.close(fd);
    const n = linux.read(fd, &buf, buf.len);
    const rd: isize = @bitCast(n);
    if (rd <= 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(rd)], ' ');
    _ = it.next() orelse return 0; // total program size
    const resident = it.next() orelse return 0;
    const pages = std.fmt.parseInt(u64, resident, 10) catch return 0;
    return pages * std.heap.pageSize();
}

pub fn report() void {
    // Diagnostic stderr during `zig build test --listen=-` corrupts the
    // runner. Stay silent under the test runner.
    if (builtin.is_test) return;
    std.debug.print("\n=== GC (stop-the-world mark-sweep; parallel mark at --workers>1) ===\n", .{});
    std.debug.print("memory budget (reserved-bytes ceiling): {d:.1} MB\n", .{mb(heap_mod.ObjectHeap.gc_budget_bytes)});
    std.debug.print("collections: {d}\n", .{collections});
    std.debug.print("objects freed (total): {d}\n", .{objects_freed_total});
    std.debug.print("live after last collect: {d:.1} MB\n", .{mb(last_live_bytes)});
    std.debug.print("peak reserved (RSS ceiling held): {d:.1} MB\n", .{mb(peak_total_bytes)});
    std.debug.print("final reserved: {d:.1} MB\n", .{mb(final_total_bytes)});
    std.debug.print("mark time (total): {d:.1} ms\n", .{@as(f64, @floatFromInt(mark_ns_total)) / 1e6});
    if (drain_ns_total > 0)
        std.debug.print("  mark phases: reset {d:.1} / roots {d:.1} / remset {d:.1} ms ({d} sources) / drain {d:.1} ms\n", .{
            @as(f64, @floatFromInt(reset_ns_total)) / 1e6,
            @as(f64, @floatFromInt(roots_ns_total)) / 1e6,
            @as(f64, @floatFromInt(remset_ns_total)) / 1e6,
            remset_sources_total,
            @as(f64, @floatFromInt(drain_ns_total)) / 1e6,
        });
    std.debug.print("sweep time (total): {d:.1} ms\n", .{@as(f64, @floatFromInt(sweep_ns_total)) / 1e6});
    std.debug.print("barrier wait (total, w>1 spin): {d:.1} ms\n", .{@as(f64, @floatFromInt(barrier_ns_total)) / 1e6});
    std.debug.print("peak RSS (kernel high-water): {d:.1} MB\n", .{mb(peakRssBytes())});
    std.debug.print("current RSS (end of eval): {d:.1} MB\n", .{mb(currentRssBytes())});
    if (containers.hugetlb.peakMappedBytes() > 0)
        std.debug.print("hugetlb mapped (now / peak): {d:.1} / {d:.1} MB (excluded from RSS lines above)\n", .{
            mb(containers.hugetlb.mappedBytes()), mb(containers.hugetlb.peakMappedBytes()),
        });
    const b = last_breakdown;
    std.debug.print("last-collect per-store (live / reserved):\n", .{});
    std.debug.print("  objects: {d} / {d} ({d:.0}% live)\n", .{ b.obj_live, b.obj_reserved, pct(b.obj_live, b.obj_reserved) });
    std.debug.print("  values:  {d} / {d} ({d:.0}% live)\n", .{ b.val_live, b.val_reserved, pct(b.val_live, b.val_reserved) });
    std.debug.print("  attrs:   {d} / {d} ({d:.0}% live)\n", .{ b.attr_live, b.attr_reserved, pct(b.attr_live, b.attr_reserved) });
    if (collections == 0)
        std.debug.print("(no collection — eval stayed under the threshold)\n", .{});
}

test "gc reclaim: sweep frees unreachable objects + ranges, allocator reuses them" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_mod.heap_gc.enableCollect(&heap, 64 << 20, 0);

    // Live tree: outer list -> inner list. Garbage: two unreferenced lists.
    const inner = try heap.addList(&.{ Value.int(1), Value.int(2), Value.int(3) });
    const outer = try heap.addList(&.{Value.list(inner)});
    const g1 = try heap.addList(&.{ Value.int(7), Value.int(8), Value.int(9) }); // same len as inner
    const g2 = try heap.addList(&.{Value.int(42)});
    _ = g1;
    _ = g2;
    const count_before = heap.objects.count();

    // Mark from the single root `outer`; inner must survive transitively.
    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(outer));
    tr.drain(&heap);
    try std.testing.expectEqual(@as(u64, 2), tr.stats.objects); // outer + inner live

    const st = heap.sweep(tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 2), st.objects_freed); // g1 + g2 dead

    // Live objects survive intact.
    try std.testing.expectEqual(@as(usize, 1), try heap.getListLen(outer));
    try std.testing.expectEqual(@as(usize, 3), try heap.getListLen(inner));
    try std.testing.expectEqual(@as(i64, 2), (try heap.getListItem(inner, 1)).asInt());

    // A new len-3 list reuses g1's freed value range + a freed object slot,
    // so neither the object store nor the value store grows.
    const values_before = heap.values.count();
    const reused = try heap.addList(&.{ Value.int(100), Value.int(200), Value.int(300) });
    try std.testing.expectEqual(count_before, heap.objects.count()); // slot reused
    try std.testing.expectEqual(values_before, heap.values.count()); // value range reused
    try std.testing.expectEqual(@as(i64, 200), (try heap.getListItem(reused, 1)).asInt());
}

test "tracer collectLiveIds returns exactly the marked set" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();

    // Reachable (from root `outer`): outer -> inner. Unreachable: loose_a, loose_b.
    const inner = try heap.addList(&.{ Value.int(1), Value.int(2) });
    const outer = try heap.addList(&.{Value.list(inner)});
    const loose_a = try heap.addList(&.{Value.int(3)});
    const loose_b = try heap.addList(&.{Value.int(4)});

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(outer));
    tr.drain(&heap);

    const live_ids = try tr.collectLiveIds(allocator);
    defer allocator.free(live_ids);

    try std.testing.expectEqual(@as(usize, 2), live_ids.len);
    var saw_outer = false;
    var saw_inner = false;
    for (live_ids) |id| {
        if (id == outer) saw_outer = true;
        if (id == inner) saw_inner = true;
    }
    try std.testing.expect(saw_outer);
    try std.testing.expect(saw_inner);
    try std.testing.expect(!tr.isMarked(loose_a));
    try std.testing.expect(!tr.isMarked(loose_b));
}

test "tracer markObject ignores objects outside the reset range" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();

    const a = try heap.addList(&.{Value.int(1)});

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    // Reset to a bitmap covering zero objects, then mark an id past it —
    // markObject/testAndSet must not go out of bounds.
    try tr.reset(0);
    tr.markObject(&heap, a);
    try std.testing.expect(!tr.isMarked(a));

    const live_ids = try tr.collectLiveIds(allocator);
    defer allocator.free(live_ids);
    try std.testing.expectEqual(@as(usize, 0), live_ids.len);
}

test "tracer: parallel mark reaches exactly the live set (K markers, stealing)" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();

    // Wide + deep graph so stealing is actually exercised: a root list of C
    // chain-heads, each chain a depth-D spine of 1-element lists. All objects
    // are distinct (append-only store), so the live set is exactly C*D + 1.
    const C = 512;
    const D = 8;
    var heads: [C]Value = undefined;
    for (&heads) |*h| {
        var node = try heap.addList(&.{Value.int(0)}); // innermost (1 object)
        var d: usize = 1;
        while (d < D) : (d += 1) node = try heap.addList(&.{Value.list(node)});
        h.* = Value.list(node);
    }
    const root = try heap.addList(&heads);
    const live_expected: u64 = @as(u64, C) * D + 1;

    // Garbage the mark must NOT reach.
    const g1 = try heap.addList(&.{Value.int(1)});
    const g2 = try heap.addList(&.{ Value.int(2), Value.int(3) });

    const Worker = struct {
        fn drain(tr: *Tracer, h: *const ObjectHeap, id: usize) void {
            tr.drainParallel(h, id);
        }
    };

    var tr = Tracer.init(allocator);
    defer tr.deinit();

    const K = 4;
    // Repeat: a parallel-mark data race is rare, so hammer it.
    var iter: usize = 0;
    while (iter < 50) : (iter += 1) {
        try tr.resetParallel(heap.objects.count(), K);
        // Seed the single root into marker 0; stealing spreads the rest.
        tr.beginSeeding(0);
        tr.markValue(&heap, Value.list(root));
        tr.endSeeding();

        var threads: [K]std.Thread = undefined;
        for (&threads, 0..) |*th, id|
            th.* = try std.Thread.spawn(.{}, Worker.drain, .{ &tr, &heap, id });
        for (&threads) |th| th.join();

        tr.sumStats();
        try std.testing.expectEqual(live_expected, tr.stats.objects);
        try std.testing.expect(tr.isMarked(root));
        try std.testing.expect(!tr.isMarked(g1));
        try std.testing.expect(!tr.isMarked(g2));
    }
}

test "gc stat recorders accumulate observable deltas" {
    const timing_before = mark_ns_total;
    const sweep_before = sweep_ns_total;
    recordTiming(100, 50);
    try std.testing.expectEqual(timing_before + 100, mark_ns_total);
    try std.testing.expectEqual(sweep_before + 50, sweep_ns_total);

    const breakdown: Breakdown = .{
        .obj_live = 3,
        .obj_reserved = 10,
        .val_live = 4,
        .val_reserved = 12,
        .attr_live = 5,
        .attr_reserved = 14,
    };
    recordBreakdown(breakdown);
    try std.testing.expectEqual(breakdown, last_breakdown);

    const collections_before = collections;
    const freed_before = objects_freed_total;
    const peak_before = peak_total_bytes;
    recordCollection(7, 1234, peak_before + 999);
    try std.testing.expectEqual(collections_before + 1, collections);
    try std.testing.expectEqual(freed_before + 7, objects_freed_total);
    try std.testing.expectEqual(@as(u64, 1234), last_live_bytes);
    try std.testing.expectEqual(peak_before + 999, peak_total_bytes);

    // A smaller total-after must not lower the running peak.
    recordCollection(0, 1234, peak_before + 1);
    try std.testing.expectEqual(peak_before + 999, peak_total_bytes);

    recordFinalTotal(peak_before + 999);
    try std.testing.expectEqual(peak_before + 999, final_total_bytes);

    // recordFinalTotal also raises the peak if the final total exceeds it.
    recordFinalTotal(peak_before + 2000);
    try std.testing.expectEqual(peak_before + 2000, peak_total_bytes);
    try std.testing.expectEqual(peak_before + 2000, final_total_bytes);
}
