//! Nix version and derivation-name parsing helpers.

const std = @import("std");

pub const ParsedDrvName = struct {
    name: []const u8,
    version: []const u8,
};

pub fn splitVersion(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer parts.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        const c = text[index];
        if (isSeparator(c)) {
            index += 1;
            continue;
        }

        const start = index;
        if (std.ascii.isDigit(c)) {
            index += 1;
            while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
        } else if (std.ascii.isAlphabetic(c)) {
            index += 1;
            while (index < text.len and std.ascii.isAlphabetic(text[index])) index += 1;
        } else {
            index += 1;
        }
        try parts.append(allocator, text[start..index]);
    }

    return parts.toOwnedSlice(allocator);
}

pub fn compareVersions(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !i64 {
    const left_parts = try splitVersion(allocator, left);
    defer allocator.free(left_parts);
    const right_parts = try splitVersion(allocator, right);
    defer allocator.free(right_parts);

    var index: usize = 0;
    while (index < left_parts.len or index < right_parts.len) : (index += 1) {
        const left_part = if (index < left_parts.len) left_parts[index] else "";
        const right_part = if (index < right_parts.len) right_parts[index] else "";
        const order = comparePart(left_part, right_part);
        if (order < 0) return -1;
        if (order > 0) return 1;
    }
    return 0;
}

pub fn parseDrvName(text: []const u8) ParsedDrvName {
    // Nix splits at the first `-` (past position 0) whose following character is
    // not a letter — so `name-that-ends-with-dash--1.0` splits at the first of
    // the double dash, giving version "-1.0" (not "1.0").
    var index: usize = 1;
    while (index < text.len) : (index += 1) {
        const next_not_alpha = index + 1 >= text.len or !std.ascii.isAlphabetic(text[index + 1]);
        if (text[index] == '-' and next_not_alpha) {
            return .{
                .name = text[0..index],
                .version = text[index + 1 ..],
            };
        }
    }
    return .{ .name = text, .version = "" };
}

fn comparePart(left: []const u8, right: []const u8) i8 {
    if (std.mem.eql(u8, left, right)) return 0;
    if (left.len == 0) return if (std.mem.eql(u8, right, "pre")) 1 else -1;
    if (right.len == 0) return if (std.mem.eql(u8, left, "pre")) -1 else 1;

    const left_number = isNumber(left);
    const right_number = isNumber(right);
    if (left_number and right_number) return compareNumbers(left, right);
    if (left_number != right_number) return if (left_number) 1 else -1;

    return switch (std.mem.order(u8, left, right)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn compareNumbers(left: []const u8, right: []const u8) i8 {
    const l = trimLeadingZeroes(left);
    const r = trimLeadingZeroes(right);
    if (l.len < r.len) return -1;
    if (l.len > r.len) return 1;
    return switch (std.mem.order(u8, l, r)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn trimLeadingZeroes(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index + 1 < text.len and text[index] == '0') index += 1;
    return text[index..];
}

fn isNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isSeparator(c: u8) bool {
    return c == '.' or c == '-';
}

test "splitVersion matches Nix tokenization examples" {
    const parts = try splitVersion(std.testing.allocator, "1.0-beta2");
    defer std.testing.allocator.free(parts);
    try std.testing.expectEqualSlices(u8, "1", parts[0]);
    try std.testing.expectEqualSlices(u8, "0", parts[1]);
    try std.testing.expectEqualSlices(u8, "beta", parts[2]);
    try std.testing.expectEqualSlices(u8, "2", parts[3]);
}

test "compareVersions matches Nix ordering examples" {
    try std.testing.expectEqual(@as(i64, 0), try compareVersions(std.testing.allocator, "1.02", "1.2"));
    try std.testing.expectEqual(@as(i64, -1), try compareVersions(std.testing.allocator, "1.0pre", "1.0"));
    try std.testing.expectEqual(@as(i64, 1), try compareVersions(std.testing.allocator, "1.0", "1.0pre"));
}
