//! Terminal policy, styling, and synchronized stderr presentation.

const std = @import("std");

pub const When = enum { auto, always, never };

pub const ProgressMode = enum { auto, log, disabled };

pub const ProgressPolicy = struct {
    show: bool,
    log: bool,

    pub fn enabled(self: ProgressPolicy) bool {
        return self.show or self.log;
    }
};

pub fn parseWhen(text: []const u8) ?When {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

pub fn parseProgressMode(text: []const u8) ?ProgressMode {
    if (std.mem.eql(u8, text, "log")) return .log;
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

pub fn progressPolicy(mode: ProgressMode, io: std.Io, env: *const std.process.Environ.Map) ProgressPolicy {
    return progressPolicyForTerminal(mode, isStderrInteractive(io, env));
}

pub fn progressPolicyForTerminal(mode: ProgressMode, interactive: bool) ProgressPolicy {
    return switch (mode) {
        .disabled => .{ .show = false, .log = false },
        .log => .{ .show = false, .log = true },
        .auto => if (interactive)
            .{ .show = true, .log = false }
        else
            .{ .show = false, .log = true },
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

pub fn stableNounAccent(noun: []const u8) Accent {
    // Keep noun colors disjoint from the progress-verb palette so grammar is
    // still obvious when both spans are adjacent.
    const palette = [_]Accent{ .red, .yellow, .blue };
    return palette[std.hash.Wyhash.hash(0, noun) % palette.len];
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
    try std.testing.expectEqual(ProgressMode.log, parseProgressMode("log").?);
    try std.testing.expect(parseProgressMode("sometimes") == null);

    try std.testing.expect(progressPolicyForTerminal(.auto, true).show);
    try std.testing.expect(progressPolicyForTerminal(.auto, false).log);
    try std.testing.expect(progressPolicyForTerminal(.log, true).log);
    try std.testing.expect(!progressPolicyForTerminal(.disabled, true).enabled());
}
