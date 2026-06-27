//! Small shared CLI presentation layer.
//!
//! Output policy lives here: terminal detection, color styles, and small
//! formatting primitives. Evaluation progress itself is backed by `std.Progress`.

const std = @import("std");
const eval_progress = @import("eval/progress.zig");

pub const When = enum {
    auto,
    always,
    never,
};

pub fn parseWhen(text: []const u8) ?When {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

pub fn stderrInteractive(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return std.Io.File.stderr().isTty(io) catch false;
}

pub fn shouldColor(mode: When, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => autoColor(stderrInteractive(io, env), env),
    };
}

pub fn autoColor(interactive: bool, env: *const std.process.Environ.Map) bool {
    if (!interactive) return false;
    if (env.get("NO_COLOR")) |_| return false;
    return true;
}

pub fn shouldProgress(mode: When, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => stderrInteractive(io, env),
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
    return .{
        .io = io,
        .locked = try io.lockStderr(buffer, null),
    };
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

pub const EvalProgress = struct {
    const max_active = 128;

    root: std.Progress.Node,
    active: [max_active]Active = undefined,
    active_len: usize = 0,

    const Active = struct {
        stage: eval_progress.Stage,
        node: std.Progress.Node,
    };

    pub fn init(io: std.Io, enabled: bool) EvalProgress {
        return .{
            .root = std.Progress.start(io, .{
                .root_name = "",
                .disable_printing = !enabled,
                .initial_delay_ns = .fromMilliseconds(180),
                .refresh_rate_ns = .fromMilliseconds(100),
            }),
        };
    }

    pub fn deinit(self: *EvalProgress, success: bool) void {
        while (self.active_len != 0) {
            self.active_len -= 1;
            self.active[self.active_len].node.end();
        }
        std.Progress.setStatus(if (success) .success else .failure);
        self.root.end();
    }

    pub fn sink(self: *EvalProgress) eval_progress.Sink {
        return .{
            .context = self,
            .emit_fn = emit,
        };
    }

    fn emit(context: *anyopaque, event: eval_progress.Event) void {
        const self: *EvalProgress = @ptrCast(@alignCast(context));
        switch (event) {
            .begin => |step| self.beginStep(step),
            .end => |step| self.endStep(step.stage),
            .instant => |step| self.instantStep(step),
        }
    }

    fn beginStep(self: *EvalProgress, step: eval_progress.Step) void {
        const parent = if (self.active_len == 0) self.root else self.active[self.active_len - 1].node;
        const node = startStepNode(parent, step);
        if (self.active_len >= self.active.len) {
            node.end();
            return;
        }
        self.active[self.active_len] = .{ .stage = step.stage, .node = node };
        self.active_len += 1;
    }

    fn endStep(self: *EvalProgress, stage: eval_progress.Stage) void {
        if (self.active_len == 0) return;

        var i = self.active_len;
        while (i > 0) {
            i -= 1;
            if (self.active[i].stage == stage) {
                while (self.active_len > i) {
                    self.active_len -= 1;
                    self.active[self.active_len].node.end();
                }
                return;
            }
        }
    }

    fn instantStep(self: *EvalProgress, step: eval_progress.Step) void {
        const parent = if (self.active_len == 0) self.root else self.active[self.active_len - 1].node;
        const node = startStepNode(parent, step);
        node.end();
    }
};

fn startStepNode(parent: std.Progress.Node, step: eval_progress.Step) std.Progress.Node {
    if (step.subject.len == 0) return parent.start(eval_progress.stageName(step.stage), 0);
    var buffer: [std.Progress.Node.max_name_len]u8 = undefined;
    const name = std.fmt.bufPrint(&buffer, "{s} {s}", .{
        eval_progress.stageName(step.stage),
        std.fs.path.basename(step.subject),
    }) catch eval_progress.stageName(step.stage);
    return parent.start(name, 0);
}

test "parse terminal policy" {
    try std.testing.expectEqual(When.auto, parseWhen("auto").?);
    try std.testing.expect(parseWhen("sometimes") == null);
}
