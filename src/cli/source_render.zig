//! Shared, allocation-free Nix source-line rendering for terminal frontends.
//! Token color and an exact byte-range focus are composed in one pass so a
//! debugger can emphasize an expression without painting its whole line.

const std = @import("std");
const syntax = @import("syntax");

const TokenType = syntax.token.TokenType;

const col_keyword = "\x1b[35m";
const col_string = "\x1b[32m";
const col_number = "\x1b[33m";
const focus = "\x1b[4;7m";
const reset = "\x1b[0m";

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Options = struct {
    color: bool,
    /// Byte range relative to `line`. Empty and out-of-bounds ranges are
    /// ignored. Focus uses terminal attributes even when color is disabled.
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
        if (start > last) try writeSpan(w, line, last, start, null, selected);
        try writeSpan(w, line, start, end, if (options.color) tokenColor(token.type) else null, selected);
        last = end;
    }
    if (last < line.len) try writeSpan(w, line, last, line.len, null, selected);
}

fn writeSpan(
    w: *std.Io.Writer,
    line: []const u8,
    start: usize,
    end: usize,
    color: ?[]const u8,
    selected: ?Range,
) !void {
    if (start >= end) return;
    if (selected) |range| {
        const selected_start = @max(start, range.start);
        const selected_end = @min(end, range.end);
        if (selected_start < selected_end) {
            if (start < selected_start) try styled(w, line[start..selected_start], color, false);
            try styled(w, line[selected_start..selected_end], color, true);
            if (selected_end < end) try styled(w, line[selected_end..end], color, false);
            return;
        }
    }
    try styled(w, line[start..end], color, false);
}

fn styled(w: *std.Io.Writer, text: []const u8, color: ?[]const u8, selected: bool) !void {
    if (selected) try w.writeAll(focus);
    if (color) |code| try w.writeAll(code);
    try writeSafe(w, text);
    if (selected or color != null) try w.writeAll(reset);
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

fn tokenColor(token: TokenType) ?[]const u8 {
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
        .color = true,
        .focus = .{ .start = 3, .end = 7 },
    });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[4;7m\x1b[35mtrue") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[33m42") != null);
}

test "source focus outside a token does not duplicate its text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeLine(&output.writer, "if true", .{
        .color = false,
        .focus = .{ .start = 3, .end = 7 },
    });
    const plain = @import("base").terminal_text.stripAnsiInPlace(output.written());
    try std.testing.expectEqualStrings("if true", plain);
}
