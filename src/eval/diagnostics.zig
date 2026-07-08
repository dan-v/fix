//! Post-evaluation diagnostic dumps: the tracing-JIT hot-anchor list
//! (`-Dtjit`, gated on `report_enabled`) and the VM opcode-execution profile
//! (`-Dvm-opcode-profile`). Both are print-only, invoked from `evaluateSource`
//! after evaluation; off the hot path and compiled out of default builds.

const std = @import("std");
const types = @import("runtime").types;
const tjit_hot = @import("../jit/hot.zig");
const vm_mod = @import("../vm.zig");
const opcode = @import("../bytecode.zig").opcode;

/// `-Dtjit`: list the tracing-JIT hot anchors (armed/traced chunks) with their
/// source location and hit counts. No-op unless `tjit_hot.report_enabled`.
pub fn reportHotAnchors(ev: anytype) void {
    if (!tjit_hot.report_enabled) return;
    const h = ev.registry.hot orelse return;
    var armed: usize = 0;
    var traced: usize = 0;
    var shown: usize = 0;
    const count = ev.registry.count();
    var id: u32 = 0;
    while (id < count and id < h.entries.len) : (id += 1) {
        const st = h.stateOf(id);
        if (st == .cold or st == .blacklisted) continue;
        if (st == .traced) traced += 1 else armed += 1;
        if (shown >= 80) continue;
        shown += 1;
        const ch = ev.registry.get(id) orelse continue;
        var line: u32 = 0;
        var file: ?types.InternId = null;
        for (ch.source_map) |e| {
            if (e.start == 0) {
                line = e.span.line;
                file = e.span.file;
                break;
            }
        }
        const path = if (file) |f| std.fs.path.basename(ev.intern.get(f)) else "<no-file>";
        std.debug.print("HOT-ANCHOR chunk={d} {s}:{d} {s} entries={d} locals={d}\n", .{
            id, path, line, @tagName(st), h.entries[id].count, ch.local_count,
        });
    }
    std.debug.print("=== tjit hot anchors: {d} armed, {d} traced (threshold={d}, chunks={d}) ===\n", .{ armed, traced, h.hot_threshold, count });
}

const OpcodeCountEntry = struct {
    op: opcode.OpCode,
    count: u64,
};

/// `-Dvm-opcode-profile`: print per-opcode execution counts, sorted, with each
/// opcode's share of the total.
pub fn printVmOpcodeProfile(counts: *const vm_mod.OpcodeCounts) void {
    var total: u64 = 0;
    var entries: [opcode.count]OpcodeCountEntry = undefined;
    for (counts, &entries, 0..) |count, *entry, i| {
        total += count;
        entry.* = .{
            .op = @enumFromInt(i),
            .count = count,
        };
    }

    std.mem.sort(OpcodeCountEntry, &entries, {}, opcodeCountGreaterThan);

    std.debug.print("fix vm opcode profile: total={d}\n", .{total});
    for (entries) |entry| {
        if (entry.count == 0) break;
        const pct = if (total == 0) 0.0 else (@as(f64, @floatFromInt(entry.count)) * 100.0) / @as(f64, @floatFromInt(total));
        std.debug.print("  {s}: {d} ({d:.2}%)\n", .{ @tagName(entry.op), entry.count, pct });
    }
}

fn opcodeCountGreaterThan(_: void, lhs: OpcodeCountEntry, rhs: OpcodeCountEntry) bool {
    return lhs.count > rhs.count;
}
