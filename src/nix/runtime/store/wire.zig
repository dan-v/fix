//! Nix/Lix worker-protocol wire framing and constants.
//!
//! Every value on the worker protocol is a little-endian `u64`. A string is a
//! `u64` byte-length followed by the bytes, zero-padded up to the next 8-byte
//! boundary. A string list is a `u64` count followed by that many strings.
//!
//! Constants match Lix 2.95 / modern CppNix (protocol 1.35). The client
//! negotiates `min(our version, daemon version)` at handshake, so these stay
//! compatible with both implementations.

const std = @import("std");

pub const worker_magic_1: u64 = 0x6e697863;
pub const worker_magic_2: u64 = 0x6478696f;

/// Client protocol version we advertise: 1.35. The effective version is the
/// minimum of this and the daemon's, read at handshake.
pub const protocol_version: u64 = (1 << 8) | 35;

pub fn protocolMajor(v: u64) u64 {
    return v & 0xff00;
}
pub fn protocolMinor(v: u64) u64 {
    return v & 0x00ff;
}

/// Worker operation opcodes (the subset fix uses).
pub const Op = enum(u64) {
    is_valid_path = 1,
    add_to_store = 7,
    add_text_to_store = 8,
    build_paths = 9,
    add_temp_root = 11,
    set_options = 19,
    query_path_info = 26,
    query_valid_paths = 31,
    build_derivation = 36,
    add_to_store_nar = 39,
    add_multiple_to_store = 44,
};

/// STDERR_* sideband message tags (the stream the daemon sends after the
/// handshake and after every op, terminated by `stderr_last`).
pub const stderr_next: u64 = 0x6f6c6d67;
pub const stderr_read: u64 = 0x64617461; // legacy non-framed source read
pub const stderr_write: u64 = 0x64617416; // legacy non-framed sink write
pub const stderr_last: u64 = 0x616c7473;
pub const stderr_error: u64 = 0x63787470;
pub const stderr_start_activity: u64 = 0x53545254;
pub const stderr_stop_activity: u64 = 0x53544f50;
pub const stderr_result: u64 = 0x52534c54;

/// Sanity ceiling on a wire string/list length so a corrupt/hostile stream
/// can't make us allocate absurd amounts.
pub const max_wire_len: u64 = 1 << 32;

pub fn writeInt(w: *std.Io.Writer, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try w.writeAll(&buf);
}

pub fn readInt(r: *std.Io.Reader) !u64 {
    const bytes = try r.takeArray(8);
    return std.mem.readInt(u64, bytes, .little);
}

pub fn writeBool(w: *std.Io.Writer, value: bool) !void {
    try writeInt(w, if (value) 1 else 0);
}

pub fn readBool(r: *std.Io.Reader) !bool {
    return (try readInt(r)) != 0;
}

fn padLen(len: usize) usize {
    return (8 - (len % 8)) % 8;
}

pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try writeInt(w, s.len);
    try w.writeAll(s);
    const pad = padLen(s.len);
    if (pad != 0) try w.splatByteAll(0, pad);
}

/// Read a length-prefixed string into freshly allocated memory (caller frees).
pub fn readString(allocator: std.mem.Allocator, r: *std.Io.Reader) ![]u8 {
    const len = try readInt(r);
    if (len > max_wire_len) return error.WireStringTooLong;
    const buf = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(buf);
    try r.readSliceAll(buf);
    const pad = padLen(buf.len);
    if (pad != 0) try r.discardAll(pad);
    return buf;
}

/// Read and discard a length-prefixed string.
pub fn skipString(r: *std.Io.Reader) !void {
    const len = try readInt(r);
    if (len > max_wire_len) return error.WireStringTooLong;
    try r.discardAll64(len);
    try r.discardAll(padLen(@intCast(len)));
}

pub fn writeStrings(w: *std.Io.Writer, items: []const []const u8) !void {
    try writeInt(w, items.len);
    for (items) |item| try writeString(w, item);
}

test "int roundtrip is little-endian" {
    var buf: [8]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeInt(&w, 0x0102_0304_0506_0708);
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 }, &buf);
    var r = std.Io.Reader.fixed(&buf);
    try std.testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), try readInt(&r));
}

test "string is length-prefixed and zero-padded to 8 bytes" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeString(&w, "abc"); // 8 (len) + 3 (data) + 5 (pad) = 16
    try std.testing.expectEqual(@as(usize, 16), w.end);
    try std.testing.expectEqual(@as(u8, 3), buf[0]);
    try std.testing.expectEqualSlices(u8, "abc", buf[8..11]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, buf[11..16]);

    var r = std.Io.Reader.fixed(buf[0..16]);
    const s = try readString(std.testing.allocator, &r);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("abc", s);
}

test "8-byte-aligned string has no padding; string list roundtrips" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeString(&w, "eightchr"); // exactly 8: 8 (len) + 8 (data) + 0 (pad)
    try std.testing.expectEqual(@as(usize, 16), w.end);

    var w2 = std.Io.Writer.fixed(&buf);
    try writeStrings(&w2, &.{ "a", "bb", "ccc" });
    var r = std.Io.Reader.fixed(buf[0..w2.end]);
    const list = try readStrings(std.testing.allocator, &r);
    defer {
        for (list) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(list);
    }
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("a", list[0]);
    try std.testing.expectEqualStrings("bb", list[1]);
    try std.testing.expectEqualStrings("ccc", list[2]);
}

/// Read a string list into freshly allocated memory (caller frees each element
/// and the outer slice).
pub fn readStrings(allocator: std.mem.Allocator, r: *std.Io.Reader) ![][]u8 {
    const n = try readInt(r);
    if (n > max_wire_len) return error.WireListTooLong;
    const list = try allocator.alloc([]u8, @intCast(n));
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |s| allocator.free(s);
        allocator.free(list);
    }
    while (filled < list.len) : (filled += 1) {
        list[filled] = try readString(allocator, r);
    }
    return list;
}
