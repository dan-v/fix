const std = @import("std");
const main = @import("../integration_diff.zig");
const Classification = main.Classification;
const Config = main.Config;
const Outcome = main.Outcome;

pub const ShrinkCandidates = std.ArrayListUnmanaged([]const u8);

pub const ClassifyFn = *const fn (std.mem.Allocator, std.Io, *const Config, []const u8) anyerror!Classification;

pub fn shrinkInteresting(
    allocator: std.mem.Allocator,
    io: std.Io,
    classify: ClassifyFn,
    config: *const Config,
    expr: []const u8,
    target: Outcome,
) ![]u8 {
    var current = try allocator.dupe(u8, expr);
    errdefer allocator.free(current);

    var changed = true;
    while (changed) {
        changed = false;

        var candidates: ShrinkCandidates = .empty;
        defer {
            for (candidates.items) |candidate| allocator.free(candidate);
            candidates.deinit(allocator);
        }
        try candidatesFor(allocator, current, &candidates);

        for (candidates.items) |candidate| {
            if (candidate.len == 0 or candidate.len >= current.len) continue;
            var c = try classify(allocator, io, config, candidate);
            defer c.deinit(allocator);
            if (c.outcome == target) {
                allocator.free(current);
                current = try allocator.dupe(u8, candidate);
                changed = true;
                break;
            }
        }
    }

    return current;
}

pub fn candidatesFor(allocator: std.mem.Allocator, expr: []const u8, out: *ShrinkCandidates) !void {
    const constants = [_][]const u8{ "1", "true", "false", "null", "[]", "{}" };
    for (constants) |constant| try out.append(allocator, try allocator.dupe(u8, constant));

    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')' and balanced(trimmed[1 .. trimmed.len - 1])) {
        try out.append(allocator, try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]));
    }

    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        if (expr[i] != '(' and expr[i] != '[' and expr[i] != '{') continue;
        if (matchingClose(expr[i])) |close| {
            if (findMatching(expr, i, close)) |end| {
                try out.append(allocator, try std.mem.concat(allocator, u8, &.{ expr[0..i], "1", expr[end + 1 ..] }));
            }
        }
    }
}

fn matchingClose(open: u8) ?u8 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

fn findMatching(expr: []const u8, start: usize, close: u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == expr[start]) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn balanced(expr: []const u8) bool {
    var parens: isize = 0;
    var brackets: isize = 0;
    var braces: isize = 0;
    var in_string = false;

    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => parens += 1,
            ')' => parens -= 1,
            '[' => brackets += 1,
            ']' => brackets -= 1,
            '{' => braces += 1,
            '}' => braces -= 1,
            else => {},
        }
        if (parens < 0 or brackets < 0 or braces < 0) return false;
    }
    return !in_string and parens == 0 and brackets == 0 and braces == 0;
}
