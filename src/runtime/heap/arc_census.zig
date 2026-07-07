//! ARC-feasibility census (`-Darc-census`): exit-time whole-heap object-graph
//! analysis sizing what reference counting could and could not reclaim.
//!
//! Motivation (see docs/plans; ARC = automatic reference counting): pure RC
//! frees an object when its last reference dies, but leaks reference CYCLES.
//! Nix evaluation is suspected to create cycles pervasively (`rec {}`,
//! recursive-let binding cells, the module-system fixpoint, closures capturing
//! their own scope). Before any RC design is entertained we need numbers:
//!
//!   1. Cycle mass — what fraction of objects/bytes sits in reference cycles
//!      (nontrivial SCCs, exact via iterative Tarjan), and what fraction is
//!      reachable FROM a cycle (trial-deletion leftover, via Kahn peeling:
//!      repeatedly delete objects with zero remaining in-heap references —
//!      what survives is exactly what pure RC could never free once all
//!      external/root references are gone).
//!   2. RC traffic — total heap edges (object→object references), the inc/dec
//!      op count a heap-edge-only deferred-RC design would pay, plus the
//!      in-degree distribution (how concentrated references are on a few hot
//!      objects — the atomic-RMW contention exposure at --workers>1).
//!
//! Run at `--workers=1` with `--print-sched-stats`; the census fires at exit
//! (no concurrent writers) and is print-only. In a default (non `-Dgc`) build
//! nothing is ever freed, so the exit heap is the FULL allocation history:
//! exit-edge counts are creation counts minus edges destroyed by thunk
//! resolution (estimated separately below from the unresolved population).
//!
//! Comptime-gated: `enabled == false` compiles this file to nothing.

const std = @import("std");
const build_options = @import("build_options");
const heap_mod = @import("../heap.zig");
const thunk_mod = @import("../thunk.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const Object = heap_mod.Object;
const ObjectId = heap_mod.ObjectId;
const AttrEntry = heap_mod.AttrEntry;
const AttrPosEntry = heap_mod.AttrPosEntry;
const Value = @import("../value.zig").Value;
const FutureState = thunk_mod.FutureState;

pub const enabled: bool = build_options.arc_census;

const VARIANTS = 9;

fn variantIndex(obj: *const Object) usize {
    return switch (obj.*) {
        .list => 0,
        .attrs => 1,
        .closure => 2,
        .builtin_closure => 3,
        .thunk => 4,
        .context_string => 5,
        .boxed_int => 6,
        .merge_attrs => 7,
        .partial_app => 8,
    };
}

/// Bytes owned by this object: its store slot plus its single-owner ranges
/// (see docs/gc.md "single-owner range invariant") plus spilled thunk
/// upvalue/env storage. Matches the accounting the tracing GC frees.
fn ownedBytes(obj: *const Object) u64 {
    var b: u64 = @sizeOf(Object);
    switch (obj.*) {
        .list => |r| b += @as(u64, r.len) * @sizeOf(Value),
        .attrs => |a| {
            b += @as(u64, a.range.len) * @sizeOf(AttrEntry);
            b += @as(u64, a.positions.len) * @sizeOf(AttrPosEntry);
        },
        .closure => |c| b += @as(u64, c.upvalues.len) * @sizeOf(Value),
        .builtin_closure => |c| b += @as(u64, c.args.len) * @sizeOf(Value),
        .partial_app => |p| b += @as(u64, p.args.len) * @sizeOf(Value),
        .context_string => |c| b += @as(u64, c.context.len) * @sizeOf(AttrEntry),
        .thunk => |*t| {
            const s: FutureState = @enumFromInt(t.future.state.load(.monotonic));
            switch (s) {
                .unresolved, .evaluating => switch (t.future.target_kind) {
                    .bytecode => {
                        const n = t.payload.target.bytecode.upvalue_count;
                        if (n > thunk_mod.BytecodeThunk.INLINE_CAP) b += @as(u64, n) * @sizeOf(Value);
                    },
                    .deferred => {
                        const n = t.payload.target.deferred.env_count;
                        if (n > thunk_mod.DeferredThunk.INLINE_CAP) b += @as(u64, n) * @sizeOf(Value);
                    },
                    else => {},
                },
                // Resolved/errored overwrote the target; spilled ranges (if
                // any) are unreachable and uncounted — matches what RC would
                // see (it, too, loses the range at resolve time).
                else => {},
            }
        },
        .merge_attrs, .boxed_int => {},
    }
    return b;
}

/// Enumerate every object→object edge out of `id`. Mirrors the tracing GC's
/// edge map (heap/gc.zig `verifyMinorClosure`), including `merge_attrs`'s
/// memoized `flattened` link. Duplicate edges are reported as-is: each stored
/// Value is one RC increment.
fn forEachEdge(
    heap: *const ObjectHeap,
    obj: *const Object,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), ObjectId) void,
) void {
    const emit = struct {
        fn f(c: @TypeOf(ctx), v: Value) void {
            if (ObjectHeap.gcHeapId(v)) |cid| cb(c, cid);
        }
    }.f;
    switch (obj.*) {
        .list => |r| for (heap.values.slice(r)) |v| emit(ctx, v),
        .attrs => |a| for (heap.attrs.slice(a.range)) |e| emit(ctx, e.value),
        .closure => |c| for (heap.values.slice(c.upvalues)) |v| emit(ctx, v),
        .builtin_closure => |c| for (heap.values.slice(c.args)) |v| emit(ctx, v),
        .partial_app => |p| {
            emit(ctx, p.func);
            for (heap.values.slice(p.args)) |v| emit(ctx, v);
        },
        .context_string => |c| for (heap.attrs.slice(c.context)) |e| emit(ctx, e.value),
        .merge_attrs => |m| {
            cb(ctx, m.base);
            cb(ctx, m.overlay);
            const flat = m.flattened.load(.monotonic);
            if (flat != heap_mod.NO_FLAT) cb(ctx, flat);
        },
        .thunk => |*t| {
            const s: FutureState = @enumFromInt(t.future.state.load(.monotonic));
            switch (s) {
                .resolved => emit(ctx, t.payload.result),
                .errored, .blackhole => {},
                .unresolved, .evaluating => switch (t.future.target_kind) {
                    .closure => emit(ctx, t.payload.target.closure),
                    .pass_through => emit(ctx, t.payload.target.pass_through),
                    .attr_access => emit(ctx, t.payload.target.attr_access.base),
                    .bytecode => for (t.payload.target.bytecode.upvalues()) |v| emit(ctx, v),
                    .deferred => for (t.payload.target.deferred.env()) |v| emit(ctx, v),
                },
            }
        },
        .boxed_int => {},
    }
}

const VariantAgg = struct {
    n: [VARIANTS]u64 = @splat(0),
    bytes: [VARIANTS]u64 = @splat(0),

    fn add(self: *VariantAgg, vi: usize, b: u64) void {
        self.n[vi] += 1;
        self.bytes[vi] += b;
    }

    fn totalN(self: *const VariantAgg) u64 {
        var t: u64 = 0;
        for (self.n) |x| t += x;
        return t;
    }

    fn totalBytes(self: *const VariantAgg) u64 {
        var t: u64 = 0;
        for (self.bytes) |x| t += x;
        return t;
    }
};

fn pct(x: u64, total: u64) f64 {
    return if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(total));
}

fn mb(x: u64) f64 {
    return @as(f64, @floatFromInt(x)) / (1024.0 * 1024.0);
}

pub fn report(heap: *const ObjectHeap) void {
    if (comptime !enabled) return;
    reportImpl(heap) catch |err| {
        std.debug.print("arc-census: FAILED ({s})\n", .{@errorName(err)});
    };
}

fn reportImpl(heap: *const ObjectHeap) !void {
    const a = std.heap.page_allocator;
    const n: u32 = heap.objects.count();
    if (n == 0) return;

    // -- filled bitmap: skip per-worker reserved-but-unfilled TLAB tails ----
    const skip = heap.collectUnfilled(.object);
    const words = (@as(usize, n) + 63) >> 6;
    const filled = try a.alloc(u64, words);
    defer a.free(filled);
    @memset(filled, ~@as(u64, 0));
    // Clear the tail bits beyond n.
    if ((n & 63) != 0) filled[words - 1] = (@as(u64, 1) << @intCast(n & 63)) - 1;
    for (skip.starts[0..skip.len], skip.ends[0..skip.len]) |s, e| {
        var id: u32 = s;
        while (id < e and id < n) : (id += 1) filled[id >> 6] &= ~(@as(u64, 1) << @intCast(id & 63));
    }
    const isFilled = struct {
        fn f(bits: []const u64, id: u32) bool {
            return (bits[id >> 6] >> @intCast(id & 63)) & 1 != 0;
        }
    }.f;

    // -- pass 1: totals, out-degrees (CSR offsets), unresolved-thunk stats --
    var totals: VariantAgg = .{};
    const outdeg = try a.alloc(u32, n);
    defer a.free(outdeg);
    @memset(outdeg, 0);

    var unresolved_thunks: u64 = 0;
    var unresolved_target_edges: u64 = 0;
    var resolved_thunks: u64 = 0;

    const Count = struct {
        c: u32 = 0,
        fn cb(self: *@This(), child: ObjectId) void {
            _ = child;
            self.c += 1;
        }
    };

    var id: u32 = 0;
    while (id < n) : (id += 1) {
        if (!isFilled(filled, id)) continue;
        const obj = heap.objects.get(id);
        const vi = variantIndex(obj);
        totals.add(vi, ownedBytes(obj));
        var cnt: Count = .{};
        forEachEdge(heap, obj, &cnt, Count.cb);
        outdeg[id] = cnt.c;
        if (obj.* == .thunk) {
            const s: FutureState = @enumFromInt(obj.thunk.future.state.load(.monotonic));
            switch (s) {
                .resolved => resolved_thunks += 1,
                .unresolved, .evaluating => {
                    unresolved_thunks += 1;
                    unresolved_target_edges += cnt.c;
                },
                else => {},
            }
        }
    }

    // -- CSR build + in-degrees -------------------------------------------
    var total_edges: u64 = 0;
    const off = try a.alloc(u32, @as(usize, n) + 1);
    defer a.free(off);
    for (outdeg, 0..) |d, i| {
        off[i] = @intCast(total_edges);
        total_edges += d;
    }
    off[n] = @intCast(total_edges);
    const edges = try a.alloc(u32, total_edges);
    defer a.free(edges);
    const indeg = try a.alloc(u32, n);
    defer a.free(indeg);
    @memset(indeg, 0);
    {
        const Fill = struct {
            edges: []u32,
            indeg: []u32,
            cursor: u32,
            self_loop: bool = false,
            src: u32,
            fn cb(self: *@This(), child: ObjectId) void {
                self.edges[self.cursor] = child;
                self.cursor += 1;
                self.indeg[child] += 1;
                if (child == self.src) self.self_loop = true;
            }
        };
        const self_loops = try a.alloc(u64, words);
        defer a.free(self_loops);
        @memset(self_loops, 0);
        id = 0;
        while (id < n) : (id += 1) {
            if (!isFilled(filled, id)) continue;
            var f: Fill = .{ .edges = edges, .indeg = indeg, .cursor = off[id], .src = id };
            forEachEdge(heap, heap.objects.get(id), &f, Fill.cb);
            if (f.self_loop) self_loops[id >> 6] |= @as(u64, 1) << @intCast(id & 63);
        }

        // -- in-degree concentration (RC contention exposure) --------------
        reportInDegree(heap, indeg, total_edges, isFilled, filled);

        // -- Kahn trial deletion: what pure RC frees once roots drop -------
        try reportKahn(heap, a, filled, isFilled, off, edges, indeg, &totals);

        // -- Tarjan SCC: exact cycle membership -----------------------------
        try reportTarjan(heap, a, filled, isFilled, off, edges, self_loops, &totals);
    }

    // -- headline totals + RC op-rate estimate ------------------------------
    const tot_n = totals.totalN();
    const tot_b = totals.totalBytes();
    std.debug.print("arc-census totals: objects={d} bytes={d:.1}MB edges={d} (avg out-degree {d:.2})\n", .{
        tot_n, mb(tot_b), total_edges, if (tot_n == 0) @as(f64, 0) else @as(f64, @floatFromInt(total_edges)) / @as(f64, @floatFromInt(tot_n)),
    });
    for (0..VARIANTS) |vi| {
        if (totals.n[vi] == 0) continue;
        std.debug.print("  variant {s:<16} n={d} ({d:.1}%) bytes={d:.1}MB ({d:.1}%)\n", .{
            ObjectHeap.Stats.variantName(vi), totals.n[vi], pct(totals.n[vi], tot_n), mb(totals.bytes[vi]), pct(totals.bytes[vi], tot_b),
        });
    }
    // Edges destroyed by resolution: each resolved thunk overwrote its target
    // (avg edges estimated from the surviving unresolved population) and
    // wrote one result edge (already counted in exit edges). RC would pay
    // inc at creation + dec at destruction for each.
    const avg_target: f64 = if (unresolved_thunks == 0) 0 else @as(f64, @floatFromInt(unresolved_target_edges)) / @as(f64, @floatFromInt(unresolved_thunks));
    const destroyed_est: u64 = @intFromFloat(avg_target * @as(f64, @floatFromInt(resolved_thunks)));
    const created_est = total_edges + destroyed_est;
    std.debug.print(
        "arc-census rc-ops: exit_edges={d} resolved_thunks={d} unresolved={d} avg_target_edges={d:.2} destroyed_est={d} edges_created_est={d} rc_incdec_est={d}\n",
        .{ total_edges, resolved_thunks, unresolved_thunks, avg_target, destroyed_est, created_est, 2 * created_est },
    );
}

fn reportInDegree(
    heap: *const ObjectHeap,
    indeg: []const u32,
    total_edges: u64,
    comptime isFilled: fn ([]const u64, u32) bool,
    filled: []const u64,
) void {
    // Top-64 by in-degree via a simple min-tracked array (n is millions; K tiny).
    const K = 64;
    var top_ids: [K]u32 = @splat(0);
    var top_deg: [K]u32 = @splat(0);
    for (indeg, 0..) |d, i| {
        if (!isFilled(filled, @intCast(i))) continue;
        // Find the current minimum slot.
        var min_j: usize = 0;
        var min_v: u32 = top_deg[0];
        for (top_deg, 0..) |v, j| {
            if (v < min_v) {
                min_v = v;
                min_j = j;
            }
        }
        if (d > min_v) {
            top_deg[min_j] = d;
            top_ids[min_j] = @intCast(i);
        }
    }
    // Sort the K slots descending (insertion sort, K tiny).
    var i: usize = 1;
    while (i < K) : (i += 1) {
        const dv = top_deg[i];
        const iv = top_ids[i];
        var j = i;
        while (j > 0 and top_deg[j - 1] < dv) : (j -= 1) {
            top_deg[j] = top_deg[j - 1];
            top_ids[j] = top_ids[j - 1];
        }
        top_deg[j] = dv;
        top_ids[j] = iv;
    }
    var top1: u64 = 0;
    var top8: u64 = 0;
    var top64: u64 = 0;
    for (top_deg, 0..) |d, j| {
        if (j < 1) top1 += d;
        if (j < 8) top8 += d;
        top64 += d;
    }
    std.debug.print(
        "arc-census in-degree: top1={d} ({d:.2}% of edges) top8={d} ({d:.2}%) top64={d} ({d:.2}%)\n",
        .{ top1, pct(top1, total_edges), top8, pct(top8, total_edges), top64, pct(top64, total_edges) },
    );
    std.debug.print("arc-census hottest objects (id kind in-degree): ", .{});
    for (0..8) |j| {
        std.debug.print("{d}:{s}:{d} ", .{ top_ids[j], @tagName(heap.objects.get(top_ids[j]).*), top_deg[j] });
    }
    std.debug.print("\n", .{});
}

/// Kahn peeling = trial deletion with all external (root/stack) references
/// dropped: repeatedly free objects with zero remaining in-heap references.
/// The leftover is EXACTLY the set pure RC can never reclaim — every cycle
/// member plus everything reachable only from cycles.
fn reportKahn(
    heap: *const ObjectHeap,
    a: std.mem.Allocator,
    filled: []const u64,
    comptime isFilled: fn ([]const u64, u32) bool,
    off: []const u32,
    edges: []const u32,
    indeg_in: []const u32,
    totals: *const VariantAgg,
) !void {
    const n: u32 = @intCast(indeg_in.len);
    const indeg = try a.alloc(u32, n);
    defer a.free(indeg);
    @memcpy(indeg, indeg_in);
    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(a);
    var id: u32 = 0;
    while (id < n) : (id += 1) {
        if (isFilled(filled, id) and indeg[id] == 0) try stack.append(a, id);
    }
    var removed: u64 = 0;
    while (stack.pop()) |v| {
        removed += 1;
        for (edges[off[v]..off[v + 1]]) |c| {
            indeg[c] -= 1;
            if (indeg[c] == 0) try stack.append(a, c);
        }
    }
    var leak: VariantAgg = .{};
    id = 0;
    while (id < n) : (id += 1) {
        if (!isFilled(filled, id) or indeg[id] == 0) continue;
        const obj = heap.objects.get(id);
        leak.add(variantIndex(obj), ownedBytes(obj));
    }
    const tot_n = totals.totalN();
    const tot_b = totals.totalBytes();
    const leak_n = leak.totalN();
    const leak_b = leak.totalBytes();
    std.debug.print(
        "arc-census trial-deletion: rc_frees={d} ({d:.1}%) cycle-leak objects={d} ({d:.1}%) bytes={d:.1}MB ({d:.1}% of {d:.1}MB)\n",
        .{ removed, pct(removed, tot_n), leak_n, pct(leak_n, tot_n), mb(leak_b), pct(leak_b, tot_b), mb(tot_b) },
    );
    for (0..VARIANTS) |vi| {
        if (leak.n[vi] == 0) continue;
        std.debug.print("  leak variant {s:<16} n={d} bytes={d:.1}MB ({d:.1}% of variant bytes)\n", .{
            ObjectHeap.Stats.variantName(vi), leak.n[vi], mb(leak.bytes[vi]), pct(leak.bytes[vi], totals.bytes[vi]),
        });
    }
}

/// Iterative Tarjan SCC over the CSR graph. Counts NONTRIVIAL cycle members:
/// SCCs of size >= 2, plus size-1 SCCs with a self-loop.
fn reportTarjan(
    heap: *const ObjectHeap,
    a: std.mem.Allocator,
    filled: []const u64,
    comptime isFilled: fn ([]const u64, u32) bool,
    off: []const u32,
    edges: []const u32,
    self_loops: []const u64,
    totals: *const VariantAgg,
) !void {
    const n: u32 = @intCast(off.len - 1);
    const UNVISITED: u32 = std.math.maxInt(u32);
    const index = try a.alloc(u32, n);
    defer a.free(index);
    @memset(index, UNVISITED);
    const lowlink = try a.alloc(u32, n);
    defer a.free(lowlink);
    const on_stack = try a.alloc(u64, (@as(usize, n) + 63) >> 6);
    defer a.free(on_stack);
    @memset(on_stack, 0);
    var scc_stack: std.ArrayListUnmanaged(u32) = .empty;
    defer scc_stack.deinit(a);
    const Frame = struct { v: u32, ei: u32 };
    var dfs: std.ArrayListUnmanaged(Frame) = .empty;
    defer dfs.deinit(a);

    var next_index: u32 = 0;
    var members: VariantAgg = .{};
    var scc_count: u64 = 0;
    var largest: [5]u64 = @splat(0);

    var root: u32 = 0;
    while (root < n) : (root += 1) {
        if (!isFilled(filled, root) or index[root] != UNVISITED) continue;
        try dfs.append(a, .{ .v = root, .ei = 0 });
        index[root] = next_index;
        lowlink[root] = next_index;
        next_index += 1;
        try scc_stack.append(a, root);
        on_stack[root >> 6] |= @as(u64, 1) << @intCast(root & 63);

        while (dfs.items.len > 0) {
            const fr = &dfs.items[dfs.items.len - 1];
            const v = fr.v;
            if (off[v] + fr.ei < off[v + 1]) {
                const w = edges[off[v] + fr.ei];
                fr.ei += 1;
                if (index[w] == UNVISITED) {
                    index[w] = next_index;
                    lowlink[w] = next_index;
                    next_index += 1;
                    try scc_stack.append(a, w);
                    on_stack[w >> 6] |= @as(u64, 1) << @intCast(w & 63);
                    try dfs.append(a, .{ .v = w, .ei = 0 });
                } else if ((on_stack[w >> 6] >> @intCast(w & 63)) & 1 != 0) {
                    lowlink[v] = @min(lowlink[v], index[w]);
                }
            } else {
                _ = dfs.pop();
                if (dfs.items.len > 0) {
                    const p = dfs.items[dfs.items.len - 1].v;
                    lowlink[p] = @min(lowlink[p], lowlink[v]);
                }
                if (lowlink[v] == index[v]) {
                    // Pop one SCC.
                    var size: u64 = 0;
                    const base = blk: {
                        var i = scc_stack.items.len;
                        while (i > 0) {
                            i -= 1;
                            if (scc_stack.items[i] == v) break :blk i;
                        }
                        unreachable;
                    };
                    const nontrivial = (scc_stack.items.len - base) >= 2 or
                        ((self_loops[v >> 6] >> @intCast(v & 63)) & 1 != 0);
                    for (scc_stack.items[base..]) |w| {
                        on_stack[w >> 6] &= ~(@as(u64, 1) << @intCast(w & 63));
                        size += 1;
                        if (nontrivial) {
                            const obj = heap.objects.get(w);
                            members.add(variantIndex(obj), ownedBytes(obj));
                        }
                    }
                    scc_stack.shrinkRetainingCapacity(base);
                    if (nontrivial) {
                        scc_count += 1;
                        // Track top-5 sizes.
                        var s = size;
                        for (&largest) |*slot| {
                            if (s > slot.*) {
                                const t = slot.*;
                                slot.* = s;
                                s = t;
                            }
                        }
                    }
                }
            }
        }
    }

    const tot_n = totals.totalN();
    const tot_b = totals.totalBytes();
    const m_n = members.totalN();
    const m_b = members.totalBytes();
    std.debug.print(
        "arc-census scc: nontrivial_sccs={d} members={d} ({d:.1}% of objects) bytes={d:.1}MB ({d:.1}%) largest={any}\n",
        .{ scc_count, m_n, pct(m_n, tot_n), mb(m_b), pct(m_b, tot_b), largest },
    );
    for (0..VARIANTS) |vi| {
        if (members.n[vi] == 0) continue;
        std.debug.print("  scc variant {s:<16} n={d} bytes={d:.1}MB\n", .{
            ObjectHeap.Stats.variantName(vi), members.n[vi], mb(members.bytes[vi]),
        });
    }
}
