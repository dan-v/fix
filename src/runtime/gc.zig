//! GC Phase 0 — measure, don't reclaim (gated behind `-Dgc`, off by
//! default; zero cost in normal builds). The collector itself is future
//! work; this phase delivers the numbers that pick its architecture
//! (see docs/gc-plan.md): how big is the *live* set vs *total allocated*?
//!
//! `fix`'s stores are append-only bump allocators — nothing is reclaimed
//! during an eval, so peak RSS tracks *total* allocation, not the *live*
//! set. A GC can only ever buy back `allocated − max(live)`. This probe
//! marks the object graph from roots at a periodic safepoint (the object-
//! allocation path, every `SAMPLE_INTERVAL` objects) WITHOUT sweeping,
//! records the high-water of live objects/bytes across the eval, and at
//! exit reports peak-live vs total-allocated — the reclaimable headroom,
//! and the per-collection mark cost (= live-set size).
//!
//! The mark is precise: it follows exactly the heap edges (the same trace
//! map a real collector's marker will use), so the `Tracer` here is the
//! reusable core for Phase 1. Run at `--workers=1`: the driver scans the
//! main worker's fibers only, and the sample runs inline on the lone
//! mutator, so there is no concurrency to race.

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

/// Run a live-set sample once every this many object allocations. ~1M
/// keeps the probe overhead modest (each sample is O(live)) while drawing
/// the live-vs-allocated curve finely enough to catch the high-water.
pub const SAMPLE_INTERVAL: u64 = 1 << 20;

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
/// across samples; `reset` grows the bitmap to the current object count
/// and clears it.
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
        if (word >= self.mark_bits.len) return false; // allocated after reset; out of this sample
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
        self.stack.append(self.allocator, id) catch return; // OOM: undercount, don't crash a probe
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
    /// slice. Used by the parallel-mark microbench to partition work across
    /// threads. Caller owns the returned memory.
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

/// Monotonic nanoseconds (matches the timeline probe's clock — this Zig
/// has no `std.time.Timer`).
pub fn nowNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * std.time.ns_per_s + nsec;
}

/// Does this Value carry a heap ObjectId a marker must follow?
pub inline fn hasObjectRef(v: Value) bool {
    return v.isList() or v.isAttrs() or v.isThunk() or v.isClosure() or
        v.isBuiltinClosure() or v.isContextString() or v.isBoxedInt() or
        v.isPartialApp();
}

/// Total bytes ever reserved across the four stores (the peak-RSS proxy,
/// since nothing is freed). Includes per-worker TLAB over-reservation.
pub const TotalStats = struct {
    objects: u64,
    values: u64,
    attrs: u64,
    attr_pos: u64,
    bytes: u64,
};

pub fn totalStats(heap: *const ObjectHeap) TotalStats {
    const o: u64 = heap.objects.count();
    const v: u64 = heap.values.count();
    const a: u64 = heap.attrs.count();
    const p: u64 = heap.attr_positions.count();
    return .{
        .objects = o,
        .values = v,
        .attrs = a,
        .attr_pos = p,
        .bytes = o * @sizeOf(heap_mod.Object) + v * @sizeOf(Value) +
            a * @sizeOf(heap_mod.AttrEntry) + p * @sizeOf(heap_mod.AttrPosEntry),
    };
}

// --- peak tracking across samples (global; the probe is single-threaded) ---

const Peak = struct {
    samples: u64 = 0,
    /// Live high-water and the totals at the moment it was observed.
    peak_live: LiveStats = .{},
    total_at_peak: TotalStats = .{ .objects = 0, .values = 0, .attrs = 0, .attr_pos = 0, .bytes = 0 },
    /// Final totals (end of eval) — the actual peak RSS with no GC.
    final_total: TotalStats = .{ .objects = 0, .values = 0, .attrs = 0, .attr_pos = 0, .bytes = 0 },
    /// Coarse curve: live-byte fraction of total at each sample (capped).
    curve_total_mb: [CURVE_CAP]u32 = undefined,
    curve_live_mb: [CURVE_CAP]u32 = undefined,
    curve_len: usize = 0,
};

const CURVE_CAP: usize = 64;

var peak: Peak = .{};

/// Record one live-set sample. Updates the high-water by live bytes.
pub fn recordSample(live: LiveStats, total: TotalStats) void {
    if (comptime !enabled) return;
    peak.samples += 1;
    if (live.bytes > peak.peak_live.bytes) {
        peak.peak_live = live;
        peak.total_at_peak = total;
    }
    if (peak.curve_len < CURVE_CAP) {
        peak.curve_total_mb[peak.curve_len] = @intCast(total.bytes >> 20);
        peak.curve_live_mb[peak.curve_len] = @intCast(live.bytes >> 20);
        peak.curve_len += 1;
    }
}

/// Record the final totals at eval end (called once from `deinit`).
pub fn recordFinal(total: TotalStats) void {
    if (comptime !enabled) return;
    peak.final_total = total;
}

// --- parallel-mark scaling microbench (one-shot at end of eval) ---
//
// Marking is a random pointer-chase over the heap → memory-latency-bound.
// This bench answers the architecture question behind parallel-STW mark:
// does dividing the live-object walk across N threads shrink the pause, or
// does it flatten once memory bandwidth saturates? It walks the *known*
// live set (so no work-stealing / mark-bit CAS — those are Phase-3
// overhead on top), measuring the dominant cost: touching every live
// object slot + its owned ranges. A lower bound on a real parallel mark,
// but the SCALING SHAPE (where it flattens) is what decides the model.

const BenchPoint = struct { threads: usize = 0, ns: u64 = 0 };
const MAX_BENCH_POINTS = 8;
var bench_points: [MAX_BENCH_POINTS]BenchPoint = undefined;
var bench_len: usize = 0;
var serial_mark_ns: u64 = 0;
var serial_mark_objects: u64 = 0;

/// Record the timed serial mark at end of eval (the no-parallelism pause).
pub fn recordSerialMark(ns: u64, objects: u64) void {
    if (comptime !enabled) return;
    serial_mark_ns = ns;
    serial_mark_objects = objects;
}

/// Touch one live object the way a marker would: read the slot and its
/// owned ranges. Returns a checksum so the reads aren't optimized away.
fn touchObject(heap: *const ObjectHeap, id: ObjectId) u64 {
    var sum: u64 = id;
    const obj = heap.objects.get(id);
    switch (obj.*) {
        .list => |r| for (heap.values.slice(r)) |v| {
            sum +%= v.bits;
        },
        .attrs => |a| for (heap.attrs.slice(a.range)) |e| {
            sum +%= e.value.bits;
        },
        .merge_attrs => |m| {
            sum +%= m.base;
            sum +%= m.overlay;
        },
        .closure => |c| for (heap.values.slice(c.upvalues)) |v| {
            sum +%= v.bits;
        },
        .builtin_closure => |c| for (heap.values.slice(c.args)) |v| {
            sum +%= v.bits;
        },
        .partial_app => |p| {
            sum +%= p.func.bits;
            for (heap.values.slice(p.args)) |v| sum +%= v.bits;
        },
        .context_string => |c| for (heap.attrs.slice(c.context)) |e| {
            sum +%= e.value.bits;
        },
        .boxed_int => |b| sum +%= @as(u64, @bitCast(b)),
        .thunk => sum +%= obj.thunk.future.state.load(.monotonic),
    }
    return sum;
}

const WalkCtx = struct {
    heap: *const ObjectHeap,
    ids: []const ObjectId,
    out: u64 = 0,
};

fn walkThread(ctx: *WalkCtx) void {
    var sum: u64 = 0;
    for (ctx.ids) |id| sum +%= touchObject(ctx.heap, id);
    ctx.out = sum;
}

/// Run one parallel walk of `ids` across `t` threads; return wall ns
/// (spawn→join). Returns 0 if a thread couldn't spawn (point skipped).
fn runWalk(allocator: std.mem.Allocator, heap: *const ObjectHeap, ids: []const ObjectId, t: usize) u64 {
    const ctxs = allocator.alloc(WalkCtx, t) catch return 0;
    defer allocator.free(ctxs);
    const threads = allocator.alloc(std.Thread, t) catch return 0;
    defer allocator.free(threads);

    const per = (ids.len + t - 1) / t;
    for (0..t) |i| {
        const lo = @min(i * per, ids.len);
        const hi = @min(lo + per, ids.len);
        ctxs[i] = .{ .heap = heap, .ids = ids[lo..hi] };
    }

    const t0 = nowNs();
    var spawned: usize = 0;
    for (1..t) |i| {
        threads[i] = std.Thread.spawn(.{}, walkThread, .{&ctxs[i]}) catch break;
        spawned += 1;
    }
    walkThread(&ctxs[0]); // this thread takes chunk 0
    for (1..1 + spawned) |i| threads[i].join();
    const ns = nowNs() - t0;
    if (spawned + 1 < t) return 0; // partial spawn — discard this point

    var blackhole: u64 = 0;
    for (ctxs) |c| blackhole +%= c.out;
    std.mem.doNotOptimizeAway(blackhole);
    return ns;
}

/// Bench the live-object walk at thread counts 1,2,4,…≤cpus; record best
/// of a few reps per count.
pub fn benchParallelMark(allocator: std.mem.Allocator, heap: *const ObjectHeap, live_ids: []const ObjectId) void {
    if (comptime !enabled) return;
    if (live_ids.len == 0) return;
    // `collectLiveIds` returns ascending ids → a *sequential* store walk,
    // which is bandwidth-efficient at T=1 and understates parallel scaling.
    // A real mark traverses in graph (random) order — latency-bound, which
    // parallelizes better. Shuffle to match that access pattern (fixed seed
    // for reproducibility; this Zig forbids no rng here).
    const ids = allocator.dupe(ObjectId, live_ids) catch return;
    defer allocator.free(ids);
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    prng.random().shuffle(ObjectId, ids);
    const live_ids_shuf: []const ObjectId = ids;

    const cpus = std.Thread.getCpuCount() catch 1;
    const counts = [_]usize{ 1, 2, 4, 8, 16, 32 };
    bench_len = 0;
    for (counts) |t| {
        if (t > cpus and t != 1) continue;
        if (bench_len >= MAX_BENCH_POINTS) break;
        var best: u64 = std.math.maxInt(u64);
        for (0..3) |_| {
            const ns = runWalk(allocator, heap, live_ids_shuf, t);
            if (ns != 0 and ns < best) best = ns;
        }
        if (best == std.math.maxInt(u64)) continue;
        bench_points[bench_len] = .{ .threads = t, .ns = best };
        bench_len += 1;
    }
}

fn pct(n: u64, d: u64) f64 {
    if (d == 0) return 0;
    return @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(d));
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

pub fn report() void {
    if (comptime !enabled) return;
    // Diagnostic stderr during `zig build test --listen=-` corrupts the
    // runner (the tjit work hit this); every test's Evaluator teardown
    // would otherwise dump a report. Stay silent under the test runner.
    if (builtin.is_test) return;
    const p = peak;
    std.debug.print("\n=== GC Phase 0: live-set vs total-allocated (reclaimable RSS headroom) ===\n", .{});
    std.debug.print("samples: {d} (every {d} object allocs)\n", .{ p.samples, SAMPLE_INTERVAL });
    if (p.samples == 0) {
        std.debug.print("(eval allocated < one sample interval — too small to measure)\n", .{});
        std.debug.print("final total: {d:.1} MB ({d} objects)\n", .{ mb(p.final_total.bytes), p.final_total.objects });
        return;
    }

    std.debug.print("\nfinal total allocated (= peak RSS with no GC):\n", .{});
    std.debug.print("  {d:.1} MB  objects={d} values={d} attrs={d} attr_pos={d}\n", .{
        mb(p.final_total.bytes), p.final_total.objects, p.final_total.values, p.final_total.attrs, p.final_total.attr_pos,
    });

    std.debug.print("\npeak LIVE set (high-water across eval = the RSS ceiling a GC could hold):\n", .{});
    std.debug.print("  {d:.1} MB  objects={d} values={d} attrs={d} attr_pos={d}\n", .{
        mb(p.peak_live.bytes), p.peak_live.objects, p.peak_live.values, p.peak_live.attrs, p.peak_live.attr_pos,
    });
    std.debug.print("  (total allocated at that moment: {d:.1} MB, {d} objects)\n", .{
        mb(p.total_at_peak.bytes), p.total_at_peak.objects,
    });

    // The headline: how much a GC could reclaim. Compare peak-live to the
    // total at that same moment (the live fraction is what survives) and
    // to final total (the actual peak RSS).
    std.debug.print("\n=> reclaimable headroom:\n", .{});
    std.debug.print("  peak-live is {d:.1}% of total-at-that-moment  (=> {d:.1}% reclaimable then)\n", .{
        pct(p.peak_live.bytes, p.total_at_peak.bytes), 100.0 - pct(p.peak_live.bytes, p.total_at_peak.bytes),
    });
    std.debug.print("  peak-live is {d:.1}% of final-total           (RSS ceiling vs no-GC peak)\n", .{
        pct(p.peak_live.bytes, p.final_total.bytes),
    });
    std.debug.print("  per-collection mark cost ~ peak-live objects = {d} (bound on STW pause length)\n", .{p.peak_live.objects});

    std.debug.print("\nlive-vs-total curve (MB, one point per sample):\n", .{});
    for (0..p.curve_len) |i| {
        const t = p.curve_total_mb[i];
        const l = p.curve_live_mb[i];
        std.debug.print("  [{d:>2}] total={d:>6} MB  live={d:>6} MB  ({d:.0}% live)\n", .{
            i, t, l, if (t == 0) @as(f64, 0) else @as(f64, @floatFromInt(l)) * 100.0 / @as(f64, @floatFromInt(t)),
        });
    }

    if (serial_mark_ns != 0) {
        std.debug.print("\n=== parallel-mark scaling (end-of-eval live set = {d} objects) ===\n", .{serial_mark_objects});
        std.debug.print("serial mark (full discovery): {d:.2} ms  ({d:.0}M objects/sec)\n", .{
            @as(f64, @floatFromInt(serial_mark_ns)) / 1e6,
            if (serial_mark_ns == 0) @as(f64, 0) else @as(f64, @floatFromInt(serial_mark_objects)) / (@as(f64, @floatFromInt(serial_mark_ns)) / 1e3),
        });
        std.debug.print("memory-walk scaling (touch live objects + ranges; excludes stealing/CAS):\n", .{});
        const base_ns: f64 = if (bench_len > 0) @floatFromInt(bench_points[0].ns) else 0;
        for (bench_points[0..bench_len]) |bp| {
            const ns_f: f64 = @floatFromInt(bp.ns);
            std.debug.print("  T={d:>2}: {d:>7.2} ms   {d:>5.1}x speedup\n", .{
                bp.threads, ns_f / 1e6, if (ns_f == 0) @as(f64, 0) else base_ns / ns_f,
            });
        }
        std.debug.print("note: real parallel mark adds work-steal + mark-bit CAS overhead and\n", .{});
        std.debug.print("      contention on shared objects, so the pause is somewhat above this floor.\n", .{});
    }

    std.debug.print("note: run at --workers=1 (driver scans the main worker's fibers only).\n", .{});
}

test "gc reclaim: sweep frees unreachable objects + ranges, allocator reuses them" {
    if (comptime !enabled) return; // reclaim machinery is `-Dgc`-gated
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap.gcEnableCollect();

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

