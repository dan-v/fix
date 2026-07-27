//! Shared parsing for evaluator memory-limit configuration.

const std = @import("std");

/// Parse a byte size with optional K/M/G suffix. A bare integer is MiB,
/// matching both command-line and evaluator environment configuration.
pub fn parseSize(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    const parsed = switch (text[text.len - 1]) {
        'k', 'K' => .{ text[0 .. text.len - 1], @as(u64, 1 << 10) },
        'm', 'M' => .{ text[0 .. text.len - 1], @as(u64, 1 << 20) },
        'g', 'G' => .{ text[0 .. text.len - 1], @as(u64, 1 << 30) },
        else => .{ text, @as(u64, 1 << 20) },
    };
    const value = std.fmt.parseInt(u64, parsed[0], 10) catch return null;
    return value *| parsed[1];
}

test "parseSize accepts bare MiB and k/m/g suffixes" {
    try std.testing.expectEqual(@as(?u64, 512 << 20), parseSize("512"));
    try std.testing.expectEqual(@as(?u64, 4 << 30), parseSize("4g"));
    try std.testing.expectEqual(@as(?u64, 4 << 30), parseSize("4G"));
    try std.testing.expectEqual(@as(?u64, 64 << 20), parseSize("64m"));
    try std.testing.expectEqual(@as(?u64, 128 << 10), parseSize("128k"));
    try std.testing.expectEqual(@as(?u64, 0), parseSize("0"));
    try std.testing.expectEqual(@as(?u64, null), parseSize(""));
    try std.testing.expectEqual(@as(?u64, null), parseSize("g"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("12x"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("-1"));
}
