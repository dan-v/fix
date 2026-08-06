//! `-Dprof-main` rider: duplicate-resolve census — the full-laziness payoff
//! probe. At every worker-0 bytecode-thunk resolve, key the evaluation by
//! `(chunk_id, hash of ALL upvalue value-bits, spilled included)` and charge
//! its inclusive body cycles: the SECOND and later resolves of one key are
//! work a shared floated thunk would have collapsed to a single evaluation.
//!
//! Interpretation notes:
//!   - Value-bits equality UNDER-approximates semantic equality (equal but
//!     distinct ObjectIds miss), so totals are a floor.
//!   - Cycles are INCLUSIVE of nested forces, so a duplicate chain
//!     double-counts its nested duplicates — an over-estimate that bounds
//!     the ceiling from above. Read the pair as a bracket.
//!   - Thread-local memo hits are EXCLUDED (they already cost nothing);
//!     this census measures the redundancy the memo does NOT catch. The
//!     memo's own census (`prof_census.reportCaches`) reports its side.
//!   - Worker-0 only: at w=1 that is all work; at w>1 it is the demand
//!     chain — exactly the mass that converts to wall time (helpers are
//!     mostly idle; see docs/perf/model.md).

const std = @import("std");
const prof = @import("prof.zig");
const ChunkRegistry = @import("../bytecode/chunk/registry.zig").ChunkRegistry;
const InternTable = @import("runtime").intern.InternTable;

pub const Slot = struct {
    chunk: u32 = 0,
    hash: u64 = 0,
    count: u32 = 0,
    memo_eligible: bool = false,
    first_cycles: u64 = 0,
    dup_cycles: u64 = 0,
};

const table_bits = 25; // 32M slots (~1GB, probe build only) — a full nixpkgs chunk's worker-0 resolves fit
const table_len = 1 << table_bits;
const probe_limit = 32;

var table: ?[]Slot = null;
var struct_table: ?[]Slot = null;
pub var dropped: u64 = 0;
pub var struct_dropped: u64 = 0;
pub var recorded: u64 = 0;

fn slotsFor(which: *?[]Slot) []Slot {
    if (which.*) |t| return t;
    const t = std.heap.page_allocator.alloc(Slot, table_len) catch {
        // Leave the census empty rather than fail the run.
        which.* = &.{};
        return which.*.?;
    };
    @memset(t, .{});
    which.* = t;
    return t;
}

fn tableSlots() []Slot {
    return slotsFor(&table);
}

/// Same census keyed by depth-limited STRUCTURAL upvalue hashes: equal
/// arguments held in DISTINCT objects (the cross-instantiation case the
/// bit-census cannot see) collide here. The gap between the two tables'
/// dup mass is the value-memoization ceiling estimate.
pub fn recordStructural(chunk: u32, hash: u64, cycles: u64) void {
    if (comptime !prof.enabled) return;
    const t = slotsFor(&struct_table);
    if (t.len == 0) return;
    var idx: usize = @intCast((hash ^ (@as(u64, chunk) *% 0x9E3779B97F4A7C15)) & (table_len - 1));
    var step: usize = 0;
    while (step < probe_limit) : (step += 1) {
        const slot = &t[idx];
        if (slot.count == 0) {
            slot.* = .{ .chunk = chunk, .hash = hash, .count = 1, .first_cycles = cycles };
            return;
        }
        if (slot.chunk == chunk and slot.hash == hash) {
            slot.count += 1;
            slot.dup_cycles += cycles;
            return;
        }
        idx = (idx + 1) & (table_len - 1);
    }
    struct_dropped += 1;
}

/// Record one completed worker-0 bytecode resolve. `cycles` is the
/// inclusive body cost measured by the caller around evaluation.
pub fn record(chunk: u32, hash: u64, memo_eligible: bool, cycles: u64) void {
    if (comptime !prof.enabled) return;
    const t = tableSlots();
    if (t.len == 0) return;
    recorded += 1;
    var idx: usize = @intCast((hash ^ (@as(u64, chunk) *% 0x9E3779B97F4A7C15)) & (table_len - 1));
    var step: usize = 0;
    while (step < probe_limit) : (step += 1) {
        const slot = &t[idx];
        if (slot.count == 0) {
            slot.* = .{
                .chunk = chunk,
                .hash = hash,
                .count = 1,
                .memo_eligible = memo_eligible,
                .first_cycles = cycles,
            };
            return;
        }
        if (slot.chunk == chunk and slot.hash == hash) {
            slot.count += 1;
            slot.dup_cycles += cycles;
            return;
        }
        idx = (idx + 1) & (table_len - 1);
    }
    dropped += 1;
}

/// Per-chunk aggregation, ranked by duplicate cycle mass. The go/no-go
/// numbers: `dup cycles` as a fraction of the run's wall cycles, and how
/// much of it the top chunks concentrate.
pub fn report(registry: *const ChunkRegistry, intern: *const InternTable) void {
    if (comptime !prof.enabled) return;
    reportTable(registry, intern, table orelse return, "value-bits", dropped);
    if (struct_table) |st| reportTable(registry, intern, st, "STRUCTURAL", struct_dropped);
}

fn reportTable(registry: *const ChunkRegistry, intern: *const InternTable, t: []Slot, label: []const u8, dropped_n: u64) void {
    if (t.len == 0) return;

    const Agg = struct { resolves: u64 = 0, dups: u64 = 0, dup_cycles: u64 = 0, memo_elig_dups: u64 = 0 };
    var per_chunk = std.AutoHashMap(u32, Agg).init(std.heap.page_allocator);
    defer per_chunk.deinit();

    var total_resolves: u64 = 0;
    var total_dups: u64 = 0;
    var total_dup_cycles: u64 = 0;
    var memo_elig_dup_cycles: u64 = 0;
    for (t) |slot| {
        if (slot.count == 0) continue;
        total_resolves += slot.count;
        const dups = slot.count - 1;
        total_dups += dups;
        total_dup_cycles += slot.dup_cycles;
        if (slot.memo_eligible) memo_elig_dup_cycles += slot.dup_cycles;
        const gop = per_chunk.getOrPut(slot.chunk) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.resolves += slot.count;
        gop.value_ptr.dups += dups;
        gop.value_ptr.dup_cycles += slot.dup_cycles;
        if (slot.memo_eligible) gop.value_ptr.memo_elig_dups += dups;
    }
    if (total_resolves == 0) return;

    std.debug.print(
        "prof dup-resolve [{s}] (worker 0, memo-missed only): resolves={d} dup={d} ({d:.1}%) dup_cycles={d} (memo-eligible-key dup_cycles={d}) dropped={d}\n",
        .{ label, total_resolves, total_dups, pct(total_dups, total_resolves), total_dup_cycles, memo_elig_dup_cycles, dropped_n },
    );

    const top_count = 30;
    var top: [top_count]struct { chunk: u32, agg: Agg } = undefined;
    for (&top) |*e| e.* = .{ .chunk = 0, .agg = .{} };
    var it = per_chunk.iterator();
    while (it.next()) |e| {
        const c = e.value_ptr.dup_cycles;
        var slot: usize = top_count;
        while (slot > 0 and top[slot - 1].agg.dup_cycles < c) slot -= 1;
        if (slot < top_count) {
            var j: usize = top_count - 1;
            while (j > slot) : (j -= 1) top[j] = top[j - 1];
            top[slot] = .{ .chunk = e.key_ptr.*, .agg = e.value_ptr.* };
        }
    }
    var top_cycles: u64 = 0;
    for (top) |e| top_cycles += e.agg.dup_cycles;
    std.debug.print(
        "prof dup-resolve [{s}] top-{d} chunks hold {d:.1}% of dup cycles:\n",
        .{ label, top_count, pct(top_cycles, total_dup_cycles) },
    );
    for (top) |e| {
        if (e.agg.dup_cycles == 0) break;
        var name_buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&name_buf);
        if (registry.nameOf(e.chunk)) |nid| {
            registry.name_tree.writeQualified(&w, nid, intern) catch {};
        }
        std.debug.print(
            "  chunk {d} [{s}]: resolves={d} dup={d} dup_cycles={d} memo_elig_dups={d}\n",
            .{ e.chunk, name_buf[0..w.end], e.agg.resolves, e.agg.dups, e.agg.dup_cycles, e.agg.memo_elig_dups },
        );
    }
}

fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
}
