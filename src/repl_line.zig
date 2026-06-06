//! Minimal raw-mode line editor for the interactive REPL.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

pub const History = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged([]u8) = .empty,
    max_items: usize = 100,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *History, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.items.items.len != 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], line)) return;

        if (self.items.items.len >= self.max_items) {
            self.allocator.free(self.items.items[0]);
            std.mem.copyForwards([]u8, self.items.items[0 .. self.items.items.len - 1], self.items.items[1..]);
            _ = self.items.pop();
        }
        try self.items.append(self.allocator, try self.allocator.dupe(u8, line));
    }
};

pub const ReadError = error{
    EndOfStream,
    UnsupportedTerminal,
    StreamTooLong,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    NotATerminal,
    ProcessOrphaned,
    Unexpected,
};

pub fn readInteractiveAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompt: []const u8,
    use_color: bool,
    history: *History,
) !?[]u8 {
    var raw = RawMode.enable() catch |err| switch (err) {
        error.UnsupportedTerminal => return error.UnsupportedTerminal,
        else => return err,
    };
    defer raw.disable();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const writer = &stdout.interface;

    var editor = Editor{
        .allocator = allocator,
        .io = io,
        .writer = writer,
        .prompt = prompt,
        .use_color = use_color,
        .history = history,
        .history_pos = history.items.items.len,
    };
    defer editor.deinit();

    try editor.render();
    const result = try editor.read();
    try writer.flush();
    return result;
}

const RawMode = struct {
    original: std.posix.termios,
    enabled: bool = false,

    fn enable() ReadError!RawMode {
        if (builtin.os.tag != .linux) return error.UnsupportedTerminal;

        const fd = std.posix.STDIN_FILENO;
        const original = try std.posix.tcgetattr(fd);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .original = original, .enabled = true };
    }

    fn disable(self: *RawMode) void {
        if (!self.enabled) return;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.enabled = false;
    }
};

const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    prompt: []const u8,
    use_color: bool,
    history: *History,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    saved: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,
    history_pos: usize,

    fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
        self.saved.deinit(self.allocator);
    }

    fn read(self: *Editor) !?[]u8 {
        while (true) {
            const byte = try readByte();
            switch (byte) {
                '\r', '\n' => {
                    try self.writer.writeAll("\r\n");
                    const line = try self.allocator.dupe(u8, self.buffer.items);
                    try self.history.add(line);
                    return line;
                },
                1 => self.cursor = 0, // Ctrl-A
                5 => self.cursor = self.buffer.items.len, // Ctrl-E
                4 => if (self.buffer.items.len == 0) { // Ctrl-D
                    try self.writer.writeAll("\r\n");
                    return null;
                },
                11 => self.buffer.shrinkRetainingCapacity(self.cursor), // Ctrl-K
                12 => { // Ctrl-L
                    try self.writer.writeAll("\x1b[H\x1b[2J");
                },
                21 => { // Ctrl-U
                    self.buffer.clearRetainingCapacity();
                    self.cursor = 0;
                },
                8, 127 => try self.backspace(),
                27 => try self.escape(),
                else => {
                    if (byte >= 32 and byte != 127) try self.insertByte(byte);
                },
            }
            try self.render();
        }
    }

    fn escape(self: *Editor) !void {
        const first = readByte() catch return;
        if (first != '[') return;
        const second = readByte() catch return;
        switch (second) {
            'A' => try self.historyUp(),
            'B' => try self.historyDown(),
            'C' => {
                if (self.cursor < self.buffer.items.len) self.cursor += 1;
            },
            'D' => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            'H' => self.cursor = 0,
            'F' => self.cursor = self.buffer.items.len,
            '1', '7' => {
                const terminator = readByte() catch return;
                if (terminator == '~') self.cursor = 0;
            },
            '4', '8' => {
                const terminator = readByte() catch return;
                if (terminator == '~') self.cursor = self.buffer.items.len;
            },
            '3' => {
                const terminator = readByte() catch return;
                if (terminator == '~') try self.deleteAtCursor();
            },
            else => {},
        }
    }

    fn insertByte(self: *Editor, byte: u8) !void {
        try self.buffer.insert(self.allocator, self.cursor, byte);
        self.cursor += 1;
    }

    fn backspace(self: *Editor) !void {
        if (self.cursor == 0) return;
        _ = self.buffer.orderedRemove(self.cursor - 1);
        self.cursor -= 1;
    }

    fn deleteAtCursor(self: *Editor) !void {
        if (self.cursor >= self.buffer.items.len) return;
        _ = self.buffer.orderedRemove(self.cursor);
    }

    fn historyUp(self: *Editor) !void {
        if (self.history.items.items.len == 0 or self.history_pos == 0) return;
        if (self.history_pos == self.history.items.items.len) try self.saveCurrent();
        self.history_pos -= 1;
        try self.loadText(self.history.items.items[self.history_pos]);
    }

    fn historyDown(self: *Editor) !void {
        if (self.history_pos >= self.history.items.items.len) return;
        self.history_pos += 1;
        if (self.history_pos == self.history.items.items.len) {
            try self.loadText(self.saved.items);
        } else {
            try self.loadText(self.history.items.items[self.history_pos]);
        }
    }

    fn saveCurrent(self: *Editor) !void {
        self.saved.clearRetainingCapacity();
        try self.saved.appendSlice(self.allocator, self.buffer.items);
    }

    fn loadText(self: *Editor, text: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, text);
        self.cursor = self.buffer.items.len;
    }

    fn render(self: *Editor) !void {
        try self.writer.writeAll("\r\x1b[2K");
        try cli.style(self.writer, self.use_color, .trace_label);
        try self.writer.writeAll(self.prompt);
        try cli.reset(self.writer, self.use_color);
        try self.writer.writeAll(self.buffer.items);
        if (self.buffer.items.len > self.cursor) {
            try self.writer.print("\x1b[{}D", .{self.buffer.items.len - self.cursor});
        }
        try self.writer.flush();
    }
};

fn readByte() !u8 {
    var buf: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        return buf[0];
    }
}
