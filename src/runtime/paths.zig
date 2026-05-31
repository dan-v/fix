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

pub fn searchPathSuffix(prefix: []const u8, name: []const u8) ?[]const u8 {
    if (prefix.len == 0) return name;
    if (std.mem.eql(u8, prefix, name)) return "";
    if (name.len <= prefix.len or name[prefix.len] != '/') return null;
    if (!std.mem.eql(u8, prefix, name[0..prefix.len])) return null;
    return name[prefix.len + 1 ..];
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

test "search path suffix honors nix path prefixes" {
    try std.testing.expectEqualStrings("pkg/default.nix", searchPathSuffix("", "pkg/default.nix").?);
    try std.testing.expectEqualStrings("", searchPathSuffix("pkg", "pkg").?);
    try std.testing.expectEqualStrings("default.nix", searchPathSuffix("pkg", "pkg/default.nix").?);
    try std.testing.expect(searchPathSuffix("pkg", "pkg-extra/default.nix") == null);
}
