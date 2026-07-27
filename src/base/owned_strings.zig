//! Allocation helpers for deeply-owned slices of byte strings.

const std = @import("std");

pub fn clone(allocator: std.mem.Allocator, strings: []const []const u8) ![][]u8 {
    const result = try allocator.alloc([]u8, strings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |string| allocator.free(string);
        allocator.free(result);
    }
    while (initialized < result.len) : (initialized += 1) {
        result[initialized] = try allocator.dupe(u8, strings[initialized]);
    }
    return result;
}

/// Free a deeply-owned slice; mutable slice views coerce to this read-only view.
pub fn free(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

test "clone owns the outer and inner slices" {
    const original = [_][]const u8{ "one", "two" };
    const copy = try clone(std.testing.allocator, &original);
    defer free(std.testing.allocator, copy);
    try std.testing.expectEqualStrings("one", copy[0]);
    try std.testing.expect(copy[0].ptr != original[0].ptr);
}

fn checkCloneAllocationFailures(allocator: std.mem.Allocator) !void {
    const copy = try clone(allocator, &.{ "one", "two", "three" });
    defer free(allocator, copy);
}

test "clone handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCloneAllocationFailures,
        .{},
    );
}
