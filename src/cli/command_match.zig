//! Top-level command-name resolution.
//!
//! Exact command names win. Otherwise a non-empty prefix is accepted only
//! when it identifies exactly one command, matching familiar multicall CLIs
//! without making additions silently change an exact invocation.

const std = @import("std");

pub const Result = union(enum) {
    none,
    ambiguous,
    match: usize,
};

pub fn resolve(names: []const []const u8, input: []const u8) Result {
    if (input.len == 0) return .none;

    var candidate: ?usize = null;
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, input, name)) return .{ .match = index };
        if (!std.mem.startsWith(u8, name, input)) continue;
        if (candidate != null) return .ambiguous;
        candidate = index;
    }
    return if (candidate) |index| .{ .match = index } else .none;
}

test "exact and unique command prefixes resolve" {
    const names = &[_][]const u8{ "build", "shell", "switch" };

    try std.testing.expectEqual(@as(usize, 0), resolve(names, "b").match);
    try std.testing.expectEqual(@as(usize, 1), resolve(names, "shell").match);
    try std.testing.expectEqual(@as(usize, 2), resolve(names, "sw").match);
}

test "empty unknown and ambiguous command prefixes do not resolve" {
    const names = &[_][]const u8{ "build", "shell", "switch" };

    try std.testing.expect(resolve(names, "") == .none);
    try std.testing.expect(resolve(names, "wat") == .none);
    try std.testing.expect(resolve(names, "s") == .ambiguous);
}
