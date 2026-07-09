//! Post-evaluation diagnostic dumps: the VM opcode-execution profile
//! (`-Dvm-opcode-profile`). Print-only, invoked from `evaluateSource`
//! after evaluation; off the hot path and compiled out of default builds.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const opcode = @import("bytecode").opcode;

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
