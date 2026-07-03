const std = @import("std");

pub fn captureCount(count: usize) !u16 {
    if (count > std.math.maxInt(u16)) return error.TooManyCaptures;
    return @intCast(count);
}

pub fn u16Count(count: usize) !u16 {
    if (count > std.math.maxInt(u16)) return error.BytecodeOperandTooLarge;
    return @intCast(count);
}

test "captureCount passes through counts that fit in u16" {
    try std.testing.expectEqual(@as(u16, 0), try captureCount(0));
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), try captureCount(std.math.maxInt(u16)));
}

test "captureCount rejects counts that overflow u16" {
    try std.testing.expectError(error.TooManyCaptures, captureCount(@as(usize, std.math.maxInt(u16)) + 1));
}

test "u16Count rejects counts that overflow u16" {
    try std.testing.expectEqual(@as(u16, 5), try u16Count(5));
    try std.testing.expectError(error.BytecodeOperandTooLarge, u16Count(@as(usize, std.math.maxInt(u16)) + 1));
}
