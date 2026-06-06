//! Shared bytecode operand encoding helpers.

const std = @import("std");
const types = @import("types.zig");

pub const MixedAttrSegmentTag = enum(u8) {
    static = 0,
    dynamic = 1,
};

pub fn readU16(code: []const u8, ip: usize) u16 {
    return @as(u16, code[ip]) | (@as(u16, code[ip + 1]) << 8);
}

pub fn readU32(code: []const u8, ip: usize) u32 {
    return @as(u32, code[ip]) |
        (@as(u32, code[ip + 1]) << 8) |
        (@as(u32, code[ip + 2]) << 16) |
        (@as(u32, code[ip + 3]) << 24);
}

pub fn readInternId(code: []const u8, ip: usize, wide: bool) types.InternId {
    return if (wide) readU32(code, ip) else @intCast(readU16(code, ip));
}

pub fn writeU16(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u16) !void {
    try out.append(allocator, @truncate(val));
    try out.append(allocator, @truncate(val >> 8));
}

pub fn writeU32(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u32) !void {
    try out.append(allocator, @truncate(val));
    try out.append(allocator, @truncate(val >> 8));
    try out.append(allocator, @truncate(val >> 16));
    try out.append(allocator, @truncate(val >> 24));
}

pub fn writeInternId(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, id: types.InternId, wide: bool) !void {
    if (wide) {
        try writeU32(out, allocator, id);
    } else {
        try writeU16(out, allocator, @intCast(id));
    }
}
