//! Parsing helpers for evaluator memory limits.

const std = @import("std");

/// Parse a byte size with optional K/M/G suffix. A bare integer is MiB, matching
/// the command-line and environment configuration accepted by the evaluator.
pub fn parseSize(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var number = text;
    var multiplier: u64 = 1 << 20;
    switch (text[text.len - 1]) {
        'k', 'K' => {
            multiplier = 1 << 10;
            number = text[0 .. text.len - 1];
        },
        'm', 'M' => {
            multiplier = 1 << 20;
            number = text[0 .. text.len - 1];
        },
        'g', 'G' => {
            multiplier = 1 << 30;
            number = text[0 .. text.len - 1];
        },
        else => {},
    }
    const value = std.fmt.parseInt(u64, number, 10) catch return null;
    return value *| multiplier;
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
