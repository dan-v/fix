//! Generic timestamped observation records for the CLI.

const std = @import("std");
const observ = @import("base").observ;
const terminal_text = @import("base").terminal_text;
const presentation = @import("presentation.zig");

pub const EvalProgress = struct {
    io: std.Io,
    started_at: std.Io.Timestamp,
    cwd: []const u8,
    color_depth: presentation.ColorDepth,
    log_progress: bool,
    verbosity: u8,

    pub fn init(io: std.Io, cwd: []const u8, log_progress: bool, color_depth: presentation.ColorDepth, verbosity: u8) EvalProgress {
        return .{
            .io = io,
            .started_at = std.Io.Clock.awake.now(io),
            .cwd = cwd,
            .color_depth = color_depth,
            .log_progress = log_progress,
            .verbosity = verbosity,
        };
    }

    pub fn deinit(_: *EvalProgress, _: bool) void {}

    pub fn observer(self: *EvalProgress) observ.Observer {
        return .{
            .sink = .{
                .context = self,
                .begin_fn = beginSpan,
                .finish_fn = finishSpan,
                .update_fn = updateSpan,
                .event_fn = writeEvent,
            },
            .verbosity = self.verbosity,
            .log_enabled = self.log_progress,
        };
    }

    pub fn writeLogPrefix(self: *EvalProgress, writer: *std.Io.Writer, tag: []const u8) !void {
        return presentation.writeLogPrefix(writer, self.io, self.color_depth, self.started_at, tag);
    }

    pub fn logNoun(self: *const EvalProgress, subject: []const u8) []const u8 {
        return presentation.logNoun(self.cwd, subject);
    }

    fn beginSpan(
        raw: *anyopaque,
        spec: *const observ.SpanSpec,
        details: observ.Details,
        _: observ.Track,
        interest: observ.Interest,
    ) usize {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        if (interest.log_begin) self.writeRecord(spec.category, spec.name, spec.begin_verb, details, &.{});
        return 0;
    }

    fn finishSpan(
        raw: *anyopaque,
        _: usize,
        spec: *const observ.SpanSpec,
        started: observ.Details,
        _: observ.Track,
        interest: observ.Interest,
        completion: observ.Finish,
        success: bool,
    ) void {
        if (!success or !interest.log_finish) return;
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        self.writeRecord(
            spec.category,
            spec.name,
            spec.finish_verb,
            completion.details orelse started,
            completion.metrics,
        );
    }

    fn updateSpan(_: *anyopaque, _: usize, _: *const observ.SpanSpec, _: observ.Interest, _: []const observ.Metric) void {}

    fn writeEvent(
        raw: *anyopaque,
        spec: *const observ.EventSpec,
        details: observ.Details,
        _: observ.Track,
        interest: observ.Interest,
        metrics: []const observ.Metric,
    ) void {
        if (!interest.log_finish) return;
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        self.writeRecord(spec.category, spec.name, spec.verb, details, metrics);
    }

    fn writeRecord(
        self: *EvalProgress,
        category: []const u8,
        identity: []const u8,
        verb: []const u8,
        details: observ.Details,
        metrics: []const observ.Metric,
    ) void {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = presentation.lockStderr(self.io, &stderr_buffer) catch return;
        defer stderr.deinit();
        const writer = stderr.writer();

        const use_color = self.color_depth.enabled();
        presentation.reset(writer, use_color) catch return;
        defer {
            presentation.reset(writer, use_color) catch {};
            stderr.flush() catch {};
        }
        self.writeLogPrefix(writer, category) catch return;
        presentation.foreground(writer, self.color_depth, presentation.nounColor(identity), false) catch return;
        writer.writeAll(verb) catch return;
        presentation.reset(writer, use_color) catch return;
        self.writeSubject(writer, details.subject) catch return;
        switch (details.destination) {
            .none => {},
            else => {
                writer.writeAll(" ->") catch return;
                self.writeSubject(writer, details.destination) catch return;
            },
        }
        for (metrics) |metric| self.writeMetric(writer, metric) catch return;
        writer.writeByte('\n') catch return;
    }

    fn writeSubject(self: *EvalProgress, writer: *std.Io.Writer, subject: observ.Subject) !void {
        const raw = subject.bytes();
        if (raw.len == 0) return;
        const noun = switch (subject) {
            .path => self.logNoun(raw),
            else => raw,
        };
        var buffer: [1024]u8 = undefined;
        const copied_len = @min(noun.len, buffer.len);
        @memcpy(buffer[0..copied_len], noun[0..copied_len]);
        const clean = terminal_text.stripAnsiInPlace(buffer[0..copied_len]);
        try writer.writeByte(' ');
        try presentation.foreground(writer, self.color_depth, presentation.nounColor(clean), true);
        try writer.writeAll(clean);
        try presentation.reset(writer, self.color_depth.enabled());
    }

    fn writeMetric(_: *EvalProgress, writer: *std.Io.Writer, metric: observ.Metric) !void {
        try writer.print(" {s}=", .{metric.name});
        switch (metric.value) {
            .unsigned => |value| try writer.print("{d}", .{value}),
            .signed => |value| try writer.print("{d}", .{value}),
            .float => |value| try writer.print("{d:.2}", .{value}),
            .text => |value| try writer.writeAll(value),
        }
        switch (metric.unit) {
            .none => {},
            .items => try writer.writeAll(" items"),
            .bytes => try writer.writeAll(" B"),
            .nanoseconds => try writer.writeAll(" ns"),
        }
    }
};

test "observer verbosity separates span openings from completions" {
    const spec: observ.SpanSpec = .{
        .category = "eval",
        .name = "parse",
        .begin_verb = "parsing",
        .finish_verb = "parsed",
        .begin_level = 3,
        .finish_level = 2,
    };
    var progress = EvalProgress.init(std.testing.io, "", true, .none, 2);
    const observer = progress.observer();
    var span = observer.begin(&spec, .{});
    try std.testing.expect(span.active());
    try std.testing.expect(!span.interest.log_begin);
    try std.testing.expect(span.interest.log_finish);
    span.cancel();
}
