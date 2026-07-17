//! Terminal policy, styling, and synchronized stderr presentation.

const std = @import("std");
const terminal_color = @import("base").terminal_color;

pub const When = enum { auto, always, never };

pub const ProgressMode = enum { enabled, disabled };

pub const ProgressPolicy = struct {
    log: bool,

    pub fn enabled(self: ProgressPolicy) bool {
        return self.log;
    }
};

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

pub fn progressPolicy(mode: ProgressMode) ProgressPolicy {
    return switch (mode) {
        .disabled => .{ .log = false },
        .enabled => .{ .log = true },
    };
}

pub const Style = enum {
    name,
    path,
    dim,
    error_label,
    note_label,
    trace_label,
    success,
    warning,
};

pub const Rgb = terminal_color.Rgb;

/// Semantic verb identities. Ongoing and completed spellings of the same
/// operation deliberately share a color.
pub const Verb = enum {
    transform,
    evaluate,
    store,
    query,
    fetch,
    build,
};

pub fn styleCode(use_color: bool, which: Style) []const u8 {
    if (!use_color) return "";
    return switch (which) {
        .name => "\x1b[1m",
        .path => "\x1b[32m",
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

/// Prefix a durable record with elapsed time and its independently colored
/// source tag. Verb and noun colors are applied by the record writer.
pub fn writeLogPrefix(
    writer: *std.Io.Writer,
    io: std.Io,
    use_color: bool,
    started_at: std.Io.Timestamp,
    tag: []const u8,
) !void {
    const now = std.Io.Clock.awake.now(io);
    const elapsed_ns = now.nanoseconds - started_at.nanoseconds;
    const elapsed_ms: u64 = if (elapsed_ns <= 0) 0 else @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
    try style(writer, use_color, .dim);
    try writeElapsedTimestamp(writer, elapsed_ms);
    try reset(writer, use_color);
    try writer.writeByte(' ');
    try terminal_color.foreground(writer, use_color, systemColor(tag), false);
    try writer.print("[{s}]", .{tag});
    try reset(writer, use_color);
    try writer.writeByte(' ');
}

fn writeElapsedTimestamp(writer: *std.Io.Writer, elapsed_ms: u64) !void {
    try writer.print("[{d:>8}ms]", .{elapsed_ms});
}

pub fn foreground(writer: *std.Io.Writer, use_color: bool, color: Rgb, bold: bool) !void {
    try terminal_color.foreground(writer, use_color, color, bold);
}

pub fn verbColor(verb: Verb) Rgb {
    return terminal_color.hueColor(@intFromEnum(verb));
}

pub fn nounColor(noun: []const u8) Rgb {
    return terminal_color.stableColor(0x6e6f_756e, noun);
}

pub fn systemColor(system: []const u8) Rgb {
    // Keep the small, user-facing system vocabulary at deliberately separated
    // points in the shared palette. Unknown producers still get an identity
    // color without needing to extend this presentation layer first.
    if (std.mem.eql(u8, system, "eval")) return terminal_color.hueColor(2);
    if (std.mem.eql(u8, system, "daemon")) return terminal_color.hueColor(4);
    if (std.mem.eql(u8, system, "fetch")) return terminal_color.hueColor(3);
    if (std.mem.eql(u8, system, "build")) return terminal_color.hueColor(1);
    return terminal_color.stableColor(0x7379_7374, system);
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

test "parse terminal policy" {
    try std.testing.expectEqual(When.auto, parseWhen("auto").?);
    try std.testing.expect(parseWhen("sometimes") == null);
    try std.testing.expect(progressPolicy(.enabled).log);
    try std.testing.expect(!progressPolicy(.disabled).enabled());
}

test "log timestamps are space-padded elapsed milliseconds" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeElapsedTimestamp(&writer, 12);
    try std.testing.expectEqualStrings("[      12ms]", writer.buffered());
}
