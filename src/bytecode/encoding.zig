//! Shared bytecode operand encoding helpers.

const std = @import("std");
const types = @import("runtime").types;

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

test "writeU16 then readU16 round-trips a value" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try writeU16(&buf, allocator, 0xBEEF);

    try std.testing.expectEqual(@as(usize, 2), buf.items.len);
    try std.testing.expectEqual(@as(u16, 0xBEEF), readU16(buf.items, 0));
}

test "writeU32 then readU32 round-trips a value" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try writeU32(&buf, allocator, 0xDEADBEEF);

    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), readU32(buf.items, 0));
}

test "readU16 and readU32 decode little-endian byte order" {
    const bytes16 = [_]u8{ 0x01, 0x02 };
    try std.testing.expectEqual(@as(u16, 0x0201), readU16(&bytes16, 0));

    const bytes32 = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectEqual(@as(u32, 0x04030201), readU32(&bytes32, 0));
}

test "writeU16/readU32 honor a nonzero start offset into the buffer" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, 0xFF); // padding byte before the real operand
    try writeU32(&buf, allocator, 42);

    try std.testing.expectEqual(@as(u32, 42), readU32(buf.items, 1));
}

test "writeInternId/readInternId round-trip in narrow mode" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try writeInternId(&buf, allocator, 1234, false);

    try std.testing.expectEqual(@as(usize, 2), buf.items.len);
    try std.testing.expectEqual(@as(types.InternId, 1234), readInternId(buf.items, 0, false));
}

test "writeInternId/readInternId round-trip in wide mode" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const big_id: types.InternId = 0x0001_2345;
    try writeInternId(&buf, allocator, big_id, true);

    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
    try std.testing.expectEqual(big_id, readInternId(buf.items, 0, true));
}
