//! Timestamped evaluation progress records for the CLI.

const std = @import("std");
const eval_progress = @import("expr").EvalProgress;
const sync = @import("base").sync;
const terminal_text = @import("base").terminal_text;
const presentation = @import("presentation.zig");

pub const EvalProgress = struct {
    const max_log_spans = 128;
    const max_subject_len = 512;

    const LogSubject = struct {
        bytes: [max_subject_len]u8 = undefined,
        len: u16 = 0,

        fn set(self: *LogSubject, subject: []const u8) void {
            self.len = @intCast(@min(subject.len, self.bytes.len));
            @memcpy(self.bytes[0..self.len], subject[0..self.len]);
        }

        fn get(self: *const LogSubject) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    const LogSpan = struct {
        token: usize = 0,
        kind: eval_progress.SpanKind = .fetch,
        subject: LogSubject = .{},
        destination: LogSubject = .{},
        active: bool = false,
    };

    io: std.Io,
    started_at: std.Io.Timestamp,
    cwd: []const u8,
    color_depth: presentation.ColorDepth,
    log_progress: bool,
    verbosity: u8,
    log_span_mu: sync.BlockingMutex = .{},
    log_spans: [max_log_spans]LogSpan = [_]LogSpan{.{}} ** max_log_spans,
    next_log_span_token: usize = 1,
    log_waiting: LogSubject = .{},

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

    pub fn deinit(self: *EvalProgress, success: bool) void {
        _ = success;
        self.log_waiting.len = 0;
    }

    pub fn sink(self: *EvalProgress) eval_progress.Sink {
        return .{
            .stage = .{ .context = self, .emit_fn = emit },
            .spans = .{
                .context = self,
                .begin_span_fn = beginSpan,
                .end_span_fn = endSpan,
                .update_span_fn = updateSpan,
            },
        };
    }

    pub fn writeLogPrefix(self: *EvalProgress, writer: *std.Io.Writer, tag: []const u8) !void {
        return presentation.writeLogPrefix(writer, self.io, self.color_depth, self.started_at, tag);
    }

    pub fn logNoun(self: *const EvalProgress, subject: []const u8) []const u8 {
        return presentation.logNoun(self.cwd, subject);
    }

    fn beginSpan(context: *anyopaque, kind: eval_progress.SpanKind, subject: []const u8, destination: ?[]const u8) usize {
        const self: *EvalProgress = @ptrCast(@alignCast(context));
        if (!self.log_progress or !spanVisible(self.verbosity, kind)) return 0;
        return self.beginLogSpan(kind, subject, destination);
    }

    fn endSpan(context: *anyopaque, token: usize) void {
        const self: *EvalProgress = @ptrCast(@alignCast(context));
        if (self.log_progress) self.endLogSpan(token);
    }

    fn beginLogSpan(self: *EvalProgress, kind: eval_progress.SpanKind, subject: []const u8, destination: ?[]const u8) usize {
        self.log_span_mu.lock();
        var started: ?LogSpan = null;
        for (&self.log_spans) |*span| {
            if (span.active) continue;
            const token = self.next_log_span_token;
            self.next_log_span_token +%= 1;
            if (self.next_log_span_token == 0) self.next_log_span_token = 1;
            span.* = .{ .token = token, .kind = kind, .active = true };
            span.subject.set(subject);
            if (destination) |path| span.destination.set(path);
            started = span.*;
            break;
        }
        self.log_span_mu.unlock();

        if (started) |span| {
            if (spanLogsStart(self.verbosity, span.kind)) self.writeProgressLog(
                spanTag(span.kind),
                spanVerb(span.kind),
                spanVerbRole(span.kind),
                span.subject.get(),
                if (span.destination.len == 0) null else span.destination.get(),
            );
            return span.token;
        }
        return 0;
    }

    fn endLogSpan(self: *EvalProgress, token: usize) void {
        if (token == 0) return;
        var completed: ?LogSpan = null;
        self.log_span_mu.lock();
        for (&self.log_spans) |*span| {
            if (!span.active or span.token != token) continue;
            completed = span.*;
            span.active = false;
            break;
        }
        self.log_span_mu.unlock();

        if (completed) |span| self.writeProgressLog(
            spanTag(span.kind),
            completedSpanVerb(span.kind),
            spanVerbRole(span.kind),
            span.subject.get(),
            if (span.destination.len == 0) null else span.destination.get(),
        );
    }

    /// Byte counters existed only to update the live tree. Durable records keep
    /// the fetch lifecycle but intentionally do not emit per-chunk updates.
    fn updateSpan(context: *anyopaque, token: usize, downloaded: u64, total: u64) void {
        _ = context;
        _ = token;
        _ = downloaded;
        _ = total;
    }

    fn emit(context: *anyopaque, event: eval_progress.Event) void {
        const self: *EvalProgress = @ptrCast(@alignCast(context));
        if (self.log_progress) self.logEvent(event);
    }

    fn logEvent(self: *EvalProgress, event: eval_progress.Event) void {
        switch (event) {
            .session_begin, .count => {},
            .session_end => self.log_waiting.len = 0,
            .begin => |step| if (stageVisible(self.verbosity, step.stage) and stageLogsStart(self.verbosity, step.stage)) self.writeProgressLog(
                "eval",
                stageVerb(step.stage),
                stageVerbRole(step.stage),
                step.subject,
                null,
            ),
            .end, .instant => |step| if (stageVisible(self.verbosity, step.stage)) self.writeProgressLog(
                "eval",
                completedStageVerb(step.stage),
                stageVerbRole(step.stage),
                step.subject,
                null,
            ),
            .wait_begin => |subject| {
                self.log_waiting.set(subject);
                self.writeProgressLog("eval", "waiting for", .query, subject, null);
            },
            .wait_end => self.logWaitEnd(),
        }
    }

    fn logWaitEnd(self: *EvalProgress) void {
        if (self.log_waiting.len == 0) return;
        const subject = self.log_waiting;
        self.log_waiting.len = 0;
        self.writeProgressLog("eval", "waited for", .query, subject.get(), null);
    }

    fn writeProgressLog(
        self: *EvalProgress,
        tag: []const u8,
        verb: []const u8,
        verb_role: presentation.Verb,
        subject: []const u8,
        destination: ?[]const u8,
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
        const verb_color = presentation.verbColor(verb_role);
        self.writeLogPrefix(writer, tag) catch return;
        presentation.foreground(writer, self.color_depth, verb_color, false) catch return;
        writer.writeAll(verb) catch return;
        presentation.reset(writer, use_color) catch return;
        if (subject.len != 0) {
            writer.writeByte(' ') catch return;
            self.writeNoun(writer, subject) catch return;
        }
        if (destination) |path| {
            writer.writeAll(" -> ") catch return;
            self.writeNoun(writer, path) catch return;
        }
        writer.writeByte('\n') catch return;
    }

    fn writeNoun(self: *EvalProgress, writer: *std.Io.Writer, subject: []const u8) !void {
        const noun = self.logNoun(subject);
        var buffer: [1024]u8 = undefined;
        const copied_len = @min(noun.len, buffer.len);
        @memcpy(buffer[0..copied_len], noun[0..copied_len]);
        const clean = terminal_text.stripAnsiInPlace(buffer[0..copied_len]);
        try presentation.foreground(writer, self.color_depth, presentation.nounColor(clean), true);
        try writer.writeAll(clean);
        try presentation.reset(writer, self.color_depth.enabled());
    }
};

fn stageVerb(stage: eval_progress.Stage) []const u8 {
    return switch (stage) {
        .parse => "parsing",
        .compile => "compiling",
        .evaluate => "evaluating",
        .import => "importing",
        .derivation => "instantiating",
        .store => "storing",
        .build => "building",
        .render => "rendering",
    };
}

fn completedStageVerb(stage: eval_progress.Stage) []const u8 {
    return switch (stage) {
        .parse => "parsed",
        .compile => "compiled",
        .evaluate => "evaluated",
        .import => "imported",
        .derivation => "instantiated",
        .store => "stored",
        .build => "built",
        .render => "rendered",
    };
}

fn stageLogsStart(verbosity: u8, stage: eval_progress.Stage) bool {
    return switch (stage) {
        .parse, .compile, .render => false,
        .store => verbosity >= 1,
        .evaluate, .import, .derivation, .build => true,
    };
}

fn stageVisible(verbosity: u8, stage: eval_progress.Stage) bool {
    return switch (stage) {
        .parse, .compile => verbosity >= 2,
        .evaluate, .import, .derivation, .store, .build, .render => true,
    };
}

fn spanVisible(verbosity: u8, kind: eval_progress.SpanKind) bool {
    return switch (kind) {
        .check => verbosity >= 1,
        .store, .fetch, .query, .build, .register => true,
    };
}

fn spanLogsStart(verbosity: u8, kind: eval_progress.SpanKind) bool {
    return switch (kind) {
        .check, .register => false,
        .store => verbosity >= 1,
        .fetch, .query, .build => true,
    };
}

fn spanVerb(kind: eval_progress.SpanKind) []const u8 {
    return switch (kind) {
        .check => "checking",
        .store => "storing",
        .fetch => "fetching",
        .query => "querying",
        .build => "building",
        .register => "registering",
    };
}

fn completedSpanVerb(kind: eval_progress.SpanKind) []const u8 {
    return switch (kind) {
        .check => "checked",
        .store => "stored",
        .fetch => "fetched",
        .query => "queried",
        .build => "built",
        .register => "registered",
    };
}

fn spanTag(kind: eval_progress.SpanKind) []const u8 {
    return if (kind == .fetch) "fetch" else "daemon";
}

fn spanVerbRole(kind: eval_progress.SpanKind) presentation.Verb {
    return switch (kind) {
        .check, .query => .query,
        .store, .register => .store,
        .fetch => .fetch,
        .build => .build,
    };
}

fn stageVerbRole(stage: eval_progress.Stage) presentation.Verb {
    return switch (stage) {
        .parse, .compile, .render => .transform,
        .evaluate, .import => .evaluate,
        .derivation, .store => .store,
        .build => .build,
    };
}

test "progress verbosity filters starts and detail" {
    try std.testing.expectEqualStrings("parsed", completedStageVerb(.parse));
    try std.testing.expectEqualStrings("instantiated", completedStageVerb(.derivation));
    try std.testing.expect(!stageLogsStart(0, .store));
    try std.testing.expect(stageLogsStart(1, .store));
    try std.testing.expect(!stageVisible(1, .parse));
    try std.testing.expect(stageVisible(2, .parse));
    try std.testing.expect(!spanVisible(0, .check));
    try std.testing.expect(spanVisible(1, .check));
    try std.testing.expect(!spanLogsStart(0, .store));
    try std.testing.expect(spanLogsStart(1, .store));
    try std.testing.expectEqualStrings("stored", completedSpanVerb(.store));
    try std.testing.expectEqualStrings("fetch", spanTag(.fetch));
}
