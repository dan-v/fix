const std = @import("std");

pub fn captureCount(count: usize) !u16 {
    if (count > std.math.maxInt(u16)) return error.TooManyCaptures;
    return @intCast(count);
}

pub fn u16Count(count: usize) !u16 {
    if (count > std.math.maxInt(u16)) return error.BytecodeOperandTooLarge;
    return @intCast(count);
}
