//! Terminal policy, styling, and synchronized stderr presentation.

const std = @import("std");

pub const When = enum { auto, always, never };

pub fn parseWhen(text: []const u8) ?When {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

pub fn printHelp(io: std.Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    writer.interface.writeAll(text) catch return;
    writer.interface.flush() catch {};
}

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

pub fn isStderrInteractive(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("TERM")) |term| if (std.mem.eql(u8, term, "dumb")) return false;
    return std.Io.File.stderr().isTty(io) catch false;
}

pub fn shouldColor(mode: When, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => autoColor(isStderrInteractive(io, env), env),
    };
}

pub fn autoColor(interactive: bool, env: *const std.process.Environ.Map) bool {
    return interactive and env.get("NO_COLOR") == null;
}

pub fn shouldProgress(mode: When, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => isStderrInteractive(io, env),
    };
}

pub const Style = enum {
    heading,
    section,
    label,
    name,
    path,
    hash,
    dim,
    error_label,
    note_label,
    trace_label,
    success,
    warning,
};

pub const Accent = enum {
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
};

pub fn styleCode(use_color: bool, which: Style) []const u8 {
    if (!use_color) return "";
    return switch (which) {
        .heading => "\x1b[1;35m",
        .section => "\x1b[1;36m",
        .label => "\x1b[36m",
        .name => "\x1b[1m",
        .path => "\x1b[32m",
        .hash => "\x1b[33m",
        .dim => "\x1b[2m",
        .error_label => "\x1b[1;31m",
        .note_label => "\x1b[1;36m",
        .trace_label => "\x1b[36m",
        .success => "\x1b[32m",
        .warning => "\x1b[33m",
    };
}

pub fn resetCode(use_color: bool) []const u8 {
    return if (use_color) "\x1b[0m" else "";
}

pub fn style(writer: *std.Io.Writer, use_color: bool, which: Style) !void {
    if (use_color) try writer.writeAll(styleCode(true, which));
}

pub fn reset(writer: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try writer.writeAll(resetCode(true));
}

pub fn accent(writer: *std.Io.Writer, use_color: bool, which: Accent, bold: bool) !void {
    if (!use_color) return;
    const code: u8 = switch (which) {
        .red => '1',
        .green => '2',
        .yellow => '3',
        .blue => '4',
        .magenta => '5',
        .cyan => '6',
    };
    if (bold) try writer.writeAll("\x1b[1;3") else try writer.writeAll("\x1b[3");
    try writer.writeByte(code);
    try writer.writeByte('m');
}

pub fn writeLabel(writer: *std.Io.Writer, use_color: bool, label: []const u8) !void {
    try style(writer, use_color, .label);
    try writer.writeAll(label);
    try reset(writer, use_color);
}

pub const Stderr = struct {
    io: std.Io,
    locked: std.Io.LockedStderr,

    pub fn writer(self: *Stderr) *std.Io.Writer {
        return &self.locked.file_writer.interface;
    }

    pub fn flush(self: *Stderr) !void {
        try self.writer().flush();
    }

    pub fn deinit(self: *Stderr) void {
        self.io.unlockStderr();
    }
};

pub fn lockStderr(io: std.Io, buffer: []u8) std.Io.Cancelable!Stderr {
    return .{ .io = io, .locked = try io.lockStderr(buffer, null) };
}

pub fn writeMaybePath(writer: *std.Io.Writer, use_color: bool, value: []const u8) !void {
    const is_path = isPathLike(value);
    if (is_path) try style(writer, use_color, .path);
    try writer.writeAll(value);
    if (is_path) try reset(writer, use_color);
}

pub fn isPathLike(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "/nix/store/") or std.mem.endsWith(u8, value, ".drv");
}

test "parse terminal policy" {
    try std.testing.expectEqual(When.auto, parseWhen("auto").?);
    try std.testing.expect(parseWhen("sometimes") == null);
}
