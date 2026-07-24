//! Small semantic terminal-UI primitives.
//!
//! This is intentionally narrower than ncurses: it owns the terminal grammar
//! shared by fix's inspector-like surfaces (alternate-screen lifecycle,
//! cursor placement, full-width chrome, semantic colors, dividers, and
//! ANSI-aware cell clipping). Applications remain responsible for content,
//! layout decisions, and input behavior.

const std = @import("std");
const color = @import("terminal_color.zig");

pub const CellWidthFn = *const fn (u21) u2;

pub const Role = enum {
    plain,
    muted,
    border,
    section,
    selection,
    selection_marker,
    name,
    chunk,
    /// The chunk hue, bold — the currently-open chunk keeps its identity color
    /// instead of switching to the green `current` used for live execution.
    chunk_current,
    object,
    current,
    range,
    source_focus,
};

pub const Chrome = enum { header, footer };

pub const Palette = struct {
    header_bg: color.Rgb = .{ 32, 72, 122 },
    footer_bg: color.Rgb = .{ 38, 148, 155 },
    light: color.Rgb = .{ 246, 248, 250 },
    dark: color.Rgb = .{ 15, 23, 30 },
    selection_bg: color.Rgb = .{ 78, 62, 112 },
    muted: color.Rgb = .{ 142, 151, 160 },
    border: color.Rgb = .{ 104, 118, 132 },
    section: color.Rgb = color.hueColor(2),
    name: color.Rgb = color.hueColor(4),
    chunk: color.Rgb = color.hueColor(7),
    object: color.Rgb = color.hueColor(13),
    current: color.Rgb = color.hueColor(1),
    range: color.Rgb = color.hueColor(10),
    source_focus: color.Rgb = color.hueColor(3),
};

pub const ScreenOptions = struct {
    alternate: bool = true,
    bracketed_paste: bool = false,
    cursor_visible: bool = false,
};

pub const Screen = struct {
    writer: *std.Io.Writer,
    options: ScreenOptions,

    pub fn enter(writer: *std.Io.Writer, options: ScreenOptions) !Screen {
        var self: Screen = .{ .writer = writer, .options = options };
        if (options.alternate) try writer.writeAll("\x1b[?1049h");
        if (options.bracketed_paste) try writer.writeAll("\x1b[?2004h");
        try self.cursor(options.cursor_visible);
        return self;
    }

    pub fn leave(self: *Screen) !void {
        try reset(self.writer);
        if (self.options.bracketed_paste) try self.writer.writeAll("\x1b[?2004l");
        if (self.options.alternate) try self.writer.writeAll("\x1b[?1049l");
        try self.cursor(true);
    }

    pub fn cursor(self: *Screen, visible: bool) !void {
        try self.writer.writeAll(if (visible) "\x1b[?25h" else "\x1b[?25l");
    }

    pub fn clear(self: *Screen) !void {
        try self.writer.writeAll("\x1b[H\x1b[2J");
    }
};

pub const Frame = struct {
    writer: *std.Io.Writer,
    depth: color.Depth,
    cell_width: CellWidthFn,
    palette: Palette = .{},

    pub fn init(writer: *std.Io.Writer, depth: color.Depth, cell_width: CellWidthFn) Frame {
        return .{ .writer = writer, .depth = depth, .cell_width = cell_width };
    }

    pub fn at(self: *Frame, row: usize, col: usize) !void {
        try self.writer.print("\x1b[{d};{d}H", .{ row, col });
    }

    pub fn clearRow(self: *Frame, row: usize) !void {
        try self.at(row, 1);
        try reset(self.writer);
        try self.writer.writeAll("\x1b[K");
    }

    pub fn cursor(self: *Frame, visible: bool) !void {
        try self.writer.writeAll(if (visible) "\x1b[?25h" else "\x1b[?25l");
    }

    pub fn text(self: *Frame, text_value: []const u8, start: usize, width: usize, role: Role) !void {
        try self.apply(role);
        try writeWindow(self.writer, text_value, start, width, self.cell_width);
        try reset(self.writer);
    }

    pub fn divider(self: *Frame, row: usize, col: usize) !void {
        try self.at(row, col);
        try self.text("│", 0, 1, .border);
    }

    pub fn bar(self: *Frame, row: usize, text_value: []const u8, width: usize, kind: Chrome) !void {
        try self.at(row, 1);
        try self.applyChrome(kind);
        try writeWindow(self.writer, text_value, 0, width, self.cell_width);
        const used = @min(displayWidth(text_value, self.cell_width), width);
        if (used < width) {
            // Content may itself contain a reset, so establish the chrome
            // background again before explicitly filling the terminal width.
            try self.applyChrome(kind);
            try self.writer.splatByteAll(' ', width - used);
        }
        try reset(self.writer);
    }

    fn apply(self: *Frame, role: Role) !void {
        if (role == .plain) return;
        if (!self.depth.enabled()) {
            switch (role) {
                .selection => try self.writer.writeAll("\x1b[7m"),
                .muted, .border => try self.writer.writeAll("\x1b[2m"),
                .section, .current, .source_focus, .selection_marker, .chunk_current => try self.writer.writeAll("\x1b[1m"),
                .name, .chunk, .object, .range, .plain => {},
            }
            return;
        }
        switch (role) {
            .plain => unreachable,
            .muted => try color.foreground(self.writer, self.depth, self.palette.muted, false),
            .border => try color.foreground(self.writer, self.depth, self.palette.border, false),
            .section => try color.foreground(self.writer, self.depth, self.palette.section, true),
            .selection => {
                try color.background(self.writer, self.depth, self.palette.selection_bg);
                try color.foreground(self.writer, self.depth, self.palette.light, true);
            },
            .selection_marker => try color.foreground(self.writer, self.depth, self.palette.source_focus, true),
            .name => try color.foreground(self.writer, self.depth, self.palette.name, false),
            .chunk => try color.foreground(self.writer, self.depth, self.palette.chunk, false),
            .chunk_current => try color.foreground(self.writer, self.depth, self.palette.chunk, true),
            .object => try color.foreground(self.writer, self.depth, self.palette.object, false),
            .current => try color.foreground(self.writer, self.depth, self.palette.current, true),
            .range => try color.foreground(self.writer, self.depth, self.palette.range, false),
            .source_focus => try color.foreground(self.writer, self.depth, self.palette.source_focus, true),
        }
    }

    fn applyChrome(self: *Frame, kind: Chrome) !void {
        if (!self.depth.enabled()) {
            try self.writer.writeAll("\x1b[7m");
            return;
        }
        switch (kind) {
            .header => {
                try color.background(self.writer, self.depth, self.palette.header_bg);
                try color.foreground(self.writer, self.depth, self.palette.light, true);
            },
            .footer => {
                try color.background(self.writer, self.depth, self.palette.footer_bg);
                try color.foreground(self.writer, self.depth, self.palette.dark, false);
            },
        }
    }
};

/// Encode one semantic role for components that retain a style prefix (for
/// example the multiline line editor). The returned slice points into `buf`.
pub fn roleCode(buf: []u8, depth: color.Depth, role: Role) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    var frame = Frame.init(&writer, depth, struct {
        fn width(_: u21) u2 {
            return 1;
        }
    }.width);
    try frame.apply(role);
    return writer.buffered();
}

pub fn displayWidth(text: []const u8, cell_width: CellWidthFn) usize {
    var i: usize = 0;
    var result: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = ansiSequenceEnd(text, i);
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const safe_len = if (i + len <= text.len) len else 1;
        const cp = std.unicode.utf8Decode(text[i .. i + safe_len]) catch 0xFFFD;
        result += if (cp == '\t') 1 else cell_width(cp);
        i += safe_len;
    }
    return result;
}

fn writeWindow(writer: *std.Io.Writer, text: []const u8, start: usize, width: usize, cell_width: CellWidthFn) !void {
    var i: usize = 0;
    var col: usize = 0;
    var written: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = ansiSequenceEnd(text, i);
            try writer.writeAll(text[i..end]);
            i = end;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const safe_len = if (i + len <= text.len) len else 1;
        const cp = std.unicode.utf8Decode(text[i .. i + safe_len]) catch 0xFFFD;
        const cells: usize = if (cp == '\t') 1 else cell_width(cp);
        if (col + cells <= start or col < start) {
            col += cells;
            i += safe_len;
            continue;
        }
        if (written + cells > width) break;
        try writer.writeAll(text[i .. i + safe_len]);
        written += cells;
        col += cells;
        i += safe_len;
    }
}

fn ansiSequenceEnd(text: []const u8, start: usize) usize {
    if (start + 1 >= text.len or text[start] != 0x1b) return @min(start + 1, text.len);
    if (text[start + 1] != '[') return @min(start + 2, text.len);
    var i = start + 2;
    while (i < text.len) : (i += 1) {
        if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
    }
    return text.len;
}

fn reset(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1b[0m");
}

test "full-width chrome pads after ANSI-aware clipping" {
    const width = struct {
        fn f(_: u21) u2 {
            return 1;
        }
    }.f;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame = Frame.init(&output.writer, .none, width);
    try frame.bar(1, " vm ", 8, .header);
    const plain = @import("terminal_text.zig").stripAnsiInPlace(output.written());
    try std.testing.expect(std.mem.indexOf(u8, plain, " vm     ") != null);
}

test "cell windows preserve ANSI sequences" {
    const width = struct {
        fn f(_: u21) u2 {
            return 1;
        }
    }.f;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame = Frame.init(&output.writer, .none, width);
    const line = "ab\x1b[31mcd\x1b[0mef";
    try std.testing.expectEqual(@as(usize, 6), displayWidth(line, width));
    try frame.text(line, 2, 3, .plain);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[31mcd\x1b[0me") != null);
}
