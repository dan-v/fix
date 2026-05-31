//! Structured diagnostics and source-span rendering.

const std = @import("std");
const TokenType = @import("token.zig").TokenType;

pub const Diagnostic = struct {
    pub const Severity = enum { err, note };
    pub const Kind = enum { parse, compile };

    severity: Severity = .err,
    kind: Kind = .parse,
    line: u32,
    column: u32,
    offset: u32,
    len: u32,
    token_type: ?TokenType,
    message: []const u8,
};

pub const LineSpan = struct {
    start: usize,
    end: usize,
};

pub fn lineForOffset(source: []const u8, offset: u32) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    const target = offsetTarget(source, offset);
    while (i < target) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

pub fn columnForOffset(source: []const u8, offset: u32) u32 {
    var line_start: usize = 0;
    var i: usize = 0;
    const target = offsetTarget(source, offset);
    while (i < target) : (i += 1) {
        if (source[i] == '\n') line_start = i + 1;
    }
    return @intCast(target - line_start + 1);
}

pub fn lineSpan(source: []const u8, offset: u32) LineSpan {
    const target = offsetTarget(source, offset);
    var start = target;
    while (start > 0 and source[start - 1] != '\n') {
        start -= 1;
    }

    var end = target;
    while (end < source.len and source[end] != '\n') {
        end += 1;
    }

    return .{ .start = start, .end = end };
}

pub fn writeAll(writer: *std.Io.Writer, source: []const u8, diagnostics: []const Diagnostic) !void {
    for (diagnostics) |diagnostic| {
        try writeOne(writer, source, diagnostic);
    }
}

fn writeOne(writer: *std.Io.Writer, source: []const u8, diagnostic: Diagnostic) !void {
    switch (diagnostic.severity) {
        .err => switch (diagnostic.kind) {
            .parse => try writer.print("error: parse error at {d}:{d}: {s}\n", .{
                diagnostic.line,
                diagnostic.column,
                diagnostic.message,
            }),
            .compile => try writer.print("error: {s} at {d}:{d}\n", .{
                diagnostic.message,
                diagnostic.line,
                diagnostic.column,
            }),
        },
        .note => try writer.print("note: {s} at {d}:{d}\n", .{
            diagnostic.message,
            diagnostic.line,
            diagnostic.column,
        }),
    }

    const source_line = lineSpan(source, diagnostic.offset);
    try writer.print("{d: >4} | {s}\n", .{ diagnostic.line, source[source_line.start..source_line.end] });
    try writer.writeAll("     | ");
    try writeSpaces(writer, diagnostic.column - 1);

    const caret_count = @max(@as(u32, 1), diagnostic.len);
    var i: u32 = 0;
    while (i < caret_count) : (i += 1) {
        try writer.writeByte('^');
    }

    if (diagnostic.token_type == null or diagnostic.token_type.? != .eof) {
        const start: usize = @intCast(diagnostic.offset);
        const len: usize = @intCast(diagnostic.len);
        if (start <= source.len and len <= source.len - start) {
            try writer.print(" near `{s}`", .{source[start .. start + len]});
        }
    }
    try writer.writeByte('\n');
}

fn writeSpaces(writer: *std.Io.Writer, count: u32) !void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

fn offsetTarget(source: []const u8, offset: u32) usize {
    return @min(@as(usize, @intCast(offset)), source.len);
}
