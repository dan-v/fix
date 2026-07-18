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

pub const Operation = struct {
    progress: *BuildProgress,
    completed: bool = false,

    pub fn sink(self: *Operation) daemon.BuildSink {
        return .{ .context = self, .emit_fn = emit };
    }

    pub fn finish(self: *Operation, success: bool) void {
        if (self.completed) return;
        self.completed = true;
        self.progress.finishOperation(self, success);
    }

    fn emit(raw: *anyopaque, event: daemon.BuildEvent) void {
        const self: *Operation = @ptrCast(@alignCast(raw));
        self.progress.emit(self, event);
    }
};

const ActivityKey = struct {
    operation: *Operation,
    daemon_id: u64,
};

const Active = struct {
    operation: *Operation,
    action: Action,
    subject: [max_subject_len]u8,
    subject_len: u16,
    span: observ.Span,
    done: u64 = 0,
    expected: u64 = 0,
    reported: bool = false,

    fn init(operation: *Operation, action: Action, subject: []const u8, span: observ.Span) Active {
        var active: Active = .{
            .operation = operation,
            .action = action,
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
    activities: std.AutoHashMapUnmanaged(ActivityKey, Active) = .empty,
    /// `STDERR_STOP_ACTIVITY` means only that an activity ended; it carries no
    /// success status. Build completions stay here until the enclosing
    /// buildPaths result supplies that status.
    stopped_builds: std.ArrayListUnmanaged(Active) = .empty,
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

        for (self.stopped_builds.items) |activity_value| {
            var activity = activity_value;
            activity.span.cancel();
        }
        self.stopped_builds.deinit(self.allocator);
        self.stopped_builds = .empty;

        var iterator = self.activities.valueIterator();
        while (iterator.next()) |activity| activity.span.cancel();
        self.activities.deinit(self.allocator);
        self.activities = .empty;
    }

    pub fn operation(self: *BuildProgress) Operation {
        return .{ .progress = self };
    }

    fn emit(self: *BuildProgress, operation_value: *Operation, event: daemon.BuildEvent) void {
        self.mu.lock();
        defer self.mu.unlock();
        switch (event) {
            .start => |activity| self.start(operation_value, activity),
            .stop => |id| self.stop(operation_value, id),
            .progress => |report| self.update(operation_value, report),
            .log => |log| self.writeLog(operation_value, log),
        }
    }

    fn start(self: *BuildProgress, operation_value: *Operation, activity: daemon.build_events.Activity) void {
        const key: ActivityKey = .{ .operation = operation_value, .daemon_id = activity.id };
        if (self.activities.fetchRemove(key)) |old| {
            var previous = old.value;
            previous.span.cancel();
        }
        const action = activityAction(activity);
        const spec = action.observation();
        const span = self.progress.observer().beginOn(spec, .{ .subject = .{ .path = activity.subject } }, .daemon);
        self.activities.put(self.allocator, key, Active.init(operation_value, action, activity.subject, span)) catch {
            var abandoned = span;
            abandoned.cancel();
        };
    }

    fn stop(self: *BuildProgress, operation_value: *Operation, id: u64) void {
        const removed = self.activities.fetchRemove(.{ .operation = operation_value, .daemon_id = id }) orelse return;
        var activity = removed.value;
        if (activity.action == .build) {
            self.stopped_builds.append(self.allocator, activity) catch activity.span.cancel();
            return;
        }
        finishActivity(&activity);
    }

    fn update(self: *BuildProgress, operation_value: *Operation, progress: daemon.build_events.Progress) void {
        const activity = self.activities.getPtr(.{ .operation = operation_value, .daemon_id = progress.id }) orelse return;
        activity.done = progress.done;
        activity.expected = progress.expected;
        activity.reported = true;
        activity.span.update(&.{
            .{ .name = "done", .value = .{ .unsigned = progress.done }, .unit = .items },
            .{ .name = "expected", .value = .{ .unsigned = progress.expected }, .unit = .items },
        });
    }

    fn writeLog(self: *BuildProgress, operation_value: *Operation, log: daemon.build_events.Log) void {
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

        const active = if (log.activity_id) |id| self.activities.get(.{ .operation = operation_value, .daemon_id = id }) else null;
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

    fn finishOperation(self: *BuildProgress, operation_value: *Operation, success: bool) void {
        self.mu.lock();
        defer self.mu.unlock();

        var i: usize = 0;
        while (i < self.stopped_builds.items.len) {
            if (self.stopped_builds.items[i].operation != operation_value) {
                i += 1;
                continue;
            }
            var activity = self.stopped_builds.swapRemove(i);
            if (success) finishActivity(&activity) else failActivity(&activity);
        }

        var iterator = self.activities.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.operation != operation_value) continue;
            if (entry.value_ptr.action == .build) {
                if (success) finishActivity(entry.value_ptr) else failActivity(entry.value_ptr);
            } else {
                entry.value_ptr.span.cancel();
            }
        }
    }
};

fn finishActivity(activity: *Active) void {
    completeActivity(activity, true);
}

fn failActivity(activity: *Active) void {
    completeActivity(activity, false);
}

fn completeActivity(activity: *Active, success: bool) void {
    const metrics = [_]observ.Metric{
        .{ .name = "done", .value = .{ .unsigned = activity.done }, .unit = .items },
        .{ .name = "expected", .value = .{ .unsigned = activity.expected }, .unit = .items },
    };
    const completion: observ.Finish = .{
        .verb = if (success) null else "failed",
        .details = .{ .subject = .{ .path = activity.path() } },
        .metrics = if (activity.reported) &metrics else &.{},
    };
    if (success) activity.span.finish(completion) else activity.span.fail(completion);
}

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

test "stopped builds close against their own operation result" {
    var progress = EvalProgress.init(std.testing.io, "", false, .none, 0);
    var build_progress = BuildProgress.init(std.testing.allocator, std.testing.io, .none, false, &progress);

    var failed_operation = build_progress.operation();
    var successful_operation = build_progress.operation();
    build_progress.start(&failed_operation, .{
        .id = 1,
        .kind = .build,
        .subject = "/nix/store/01234567890123456789012345678901-failing.drv",
        .detail = "",
    });
    build_progress.start(&successful_operation, .{
        .id = 1,
        .kind = .build,
        .subject = "/nix/store/01234567890123456789012345678901-successful.drv",
        .detail = "",
    });
    build_progress.stop(&failed_operation, 1);
    build_progress.stop(&successful_operation, 1);

    try std.testing.expectEqual(@as(usize, 0), build_progress.activities.count());
    try std.testing.expectEqual(@as(usize, 2), build_progress.stopped_builds.items.len);
    failed_operation.finish(false);
    try std.testing.expectEqual(@as(usize, 1), build_progress.stopped_builds.items.len);
    successful_operation.finish(true);
    try std.testing.expectEqual(@as(usize, 0), build_progress.stopped_builds.items.len);
    build_progress.deinit();
}
