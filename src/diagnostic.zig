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

pub const RenderOptions = struct {
    color: bool = false,
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
    try writeAllWithOptions(writer, source, diagnostics, .{});
}

pub fn writeAllWithOptions(writer: *std.Io.Writer, source: []const u8, diagnostics: []const Diagnostic, options: RenderOptions) !void {
    for (diagnostics) |diagnostic| {
        try writeOne(writer, source, diagnostic, options);
    }
}

fn writeOne(writer: *std.Io.Writer, source: []const u8, diagnostic: Diagnostic, options: RenderOptions) !void {
    switch (diagnostic.severity) {
        .err => switch (diagnostic.kind) {
            .parse => {
                try style(writer, options, .error_label);
                try writer.writeAll("error");
                try reset(writer, options);
                try writer.print(": parse error at {d}:{d}: {s}\n", .{
                    diagnostic.line,
                    diagnostic.column,
                    diagnostic.message,
                });
            },
            .compile => {
                try style(writer, options, .error_label);
                try writer.writeAll("error");
                try reset(writer, options);
                try writer.print(": {s} at {d}:{d}\n", .{
                    diagnostic.message,
                    diagnostic.line,
                    diagnostic.column,
                });
            },
        },
        .note => {
            try style(writer, options, .note_label);
            try writer.writeAll("note");
            try reset(writer, options);
            try writer.print(": {s} at {d}:{d}\n", .{
                diagnostic.message,
                diagnostic.line,
                diagnostic.column,
            });
        },
    }

    const source_line = lineSpan(source, diagnostic.offset);
    try style(writer, options, .gutter);
    try writer.print("{d: >4} | {s}\n", .{ diagnostic.line, source[source_line.start..source_line.end] });
    try writer.writeAll("     | ");
    try reset(writer, options);
    try writeSpaces(writer, diagnostic.column - 1);

    try style(writer, options, if (diagnostic.severity == .err) .error_caret else .note_caret);
    const caret_count = @max(@as(u32, 1), diagnostic.len);
    var i: u32 = 0;
    while (i < caret_count) : (i += 1) {
        try writer.writeByte('^');
    }
    try reset(writer, options);

    if (diagnostic.token_type == null or diagnostic.token_type.? != .eof) {
        const start: usize = @intCast(diagnostic.offset);
        const len: usize = @intCast(diagnostic.len);
        if (start <= source.len and len <= source.len - start) {
            try style(writer, options, .near);
            try writer.print(" near `{s}`", .{source[start .. start + len]});
            try reset(writer, options);
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

const Style = enum {
    error_label,
    note_label,
    error_caret,
    note_caret,
    gutter,
    near,
};

fn style(writer: *std.Io.Writer, options: RenderOptions, which: Style) !void {
    if (!options.color) return;
    try writer.writeAll(switch (which) {
        .error_label => "\x1b[1;31m",
        .note_label => "\x1b[1;36m",
        .error_caret => "\x1b[31m",
        .note_caret => "\x1b[36m",
        .gutter => "\x1b[2m",
        .near => "\x1b[2m",
    });
}

fn reset(writer: *std.Io.Writer, options: RenderOptions) !void {
    if (options.color) try writer.writeAll("\x1b[0m");
}
