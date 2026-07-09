//! Interactive REPL: the raw-mode line editor and the read-eval-print loop.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const run = @import("run.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const Options = @import("args.zig").Options;
const Evaluator = @import("fix").Evaluator;

pub const usage =
    \\usage: fix repl [options]
    \\
    \\start an interactive read-eval-print loop.
    \\
    \\options:
    \\  --json / --xml / --strict     result output format
    \\  --experimental-features FEATS / --extra-experimental-features FEATS
    \\  --show-trace                  show full evaluation traces on error
    \\  --color[=when] / --no-color
    \\  --progress[=when] / --no-progress
    \\  -h, --help                    show this help
    \\
;

/// `fix repl` subcommand entry point.
pub fn run_cmd(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const options = args.parse(args_iter, null) catch |err| switch (err) {
        error.Help => {
            cli.printHelp(init.io, usage);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}", .{ args.errorMessage(err), usage });
            return 2;
        },
    };
    if (options.source != null) {
        std.debug.print("error: repl takes no expression, file, or flake\n\n{s}", .{usage});
        return 2;
    }

    const worker_count = try setup.workerCount(options);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);

    var progress = cli.EvalProgress.init(init.io, term.show_progress);
    var repl_ok = false;
    defer progress.deinit(repl_ok);
    if (term.show_progress) ev.setProgressSink(progress.sink());
    try run_loop(allocator, init.io, options, term.use_color, &ev);
    repl_ok = true;
    return 0;
}

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

/// The read-eval-print loop. Uses the raw-mode editor when stdin/stdout are a
/// TTY, falling back to canonical line reads otherwise.
pub fn run_loop(allocator: std.mem.Allocator, io: std.Io, options: Options, use_color: bool, ev: *Evaluator) !void {
    const interactive = (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);

    if (interactive) {
        try stdout.interface.writeAll("fix repl\n");
        try stdout.interface.flush();
    }

    var history = History.init(allocator);
    defer history.deinit();
    var raw_editor = interactive;

    while (true) {
        var owned_line: ?[]u8 = null;
        const line = if (raw_editor) line: {
            const maybe_line = readInteractiveAlloc(allocator, io, "fix> ", use_color, &history) catch |err| switch (err) {
                error.UnsupportedTerminal => {
                    raw_editor = false;
                    break :line try readCanonicalReplLine(io, use_color, interactive, &stdin.interface, &stdout.interface) orelse break;
                },
                else => return err,
            };
            owned_line = maybe_line orelse break;
            break :line owned_line.?;
        } else line: {
            break :line try readCanonicalReplLine(io, use_color, interactive, &stdin.interface, &stdout.interface) orelse break;
        };
        defer if (owned_line) |owned| allocator.free(owned);

        const source = std.mem.trim(u8, line, " \t\r");
        if (source.len == 0) continue;

        if (!raw_editor) {
            try history.add(source);
        }

        if (std.mem.eql(u8, source, ":q") or
            std.mem.eql(u8, source, ":quit") or
            std.mem.eql(u8, source, ":exit"))
        {
            break;
        }
        if (std.mem.eql(u8, source, ":help")) {
            try writeReplHelp(&stdout.interface);
            try stdout.interface.flush();
            continue;
        }

        _ = try run.evaluateAndWrite(io, options.evaluationMode(), use_color, options.show_trace, options.derivation_debug, ev, source, "input");
    }
}

fn readCanonicalReplLine(
    io: std.Io,
    use_color: bool,
    interactive: bool,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
) !?[]const u8 {
    if (interactive) {
        try cli.style(stdout, use_color, .trace_label);
        try stdout.writeAll("fix> ");
        try cli.reset(stdout, use_color);
        try stdout.flush();
    }

    const raw_line = stdin.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            try writeReplInputError(io, use_color, "input line is too long");
            _ = stdin.discardDelimiterInclusive('\n') catch {};
            return "";
        },
        else => return err,
    };
    return raw_line;
}

fn writeReplHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\:help   show commands
        \\:q      exit
        \\:quit   exit
        \\
    );
}

fn writeReplInputError(io: std.Io, use_color: bool, message: []const u8) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = try cli.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    const writer = stderr.writer();
    try cli.style(writer, use_color, .error_label);
    try writer.writeAll("error");
    try cli.reset(writer, use_color);
    try writer.print(": {s}\n", .{message});
    try stderr.flush();
}
