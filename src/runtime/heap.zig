//! Runtime object heap.
//!
//! Values refer to boxed runtime objects by ObjectId rather than by host
//! pointers. This keeps the value representation position-independent and
//! centralizes object layout behind heap accessors.
//!
//! Thread safety:
//!   - The four backing stores (objects, values, attrs, attr_positions) are
//!     `StableSegments`. Readers are lock-free; writers serialize per-store
//!     on the store's internal `SpinMutex`.
//!   - Mutation of object payloads is restricted to two cases:
//!       * Atomic ops on `*Thunk` state (via `getThunk` -> CAS / release-store).
//!   - The union tag of an object slot is fixed at creation and never changes,
//!     so concurrent readers can pattern-match without synchronization once
//!     they have a published ObjectId.

const std = @import("std");
const types = @import("types.zig");
const stable = @import("stable_segments.zig");
const worker_id_mod = @import("worker_id.zig");
const Value = @import("value.zig").Value;
const Thunk = @import("thunk.zig").Thunk;

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

const ObjectStore = stable.StableSegments(HeapObject, .{ .first_segment_size = 256 });
const ValueStore = stable.StableSegments(Value, .{ .first_segment_size = 1024 });
const AttrStore = stable.StableSegments(AttrEntry, .{ .first_segment_size = 512 });
const AttrPosStore = stable.StableSegments(AttrPosEntry, .{ .first_segment_size = 512 });

pub const ValueRange = ValueStore.Range;
pub const AttrRange = AttrStore.Range;
pub const AttrPosRange = AttrPosStore.Range;

pub const Closure = struct {
    chunk_id: ChunkId,
    upvalues: []const Value,
};

pub const BuiltinClosure = struct {
    builtin_id: u16,
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

const ContextStringObject = struct {
    text: InternId,
    context: AttrRange,
};

pub const Object = union(enum) {
    list: ValueRange,
    attrs: AttrRange,
    closure: ClosureObject,
    builtin_closure: BuiltinClosureObject,
    thunk: Thunk,
    context_string: ContextStringObject,
    /// Heap-boxed full-range i64 for values that don't fit Value's
    /// 48-bit inline int payload. See `runtime/int.zig`.
    boxed_int: i64,
};

pub const ObjectMeta = union(enum) {
    none,
    attr_positions: AttrPosRange,
};

const HeapObject = struct {
    payload: Object,
    meta: ObjectMeta = .none,
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
    errored_infos: std.ArrayListUnmanaged(*@import("thunk.zig").ErrorInfo),
    errored_infos_mu: stable.SpinMutex,

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !ObjectHeap {
        const locals = try allocator.alloc(HeapLocal, @max(worker_count, 1));
        for (locals) |*l| l.* = .{};
        return .{
            .allocator = allocator,
            .objects = .empty,
            .values = .empty,
            .attrs = .empty,
            .attr_positions = .empty,
            .worker_locals = locals,
            .errored_infos = .empty,
            .errored_infos_mu = .{},
        };
    }

    pub fn deinit(self: *ObjectHeap) void {
        self.freeErroredInfos();
        self.allocator.free(self.worker_locals);
        self.attr_positions.deinit(self.allocator);
        self.attrs.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    /// Record a freshly-allocated `ErrorInfo` so `deinit` can release it
    /// without scanning the object store. Called by `Thunk.errored` via
    /// the heap's tracker — see `vm/force.zig`'s `publishThunkFailure`.
    pub fn trackErroredInfo(self: *ObjectHeap, info: *@import("thunk.zig").ErrorInfo) !void {
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
        variant_counts: [7]u32,
        thunk_states: [5]u32,
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
            .variant_counts = [_]u32{0} ** 7,
            .thunk_states = [_]u32{0} ** 5,
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
            const v_index: usize = switch (obj.payload) {
                .list => 0,
                .attrs => 1,
                .closure => 2,
                .builtin_closure => 3,
                .thunk => |t| blk: {
                    const state = t.future.state.load(.acquire);
                    const s_index: usize = @intCast(@min(state, 4));
                    result.thunk_states[s_index] += 1;
                    break :blk 4;
                },
                .context_string => 5,
                .boxed_int => 6,
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

    fn reserveAttrsLocal(self: *ObjectHeap, n: u32) !AttrRange {
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

    pub fn add(self: *ObjectHeap, object: Object) !ObjectId {
        const id = try self.reserveObjectSlot();
        self.fillObjectSlot(id, object, .none);
        return id;
    }

    pub fn addWithMeta(self: *ObjectHeap, object: Object, meta: ObjectMeta) !ObjectId {
        const id = try self.reserveObjectSlot();
        self.fillObjectSlot(id, object, meta);
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
        const id = ObjectStore.globalIdOf(chunk.segment, chunk.cursor);
        chunk.cursor += 1;
        return id;
    }

    pub fn fillObjectSlot(self: *ObjectHeap, id: ObjectId, object: Object, meta: ObjectMeta) void {
        self.objects.getMut(id).* = .{ .payload = object, .meta = meta };
    }

    pub fn get(self: *ObjectHeap, id: ObjectId) *Object {
        return &self.objects.getMut(id).payload;
    }

    pub fn getConst(self: *const ObjectHeap, id: ObjectId) *const Object {
        return &self.objects.get(id).payload;
    }

    pub fn getMeta(self: *const ObjectHeap, id: ObjectId) ObjectMeta {
        return self.objects.get(id).meta;
    }

    pub fn getList(self: *const ObjectHeap, id: ObjectId) ![]const Value {
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

    pub fn getAttrs(self: *const ObjectHeap, id: ObjectId) ![]const AttrEntry {
        return switch (self.getConst(id).*) {
            .attrs => |range| self.attrs.slice(range),
            else => error.InvalidObjectType,
        };
    }

    pub fn getAttrValue(self: *const ObjectHeap, id: ObjectId, name: InternId) !Value {
        const entries = try self.getAttrs(id);
        var lo: usize = 0;
        var hi: usize = entries.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = entries[mid];
            if (entry.name == name) return entry.value;
            if (entry.name < name) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return error.MissingAttribute;
    }

    pub fn getAttrPos(self: *const ObjectHeap, id: ObjectId, name: InternId) ?SourcePos {
        return switch (self.getMeta(id)) {
            .none => null,
            .attr_positions => |range| self.findAttrPos(range, name),
        };
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
        return self.add(.{ .attrs = range });
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
        return self.addWithMeta(.{ .attrs = range }, .{ .attr_positions = pos_range });
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

        var merged = try std.ArrayListUnmanaged(AttrEntry).initCapacity(self.allocator, left.len + right.len);
        defer merged.deinit(self.allocator);

        var left_i: usize = 0;
        var right_i: usize = 0;
        while (left_i < left.len and right_i < right.len) {
            const l = left[left_i];
            const r = right[right_i];
            if (l.name < r.name) {
                merged.appendAssumeCapacity(l);
                left_i += 1;
            } else if (l.name > r.name) {
                merged.appendAssumeCapacity(r);
                right_i += 1;
            } else {
                merged.appendAssumeCapacity(r);
                left_i += 1;
                right_i += 1;
            }
        }
        while (left_i < left.len) : (left_i += 1) merged.appendAssumeCapacity(left[left_i]);
        while (right_i < right.len) : (right_i += 1) merged.appendAssumeCapacity(right[right_i]);

        const meta = try self.mergeAttrPositionMeta(left_id, right_id, right);
        errdefer self.rollbackMeta(meta);

        const range = try self.appendAttrEntries(merged.items);
        errdefer self.attrs.rollback(range);
        self.sortAttrs(range);
        try self.rejectDuplicateAttrs(range);
        return self.addWithMeta(.{ .attrs = range }, meta);
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

        if (positions.len == 0) return self.add(.{ .attrs = range });

        const pos_range = try self.appendAttrPositions(positions);
        errdefer self.attr_positions.rollback(pos_range);
        self.sortAttrPositions(pos_range);
        return self.addWithMeta(.{ .attrs = range }, .{ .attr_positions = pos_range });
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
        const range = try self.appendValues(upvalues);
        errdefer self.values.rollback(range);
        return self.add(.{ .thunk = Thunk.initBytecode(chunk_id, self.values.slice(range)) });
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

    fn rollbackMeta(self: *ObjectHeap, meta: ObjectMeta) void {
        switch (meta) {
            .none => {},
            .attr_positions => |range| self.attr_positions.rollback(range),
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

    fn mergeAttrPositionMeta(
        self: *ObjectHeap,
        left_id: ObjectId,
        right_id: ObjectId,
        right_attrs: []const AttrEntry,
    ) !ObjectMeta {
        const left_meta = self.getMeta(left_id);
        const right_meta = self.getMeta(right_id);
        if (left_meta == .none and right_meta == .none) return .none;

        const left_positions = switch (left_meta) {
            .none => &[_]AttrPosEntry{},
            .attr_positions => |range| self.attr_positions.slice(range),
        };
        const right_positions = switch (right_meta) {
            .none => &[_]AttrPosEntry{},
            .attr_positions => |range| self.attr_positions.slice(range),
        };

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

        if (merged.items.len == 0) return .none;
        const range = try self.appendAttrPositions(merged.items);
        self.sortAttrPositions(range);
        return .{ .attr_positions = range };
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
