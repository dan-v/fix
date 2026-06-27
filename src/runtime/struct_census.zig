//! Deforestation-headroom probe (gated behind `-Dstruct-census`, off by
//! default — zero cost in normal builds). The structural sibling of
//! `vm/trace_probe.zig` (which measures *thunk* single-use → the
//! `sink_ceiling`).
//!
//! A demand-aware / deforesting optimizer can fuse away an intermediate
//! list/attrset only when it is *single-use* — built by one producer,
//! consumed by one op, never re-read. A structure read by multiple
//! consumers IS shared state (the module-system config graph) that fusing
//! would recompute. So the deforestation ceiling is the single-use
//! fraction of the structures we build.
//!
//! We record, per list/attrset ObjectId: kind, consume count, and the
//! PRODUCER op (set at `applyBuiltin` / the literal+merge VM ops via
//! save/restore) and the CONSUMER op (producer tag live at read time). At
//! eval end we print the single-use histogram plus a producer breakdown
//! and the top producer→consumer pairs — which decides targeted builtin-
//! level fusion vs a general trace deforester. Run at `--workers=1` so the
//! plain (non-atomic) counters + global tag don't race.

const std = @import("std");
const build_options = @import("build_options");
const BuiltinId = @import("builtins.zig").BuiltinId;

pub const enabled: bool = build_options.struct_census;

const CAP: usize = 32 * 1024 * 1024;

pub const Kind = enum(u8) { none = 0, list = 1, attrs = 2 };

// Producer/consumer op tags. Low values are VM ops; BUILTIN_BASE+id is a
// builtin (id < 256). 0 = untagged (allocation outside any tagged op).
pub const TAG_NONE: u16 = 0;
pub const TAG_ATTRS_LIT: u16 = 1; // `{ ... }`
pub const TAG_LIST_LIT: u16 = 2; // `[ ... ]`
pub const TAG_MERGE: u16 = 3; // `//` (layered)
pub const TAG_MERGE_STRICT: u16 = 4; // `//` (strict materialize)
pub const TAG_CONCAT: u16 = 5; // `++`
pub const BUILTIN_BASE: u16 = 1000;

const State = struct {
    kinds: []u8 = &.{},
    reads: []u8 = &.{},
    producers: []u16 = &.{},
    consumers: []u16 = &.{},
    overflow_allocs: u64 = 0,
    overflow_reads: u64 = 0,
};

var state: State = .{};

/// Current producer op. Global (the probe runs at --workers=1).
var producer_tag: u16 = TAG_NONE;

pub fn init(allocator: std.mem.Allocator) void {
    if (comptime !enabled) return;
    state.kinds = allocator.alloc(u8, CAP) catch &.{};
    state.reads = allocator.alloc(u8, CAP) catch &.{};
    state.producers = allocator.alloc(u16, CAP) catch &.{};
    state.consumers = allocator.alloc(u16, CAP) catch &.{};
    @memset(state.kinds, 0);
    @memset(state.reads, 0);
    @memset(state.producers, 0);
    @memset(state.consumers, 0);
}

/// Set the current producer op, returning the previous one for restore.
pub inline fn setProducer(tag: u16) u16 {
    if (comptime !enabled) return 0;
    const old = producer_tag;
    producer_tag = tag;
    return old;
}

pub inline fn restoreProducer(old: u16) void {
    if (comptime !enabled) return;
    producer_tag = old;
}

pub inline fn recordAlloc(id: u32, kind: Kind) void {
    if (comptime !enabled) return;
    const i: usize = id;
    if (i >= state.kinds.len) {
        state.overflow_allocs += 1;
        return;
    }
    state.kinds[i] = @intFromEnum(kind);
    state.producers[i] = producer_tag;
}

pub inline fn recordRead(id: u32) void {
    if (comptime !enabled) return;
    const i: usize = id;
    if (i >= state.reads.len) {
        state.overflow_reads += 1;
        return;
    }
    if (state.reads[i] != 255) state.reads[i] += 1;
    state.consumers[i] = producer_tag;
}

const Hist = struct {
    allocated: u64 = 0,
    read0: u64 = 0,
    read1: u64 = 0,
    read2: u64 = 0,
    read3_4: u64 = 0,
    read5_8: u64 = 0,
    read9: u64 = 0,
    reads_total: u64 = 0,

    fn add(self: *Hist, r: u8) void {
        self.allocated += 1;
        self.reads_total += r;
        switch (r) {
            0 => self.read0 += 1,
            1 => self.read1 += 1,
            2 => self.read2 += 1,
            3, 4 => self.read3_4 += 1,
            5...8 => self.read5_8 += 1,
            else => self.read9 += 1,
        }
    }
};

fn pct(n: u64, d: u64) f64 {
    if (d == 0) return 0;
    return @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(d));
}

fn tagName(tag: u16) []const u8 {
    return switch (tag) {
        TAG_NONE => "?untagged",
        TAG_ATTRS_LIT => "{}literal",
        TAG_LIST_LIT => "[]literal",
        TAG_MERGE => "//merge",
        TAG_MERGE_STRICT => "//merge-strict",
        TAG_CONCAT => "++concat",
        else => if (tag >= BUILTIN_BASE)
            @tagName(@as(BuiltinId, @enumFromInt(tag - BUILTIN_BASE)))
        else
            "?",
    };
}

fn printKind(name: []const u8, h: Hist) void {
    const single = h.read0 + h.read1;
    std.debug.print("--- {s}: {d} allocated, {d} consumes ---\n", .{ name, h.allocated, h.reads_total });
    std.debug.print("  0x={d} ({d:.0}%) 1x={d} ({d:.0}%) 2x={d} 3-4x={d} 5-8x={d} 9+x={d}\n", .{
        h.read0, pct(h.read0, h.allocated), h.read1, pct(h.read1, h.allocated), h.read2, h.read3_4, h.read5_8, h.read9,
    });
    std.debug.print("  => single-use (<=1): {d} ({d:.1}% of structures)\n", .{ single, pct(single, h.allocated) });
}

const TAG_SLOTS: usize = BUILTIN_BASE + 256;

pub fn report() void {
    if (comptime !enabled) return;
    var lists: Hist = .{};
    var attrs: Hist = .{};

    // Per-producer / per-consumer single-use structure counts (list+attrs).
    var prod_single = std.heap.page_allocator.alloc(u64, TAG_SLOTS) catch return;
    defer std.heap.page_allocator.free(prod_single);
    @memset(prod_single, 0);
    var cons_single = std.heap.page_allocator.alloc(u64, TAG_SLOTS) catch return;
    defer std.heap.page_allocator.free(cons_single);
    @memset(cons_single, 0);

    // Top producer→consumer pairs among single-use structures.
    var pairs = std.AutoHashMap(u32, u64).init(std.heap.page_allocator);
    defer pairs.deinit();

    for (state.kinds, state.reads, state.producers, state.consumers) |k, r, p, c| {
        const kind: Kind = @enumFromInt(k);
        switch (kind) {
            .none => continue,
            .list => lists.add(r),
            .attrs => attrs.add(r),
        }
        if (r <= 1) {
            if (p < TAG_SLOTS) prod_single[p] += 1;
            if (c < TAG_SLOTS) cons_single[c] += 1;
            const key = (@as(u32, p) << 16) | @as(u32, c);
            (pairs.getOrPutValue(key, 0) catch continue).value_ptr.* += 1;
        }
    }

    std.debug.print("\n=== deforestation-headroom probe (list/attrset reuse) ===\n", .{});
    std.debug.print("overflow: allocs={d} reads={d}\n", .{ state.overflow_allocs, state.overflow_reads });
    printKind("lists", lists);
    printKind("attrsets", attrs);

    const total_single = (lists.read0 + lists.read1) + (attrs.read0 + attrs.read1);
    std.debug.print("\nsingle-use producers (top 20, combined list+attrs, {d} total single-use):\n", .{total_single});
    for (0..20) |_| {
        var best: usize = 0;
        var best_n: u64 = 0;
        for (prod_single, 0..) |n, t| {
            if (n > best_n) {
                best_n = n;
                best = t;
            }
        }
        if (best_n == 0) break;
        std.debug.print("  {s:<22} {d:>9} ({d:.1}%)\n", .{ tagName(@intCast(best)), best_n, pct(best_n, total_single) });
        prod_single[best] = 0;
    }

    std.debug.print("\nsingle-use producer -> consumer pairs (top 20):\n", .{});
    for (0..20) |_| {
        var best_key: u32 = 0;
        var best_n: u64 = 0;
        var it = pairs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* > best_n) {
                best_n = e.value_ptr.*;
                best_key = e.key_ptr.*;
            }
        }
        if (best_n == 0) break;
        const p: u16 = @intCast(best_key >> 16);
        const c: u16 = @intCast(best_key & 0xFFFF);
        std.debug.print("  {s:<20} -> {s:<20} {d:>9} ({d:.1}%)\n", .{ tagName(p), tagName(c), best_n, pct(best_n, total_single) });
        _ = pairs.remove(best_key);
    }
    std.debug.print("\nsingle-use consumers (top 15):\n", .{});
    for (0..15) |_| {
        var best: usize = 0;
        var best_n: u64 = 0;
        for (cons_single, 0..) |n, t| {
            if (n > best_n) {
                best_n = n;
                best = t;
            }
        }
        if (best_n == 0) break;
        std.debug.print("  {s:<22} {d:>9} ({d:.1}%) [{s}]\n", .{ tagName(@intCast(best)), best_n, pct(best_n, total_single), @tagName(consumerClass(@intCast(best))) });
        cons_single[best] = 0;
    }

    // True-fusion ceiling: single-use structures split by consumer class.
    // Only SHALLOW (consumer needs < full content) and COMPOSING (consumer
    // is itself a fusable producer) are work-avoidable; MATERIALIZING
    // consumers need the whole structure so fusion can't elide work.
    @memset(cons_single, 0); // reused: recompute (top-15 loop zeroed entries)
    var shallow: u64 = 0;
    var composing: u64 = 0;
    var materializing: u64 = 0;
    for (state.kinds, state.reads, state.consumers) |k, r, c| {
        if (@as(Kind, @enumFromInt(k)) == .none) continue;
        if (r > 1) continue;
        switch (consumerClass(c)) {
            .shallow => shallow += 1,
            .composing => composing += 1,
            .materializing => materializing += 1,
        }
    }
    std.debug.print("\n=== TRUE-FUSION CEILING (single-use by consumer class) ===\n", .{});
    std.debug.print("  shallow (needs < full content):  {d:>9} ({d:.1}%)\n", .{ shallow, pct(shallow, total_single) });
    std.debug.print("  composing (fusable producer):    {d:>9} ({d:.1}%)\n", .{ composing, pct(composing, total_single) });
    std.debug.print("  materializing (needs whole):     {d:>9} ({d:.1}%)\n", .{ materializing, pct(materializing, total_single) });
    std.debug.print("  => work-avoidable (shallow+composing): {d} of {d} single-use ({d:.1}%)\n", .{ shallow + composing, total_single, pct(shallow + composing, total_single) });
    std.debug.print("note: run at --workers=1 for an unraced single-thread (serial-eval) picture.\n", .{});
}

const ConsumerClass = enum { shallow, composing, materializing };

/// Classify a consumer op by how much of the structure it needs. Shallow =
/// length/index/keys (work-avoidable). Composing = a producer op that
/// iterates but could itself be fused into the chain. Everything else
/// materializes the whole structure (fusion can't elide its contents).
fn consumerClass(tag: u16) ConsumerClass {
    const name = tagName(tag);
    const shallow = [_][]const u8{ "length", "elemAt", "head", "tail", "attrNames", "functionArgs", "isAttrs", "isList", "hasAttr" };
    for (shallow) |s| if (std.mem.eql(u8, name, s)) return .shallow;
    const composing = [_][]const u8{ "map", "filter", "mapAttrs", "concatMap", "catAttrs", "attrValues", "foldl'", "any", "all", "++concat", "concatLists" };
    for (composing) |s| if (std.mem.eql(u8, name, s)) return .composing;
    return .materializing;
}
