//! Narrow decoder for `NarFromPath` responses used as regular files.

const std = @import("std");
const wire = @import("wire.zig");

/// Parse a `nix-archive-1` NAR containing a single regular file and return its
/// owned contents. Directory and symlink NARs are rejected.
pub fn readSingleFile(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    try expectToken(allocator, reader, "nix-archive-1");
    try expectToken(allocator, reader, "(");
    try expectToken(allocator, reader, "type");
    try expectToken(allocator, reader, "regular");

    var token = try wire.readString(allocator, reader);
    if (std.mem.eql(u8, token, "executable")) {
        allocator.free(token);
        const empty = try wire.readString(allocator, reader);
        allocator.free(empty);
        token = try wire.readString(allocator, reader);
    }
    defer allocator.free(token);
    if (!std.mem.eql(u8, token, "contents")) return error.UnexpectedNar;

    const contents = try wire.readString(allocator, reader);
    errdefer allocator.free(contents);
    try expectToken(allocator, reader, ")");
    return contents;
}

fn expectToken(allocator: std.mem.Allocator, reader: *std.Io.Reader, want: []const u8) !void {
    const token = try wire.readString(allocator, reader);
    defer allocator.free(token);
    if (!std.mem.eql(u8, token, want)) return error.UnexpectedNar;
}
