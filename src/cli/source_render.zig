//! Shared, allocation-free Nix source-line rendering for terminal frontends.
//! Token color and an exact byte-range focus are composed in one pass so a
//! debugger can emphasize an expression without painting its whole line.

const std = @import("std");
const terminal_color = @import("base").terminal_color;
const syntax = @import("syntax");

const TokenType = syntax.token.TokenType;

const col_keyword: terminal_color.Rgb = .{ 210, 143, 240 };
const col_string: terminal_color.Rgb = .{ 111, 201, 145 };
const col_number: terminal_color.Rgb = .{ 229, 192, 123 };
const col_focus = terminal_color.hueColor(3);
const focus_underline = "\x1b[4m";
const reset = "\x1b[0m";

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Options = struct {
    color_depth: terminal_color.Depth,
    /// Byte range relative to `line`. Empty and out-of-bounds ranges are
    /// ignored. Focus falls back to an underline when color is disabled.
    focus: ?Range = null,
};

pub fn writeLine(w: *std.Io.Writer, line: []const u8, options: Options) !void {
    const selected = if (options.focus) |range| Range{
        .start = @min(range.start, line.len),
        .end = @min(@max(range.end, range.start), line.len),
    } else null;

    var scanner = syntax.scanner.Scanner.init(line);
    var last: usize = 0;
    while (true) {
        const token = scanner.next();
        if (token.type == .eof) break;
        const start = @min(token.offset, line.len);
        const end = @min(token.offset +| token.len, line.len);
        if (end <= last) break;
        if (start > last) try writeSpan(w, line, last, start, null, selected, options.color_depth);
        try writeSpan(w, line, start, end, tokenColor(token.type), selected, options.color_depth);
        last = end;
    }
    if (last < line.len) try writeSpan(w, line, last, line.len, null, selected, options.color_depth);
}

fn writeSpan(
    w: *std.Io.Writer,
    line: []const u8,
    start: usize,
    end: usize,
    color: ?terminal_color.Rgb,
    selected: ?Range,
    color_depth: terminal_color.Depth,
) !void {
    if (start >= end) return;
    if (selected) |range| {
        const selected_start = @max(start, range.start);
        const selected_end = @min(end, range.end);
        if (selected_start < selected_end) {
            if (start < selected_start) try styled(w, line[start..selected_start], color, false, color_depth);
            try styled(w, line[selected_start..selected_end], color, true, color_depth);
            if (selected_end < end) try styled(w, line[selected_end..end], color, false, color_depth);
            return;
        }
    }
    try styled(w, line[start..end], color, false, color_depth);
}

fn styled(
    w: *std.Io.Writer,
    text: []const u8,
    color: ?terminal_color.Rgb,
    selected: bool,
    color_depth: terminal_color.Depth,
) !void {
    if (selected) {
        try terminal_color.foreground(w, color_depth, col_focus, false);
        try w.writeAll(focus_underline);
    } else if (color) |rgb| {
        try terminal_color.foreground(w, color_depth, rgb, false);
    }
    try writeSafe(w, text);
    if (selected or (color != null and color_depth.enabled())) try w.writeAll(reset);
}

fn writeSafe(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '\t' => try w.writeAll("    "),
        '\r' => {},
        0x1b => try w.writeAll("␛"),
        0...8, 10...12, 14...26, 28...0x1f, 0x7f => try w.writeByte('?'),
        else => try w.writeByte(byte),
    };
}

fn tokenColor(token: TokenType) ?terminal_color.Rgb {
    return switch (token) {
        .kw_if, .kw_then, .kw_else, .kw_assert, .kw_with, .kw_let, .kw_in, .kw_rec, .kw_inherit, .kw_or, .kw_true, .kw_false, .kw_null => col_keyword,
        .string, .path, .search_path => col_string,
        .integer, .float_val => col_number,
        else => null,
    };
}

test "source rendering composes token color with an exact focus" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeLine(&output.writer, "if true then 42", .{
        .color_depth = .truecolor,
        .focus = .{ .start = 3, .end = 7 },
    });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[38;2;210;143;240mif") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[4mtrue") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[38;2;229;192;123m42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[7m") == null);
}

test "source focus outside a token does not duplicate its text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeLine(&output.writer, "if true", .{
        .color_depth = .none,
        .focus = .{ .start = 3, .end = 7 },
    });
    const plain = @import("base").terminal_text.stripAnsiInPlace(output.written());
    try std.testing.expectEqualStrings("if true", plain);
}
