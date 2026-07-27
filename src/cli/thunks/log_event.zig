//! Parser for one line of the evaluator's thunk event log.

const std = @import("std");

pub const Event = struct {
    seq: u64,
    kind: Kind,
    thunk: u32,
    // create-only:
    creator_file: []const u8,
    creator_line: u32,
    creator_col: u32,
    target_file: []const u8,
    target_line: u32,
    target_col: u32,
    // resolve/errored/reset-only:
    disc: []const u8,
    value: []const u8,
    err: []const u8,
    message: []const u8,

    pub const Kind = enum { create, resolve, errored, reset, claim, blackhole, other };
};

pub fn parse(line: []const u8) ?Event {
    var event: Event = .{
        .seq = 0,
        .kind = .other,
        .thunk = 0,
        .creator_file = "",
        .creator_line = 0,
        .creator_col = 0,
        .target_file = "",
        .target_line = 0,
        .target_col = 0,
        .disc = "",
        .value = "",
        .err = "",
        .message = "",
    };

    // seq, kind, thunk are always the first three fields and contain
    // no spaces in their values; parse them positionally.
    var rest = line;
    rest = consumePrefix(rest, "seq=") orelse return null;
    event.seq = parseUntilSpace(u64, &rest) orelse return null;
    rest = skipSpace(rest);
    rest = consumePrefix(rest, "kind=") orelse return null;
    const kind = takeUntilSpace(&rest);
    event.kind = if (std.mem.eql(u8, kind, "create"))
        .create
    else if (std.mem.eql(u8, kind, "resolve"))
        .resolve
    else if (std.mem.eql(u8, kind, "errored"))
        .errored
    else if (std.mem.eql(u8, kind, "reset"))
        .reset
    else if (std.mem.eql(u8, kind, "claim"))
        .claim
    else if (std.mem.eql(u8, kind, "blackhole"))
        .blackhole
    else
        .other;
    rest = skipSpace(rest);
    rest = consumePrefix(rest, "thunk=") orelse return null;
    event.thunk = parseUntilSpace(u32, &rest) orelse return null;

    // Remaining fields can contain spaces, so extract each by name with a
    // terminator suited to its shape.
    switch (event.kind) {
        .create => {
            if (findFieldValue(line, " creator=")) |value|
                parseLocation(value, &event.creator_file, &event.creator_line, &event.creator_col);
            if (findFieldValue(line, " target_at=")) |value|
                parseLocation(value, &event.target_file, &event.target_line, &event.target_col);
        },
        .resolve => {
            if (findFieldRaw(line, " disc=")) |value| event.disc = trimToSpace(value);
            if (std.mem.indexOf(u8, line, " value=")) |index|
                event.value = line[index + " value=".len ..];
        },
        .errored => {
            if (findFieldRaw(line, " err=")) |value| event.err = takeQuoted(value);
            if (findFieldRaw(line, " message=")) |value| event.message = takeQuoted(value);
        },
        .reset => {
            if (findFieldRaw(line, " err=")) |value| event.err = takeQuoted(value);
        },
        .claim, .blackhole, .other => {},
    }
    return event;
}

/// Parse `"file":line:col`. Tolerates the unknown-source sentinel
/// `"?":L:C`. Outputs retain their original values on parse failure.
pub fn parseLocation(text: []const u8, file: *[]const u8, line: *u32, column: *u32) void {
    if (text.len < 3 or text[0] != '"') return;
    var end_quote: usize = 1;
    while (end_quote < text.len and text[end_quote] != '"') : (end_quote += 1) {}
    if (end_quote >= text.len) return;
    file.* = text[1..end_quote];
    var rest = text[end_quote + 1 ..];
    if (rest.len == 0 or rest[0] != ':') return;
    rest = rest[1..];
    const separator = std.mem.indexOfScalar(u8, rest, ':') orelse return;
    line.* = std.fmt.parseInt(u32, rest[0..separator], 10) catch return;
    column.* = std.fmt.parseInt(u32, rest[separator + 1 ..], 10) catch 0;
}

fn findFieldRaw(line: []const u8, key: []const u8) ?[]const u8 {
    const index = std.mem.indexOf(u8, line, key) orelse return null;
    return line[index + key.len ..];
}

fn findFieldValue(line: []const u8, key: []const u8) ?[]const u8 {
    return trimToSpace(findFieldRaw(line, key) orelse return null);
}

fn trimToSpace(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and text[end] != ' ' and text[end] != '\t') : (end += 1) {}
    return text[0..end];
}

fn takeQuoted(text: []const u8) []const u8 {
    if (text.len == 0 or text[0] != '"') return trimToSpace(text);
    var end: usize = 1;
    while (end < text.len) : (end += 1) {
        if (text[end] == '\\' and end + 1 < text.len) {
            end += 1;
            continue;
        }
        if (text[end] == '"') return text[1..end];
    }
    return text[1..];
}

fn consumePrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

fn skipSpace(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and (text[start] == ' ' or text[start] == '\t')) : (start += 1) {}
    return text[start..];
}

fn takeUntilSpace(text: *[]const u8) []const u8 {
    var end: usize = 0;
    while (end < text.*.len and text.*[end] != ' ' and text.*[end] != '\t') : (end += 1) {}
    const value = text.*[0..end];
    text.* = text.*[end..];
    return value;
}

fn parseUntilSpace(comptime T: type, text: *[]const u8) ?T {
    return std.fmt.parseInt(T, takeUntilSpace(text), 10) catch null;
}
