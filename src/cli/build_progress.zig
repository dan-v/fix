//! Adapter from the daemon's typed activity/log stream to observations.

const std = @import("std");
const daemon = @import("store").daemon;
const sync = @import("base").sync;
const observ = @import("base").observ;
const EvalProgress = @import("progress.zig").EvalProgress;
const presentation = @import("presentation.zig");

const build_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "build",
    .begin_verb = "building",
    .finish_verb = "built",
    .begin_level = 0,
};
const copy_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "copy",
    .begin_verb = "copying",
    .finish_verb = "copied",
    .begin_level = 0,
};
const substitute_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "substitute",
    .begin_verb = "fetching",
    .finish_verb = "fetched",
    .begin_level = 0,
};
const post_build_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "post-build",
    .begin_verb = "running post-build for",
    .finish_verb = "ran post-build for",
    .begin_level = 0,
};

const Action = enum {
    build,
    copy,
    substitute,
    post_build,

    fn observation(self: Action) *const observ.SpanSpec {
        return switch (self) {
            .build => &build_observation,
            .copy => &copy_observation,
            .substitute => &substitute_observation,
            .post_build => &post_build_observation,
        };
    }
};

const max_subject_len = 512;

const Active = struct {
    subject: [max_subject_len]u8,
    subject_len: u16,
    span: observ.Span,
    done: u64 = 0,
    expected: u64 = 0,
    reported: bool = false,

    fn init(subject: []const u8, span: observ.Span) Active {
        var active: Active = .{
            .subject = undefined,
            .subject_len = @intCast(@min(subject.len, max_subject_len)),
            .span = span,
        };
        @memcpy(active.subject[0..active.subject_len], subject[0..active.subject_len]);
        return active;
    }

    fn path(self: *const Active) []const u8 {
        return self.subject[0..self.subject_len];
    }
};

pub const BuildProgress = struct {
    progress: *EvalProgress,
    allocator: std.mem.Allocator,
    io: std.Io,
    color_depth: presentation.ColorDepth,
    log_progress: bool,
    activities: std.AutoHashMapUnmanaged(u64, Active) = .empty,
    mu: sync.BlockingMutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, color_depth: presentation.ColorDepth, log_progress: bool, progress: *EvalProgress) BuildProgress {
        return .{
            .progress = progress,
            .allocator = allocator,
            .io = io,
            .color_depth = color_depth,
            .log_progress = log_progress,
        };
    }

    pub fn deinit(self: *BuildProgress) void {
        self.mu.lock();
        defer self.mu.unlock();
        var iterator = self.activities.valueIterator();
        while (iterator.next()) |activity| activity.span.cancel();
        self.activities.deinit(self.allocator);
        self.activities = .empty;
    }

    pub fn sink(self: *BuildProgress) daemon.BuildSink {
        return .{ .context = self, .emit_fn = emit };
    }

    fn emit(raw: *anyopaque, event: daemon.BuildEvent) void {
        const self: *BuildProgress = @ptrCast(@alignCast(raw));
        self.mu.lock();
        defer self.mu.unlock();
        switch (event) {
            .start => |activity| self.start(activity),
            .stop => |id| self.stop(id),
            .progress => |report| self.update(report),
            .log => |log| self.writeLog(log),
        }
    }

    fn start(self: *BuildProgress, activity: daemon.build_events.Activity) void {
        if (self.activities.fetchRemove(activity.id)) |old| {
            var previous = old.value;
            previous.span.cancel();
        }
        const spec = activityAction(activity).observation();
        const span = self.progress.observer().begin(spec, .{ .subject = .{ .path = activity.subject } });
        self.activities.put(self.allocator, activity.id, Active.init(activity.subject, span)) catch {
            var abandoned = span;
            abandoned.cancel();
        };
    }

    fn stop(self: *BuildProgress, id: u64) void {
        const removed = self.activities.fetchRemove(id) orelse return;
        var activity = removed.value;
        const metrics = [_]observ.Metric{
            .{ .name = "done", .value = .{ .unsigned = activity.done }, .unit = .items },
            .{ .name = "expected", .value = .{ .unsigned = activity.expected }, .unit = .items },
        };
        activity.span.finish(.{
            .details = .{ .subject = .{ .path = activity.path() } },
            .metrics = if (activity.reported) &metrics else &.{},
        });
    }

    fn update(self: *BuildProgress, progress: daemon.build_events.Progress) void {
        const activity = self.activities.getPtr(progress.id) orelse return;
        activity.done = progress.done;
        activity.expected = progress.expected;
        activity.reported = true;
        activity.span.update(&.{
            .{ .name = "done", .value = .{ .unsigned = progress.done }, .unit = .items },
            .{ .name = "expected", .value = .{ .unsigned = progress.expected }, .unit = .items },
        });
    }

    fn writeLog(self: *BuildProgress, log: daemon.build_events.Log) void {
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

        const active = if (log.activity_id) |id| self.activities.get(id) else null;
        const is_build_log = log.kind != .daemon;
        if (self.log_progress) self.progress.writeLogPrefix(writer, if (is_build_log) "build" else "daemon") catch return;
        if (is_build_log) {
            if (active) |activity| {
                const noun = self.progress.logNoun(activity.path());
                self.writeNoun(writer, noun) catch return;
            }
            writer.writeAll(if (active == null) "| " else " | ") catch return;
        }
        writer.writeAll(log.text) catch return;
        if (!std.mem.endsWith(u8, log.text, "\n")) writer.writeByte('\n') catch return;
    }

    fn writeNoun(self: *BuildProgress, writer: *std.Io.Writer, noun: []const u8) !void {
        try presentation.foreground(writer, self.color_depth, presentation.nounColor(noun), true);
        try writer.writeAll(noun);
        try presentation.reset(writer, self.color_depth.enabled());
    }
};

fn activityAction(activity: daemon.build_events.Activity) Action {
    return switch (activity.kind) {
        .build => .build,
        .substitute => if (std.mem.startsWith(u8, activity.detail, "local")) .copy else .substitute,
        .post_build_hook => .post_build,
    };
}

test "daemon activities select local observation specs" {
    const build: daemon.build_events.Activity = .{
        .id = 1,
        .kind = .build,
        .subject = "/nix/store/01234567890123456789012345678901-hello-1.0.drv",
        .detail = "",
    };
    try std.testing.expectEqualStrings("built", activityAction(build).observation().finish_verb);
    const copy = daemon.build_events.Activity{ .id = 2, .kind = .substitute, .subject = build.subject, .detail = "local" };
    try std.testing.expectEqualStrings("copied", activityAction(copy).observation().finish_verb);
    const fetch = daemon.build_events.Activity{ .id = 3, .kind = .substitute, .subject = build.subject, .detail = "https://cache.example" };
    try std.testing.expectEqualStrings("fetched", activityAction(fetch).observation().finish_verb);
}
