//! Minimal TOML reader for the Lix `test.toml` manifests. Handles exactly the
//! subset they use: an array of `[[test]]` tables whose values are strings,
//! string arrays (possibly spanning lines), and booleans.

const std = @import("std");

pub const Entry = struct {
    runner: []const u8 = "",
    name: ?[]const u8 = null,
    flags: []const []const u8 = &.{},
    extra_files: []const []const u8 = &.{},
    global_assets: []const []const u8 = &.{},
    matrix: bool = false,
    /// The `in` key: null if absent, else one-or-more input filenames.
    in_spec: ?[]const []const u8 = null,
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) ![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var cur: ?*Entry = null;
    while (lines.next()) |raw| {
        const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[[test]]")) {
            try entries.append(arena, .{});
            cur = &entries.items[entries.items.len - 1];
            continue;
        }
        const e = cur orelse continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // An array may continue on following lines until the closing ']'.
        if (val.len > 0 and val[0] == '[' and std.mem.indexOfScalar(u8, val, ']') == null) {
            var acc: std.ArrayListUnmanaged(u8) = .empty;
            try acc.appendSlice(arena, val);
            while (lines.next()) |more| {
                const m = stripComment(std.mem.trim(u8, more, " \t\r"));
                try acc.append(arena, ' ');
                try acc.appendSlice(arena, m);
                if (std.mem.indexOfScalar(u8, m, ']') != null) break;
            }
            val = acc.items;
        }

        if (std.mem.eql(u8, key, "runner")) {
            e.runner = try unquote(arena, val);
        } else if (std.mem.eql(u8, key, "name")) {
            e.name = try unquote(arena, val);
        } else if (std.mem.eql(u8, key, "flags")) {
            e.flags = try parseArray(arena, val);
        } else if (std.mem.eql(u8, key, "extra-files")) {
            e.extra_files = try parseArray(arena, val);
        } else if (std.mem.eql(u8, key, "global-assets")) {
            e.global_assets = try parseArray(arena, val);
        } else if (std.mem.eql(u8, key, "matrix")) {
            e.matrix = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "in")) {
            if (val.len > 0 and val[0] == '[') {
                e.in_spec = try parseArray(arena, val);
            } else {
                const one = try arena.alloc([]const u8, 1);
                one[0] = try unquote(arena, val);
                e.in_spec = one;
            }
        }
    }
    return entries.items;
}

fn stripComment(line: []const u8) []const u8 {
    // No '#' occurs inside the quoted values in these manifests.
    const h = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return std.mem.trim(u8, line[0..h], " \t\r");
}

fn unquote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return arena.dupe(u8, t[1 .. t.len - 1]);
    return arena.dupe(u8, t);
}

fn parseArray(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    const open = std.mem.indexOfScalar(u8, s, '[') orelse return &.{};
    const close = std.mem.lastIndexOfScalar(u8, s, ']') orelse return &.{};
    if (close <= open + 1) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var items = std.mem.splitScalar(u8, s[open + 1 .. close], ',');
    while (items.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) continue;
        try out.append(arena, try unquote(arena, t));
    }
    return out.items;
}
