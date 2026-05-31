//! Nix-compatible POSIX path splitting helpers.

const std = @import("std");

pub fn baseName(path: []const u8) []const u8 {
    const trimmed = trimTrailingSlashes(path);
    if (trimmed.len == 0) return "";

    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    if (slash + 1 >= trimmed.len) return "";
    return trimmed[slash + 1 ..];
}

pub fn dirOf(path: []const u8) []const u8 {
    const trimmed = trimTrailingSlashes(path);
    if (trimmed.len == 0) return ".";

    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    if (slash == 0) return "/";
    return trimmed[0..slash];
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    if (path.len <= 1) return path;

    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

test "baseName matches Nix path splitting edge cases" {
    try std.testing.expectEqualStrings("bar", baseName("/foo/bar"));
    try std.testing.expectEqualStrings("bar", baseName("foo/bar/"));
    try std.testing.expectEqualStrings("foo", baseName("foo"));
    try std.testing.expectEqualStrings("", baseName(""));
}

test "dirOf matches Nix path splitting edge cases" {
    try std.testing.expectEqualStrings("/foo", dirOf("/foo/bar"));
    try std.testing.expectEqualStrings("/", dirOf("/foo"));
    try std.testing.expectEqualStrings("foo", dirOf("foo/bar"));
    try std.testing.expectEqualStrings(".", dirOf("foo"));
    try std.testing.expectEqualStrings(".", dirOf(""));
}
