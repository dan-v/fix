//! Garbage collector (gated behind `-Dgc`, off by default; zero cost in
//! normal builds). Non-moving, stop-the-world mark-sweep — see
//! docs/gc-plan.md for the architecture (and why moving / refcounting are
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
//! map in docs/gc-plan.md) — and is the reusable marker for the later
//! parallel/concurrent phases.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const heap_mod = @import("heap.zig");
const value_mod = @import("value.zig");
const thunk_mod = @import("thunk.zig");
const types = @import("types.zig");

const ObjectHeap = heap_mod.ObjectHeap;
const Value = value_mod.Value;
const ObjectId = types.ObjectId;
const FutureState = thunk_mod.FutureState;

pub const enabled: bool = build_options.gc;

/// `NO_FLAT` from heap.zig (private there) — a `merge_attrs` whose
/// `flattened` memo equals this has no flattened object to follow.
const NO_FLAT: ObjectId = std.math.maxInt(ObjectId);

/// Live-set tally accumulated by one mark pass: object slots reached, the
/// value/attr/attr-pos store slots they own, and the total live bytes
/// (object slots + owned ranges).
pub const LiveStats = struct {
    objects: u64 = 0,
    values: u64 = 0,
    attrs: u64 = 0,
    attr_pos: u64 = 0,
    bytes: u64 = 0,
};

/// Precise marker over the heap object graph. Holds a mark-bitmap indexed
/// by ObjectId and an explicit work stack (no recursion — the module
/// fixpoint builds graphs far too deep for the native stack). Reused
/// across collections; `reset` grows the bitmap to the current object
/// count and clears it.
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    /// One bit per ObjectId; bit set == marked.
    mark_bits: []u64 = &.{},
    /// Worklist of marked-but-not-yet-scanned objects.
    stack: std.ArrayListUnmanaged(ObjectId) = .empty,
    stats: LiveStats = .{},

    pub fn init(allocator: std.mem.Allocator) Tracer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tracer) void {
        self.allocator.free(self.mark_bits);
        self.stack.deinit(self.allocator);
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

    /// Mark the heap object a Value references, if any. Non-heap Values
    /// (int/float/bool/null/string/path/builtin) are ignored.
    pub fn markValue(self: *Tracer, heap: *const ObjectHeap, v: Value) void {
        if (!hasObjectRef(v)) return;
        self.markObject(heap, v.asObjectId());
    }

    /// Mark `id` for later scanning. Append-only — the caller runs `drain`
    /// once after all roots are marked, so the graph is walked iteratively
    /// (the work stack), never by native recursion.
    pub fn markObject(self: *Tracer, heap: *const ObjectHeap, id: ObjectId) void {
        _ = heap;
        if (!self.testAndSet(id)) return;
        self.stack.append(self.allocator, id) catch return; // OOM: undercount, don't crash
    }

    fn addValues(self: *Tracer, heap: *const ObjectHeap, range: heap_mod.ValueRange) void {
        self.stats.values += range.len;
        self.stats.bytes += @as(u64, range.len) * @sizeOf(Value);
        for (heap.values.slice(range)) |v| self.markValue(heap, v);
    }

    fn addAttrs(self: *Tracer, heap: *const ObjectHeap, range: heap_mod.AttrRange) void {
        self.stats.attrs += range.len;
        self.stats.bytes += @as(u64, range.len) * @sizeOf(heap_mod.AttrEntry);
        for (heap.attrs.slice(range)) |entry| self.markValue(heap, entry.value);
    }

    fn addAttrPos(self: *Tracer, range: heap_mod.AttrPosRange) void {
        self.stats.attr_pos += range.len;
        self.stats.bytes += @as(u64, range.len) * @sizeOf(heap_mod.AttrPosEntry);
    }

    /// Process the work stack until empty: account each object's slot,
    /// follow its outgoing edges (the trace map from docs/gc-plan.md).
    /// Call once after all roots are marked.
    pub fn drain(self: *Tracer, heap: *const ObjectHeap) void {
        while (self.stack.pop()) |id| {
            self.stats.objects += 1;
            self.stats.bytes += @sizeOf(heap_mod.Object);
            const obj = heap.objects.get(id);
            switch (obj.*) {
                .list => |r| self.addValues(heap, r),
                .attrs => |a| {
                    self.addAttrs(heap, a.range);
                    self.addAttrPos(a.positions);
                },
                .merge_attrs => |m| {
                    self.markObject(heap, m.base);
                    self.markObject(heap, m.overlay);
                    const flat = m.flattened.load(.monotonic);
                    if (flat != NO_FLAT) self.markObject(heap, flat);
                },
                .closure => |c| self.addValues(heap, c.upvalues),
                .builtin_closure => |c| self.addValues(heap, c.args),
                .partial_app => |p| {
                    self.markValue(heap, p.func);
                    self.addValues(heap, p.args);
                },
                .context_string => |c| self.addAttrs(heap, c.context),
                .boxed_int => {},
                .thunk => self.markThunk(heap, &obj.thunk),
            }
        }
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

    fn markThunk(self: *Tracer, heap: *const ObjectHeap, t: *const thunk_mod.Thunk) void {
        switch (@as(FutureState, @enumFromInt(t.future.state.load(.monotonic)))) {
            .resolved => self.markValue(heap, t.payload.result),
            // `.errored` reuses the result bits as a `*ErrorInfo` (heap-
            // owned out-of-band, swept separately); `.blackhole` is
            // terminal. Neither holds a Value to follow.
            .errored, .blackhole => {},
            .unresolved, .evaluating => switch (t.future.target_kind) {
                .closure => self.markValue(heap, t.payload.target.closure),
                .pass_through => self.markValue(heap, t.payload.target.pass_through),
                .attr_access => self.markValue(heap, t.payload.target.attr_access.base),
                .bytecode => {
                    const bt = &t.payload.target.bytecode;
                    const ups = bt.upvalues();
                    // Spilled upvalues live in the value store and belong
                    // to this thunk; inline ones are inside the slot.
                    if (bt.upvalue_count > thunk_mod.BytecodeThunk.INLINE_CAP) {
                        self.stats.values += ups.len;
                        self.stats.bytes += @as(u64, ups.len) * @sizeOf(Value);
                    }
                    for (ups) |v| self.markValue(heap, v);
                },
                .deferred => {
                    const dt = &t.payload.target.deferred;
                    const env = dt.env();
                    if (dt.env_count > thunk_mod.DeferredThunk.INLINE_CAP) {
                        self.stats.values += env.len;
                        self.stats.bytes += @as(u64, env.len) * @sizeOf(Value);
                    }
                    for (env) |v| self.markValue(heap, v);
                },
            },
        }
    }
};

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

/// Record one completed collection: objects freed, surviving live bytes,
/// and total reserved bytes (the committed-RSS high-water for this cycle).
pub fn recordCollection(objects_freed: u64, live_bytes: u64, total_after: u64) void {
    if (comptime !enabled) return;
    collections += 1;
    objects_freed_total += objects_freed;
    last_live_bytes = live_bytes;
    if (total_after > peak_total_bytes) peak_total_bytes = total_after;
}

pub fn recordFinalTotal(total: u64) void {
    if (comptime !enabled) return;
    final_total_bytes = total;
    if (total > peak_total_bytes) peak_total_bytes = total;
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

pub fn report() void {
    if (comptime !enabled) return;
    // Diagnostic stderr during `zig build test --listen=-` corrupts the
    // runner (the tjit work hit this). Stay silent under the test runner.
    if (builtin.is_test) return;
    std.debug.print("\n=== GC (-Dgc, stop-the-world mark-sweep, --workers=1) ===\n", .{});
    std.debug.print("collections: {d}\n", .{collections});
    std.debug.print("objects freed (total): {d}\n", .{objects_freed_total});
    std.debug.print("live after last collect: {d:.1} MB\n", .{mb(last_live_bytes)});
    std.debug.print("peak reserved (RSS ceiling held): {d:.1} MB\n", .{mb(peak_total_bytes)});
    std.debug.print("final reserved: {d:.1} MB\n", .{mb(final_total_bytes)});
    if (collections == 0)
        std.debug.print("(no collection — eval stayed under the threshold)\n", .{});
}

test "gc reclaim: sweep frees unreachable objects + ranges, allocator reuses them" {
    if (comptime !enabled) return; // reclaim machinery is `-Dgc`-gated
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap.gcEnableCollect(64 << 20);

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
