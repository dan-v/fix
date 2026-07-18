//! Build progress adapter: turns the daemon's typed activity/log stream into
//! timestamped records. Daemon-provided prose and styling never control the
//! record presentation; this layer owns both.

const std = @import("std");
const daemon = @import("store").daemon;
const sync = @import("base").sync;
const EvalProgress = @import("progress.zig").EvalProgress;
const presentation = @import("presentation.zig");

const Action = enum {
    building,
    copying,
    fetching,
    post_build,

    fn verb(self: Action) []const u8 {
        return switch (self) {
            .building => "building",
            .copying => "copying",
            .fetching => "fetching",
            .post_build => "post-build",
        };
    }

    fn completedVerb(self: Action) []const u8 {
        return switch (self) {
            .building => "built",
            .copying => "copied",
            .fetching => "fetched",
            .post_build => "ran post-build for",
        };
    }

    fn verbRole(self: Action) presentation.Verb {
        return switch (self) {
            .building => .build,
            .copying => .store,
            .fetching => .fetch,
            .post_build => .store,
        };
    }
};

const Phase = enum { ongoing, completed };
const max_name_len = 512;

const Active = struct {
    action: Action,
    noun: [max_name_len]u8,
    noun_len: u16,

    fn init(action: Action, noun: []const u8) Active {
        var active: Active = .{
            .action = action,
            .noun = undefined,
            .noun_len = @intCast(@min(noun.len, max_name_len)),
        };
        @memcpy(active.noun[0..active.noun_len], noun[0..active.noun_len]);
        return active;
    }

    fn name(self: *const Active) []const u8 {
        return self.noun[0..self.noun_len];
    }
};

pub const BuildProgress = struct {
    progress: *EvalProgress,
    allocator: std.mem.Allocator,
    io: std.Io,
    color_depth: presentation.ColorDepth,
    log_progress: bool,
    /// Active activity id -> its presentation identity.
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

    /// Free tracked activity identities. Idempotent.
    pub fn deinit(self: *BuildProgress) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.activities.deinit(self.allocator);
        self.activities = .empty;
    }

    pub fn sink(self: *BuildProgress) daemon.BuildSink {
        return .{
            .context = self,
            .emit_fn = emit,
        };
    }

    fn emit(context: *anyopaque, event: daemon.BuildEvent) void {
        const self: *BuildProgress = @ptrCast(@alignCast(context));
        self.mu.lock();
        defer self.mu.unlock();
        switch (event) {
            .start => |activity| {
                const action = activityAction(activity);
                const noun = self.progress.logNoun(activity.subject);
                _ = self.activities.remove(activity.id);
                self.activities.put(self.allocator, activity.id, Active.init(action, noun)) catch return;
                if (self.log_progress) self.writeActivity(action, noun, .ongoing);
            },
            .stop => |id| if (self.activities.fetchRemove(id)) |kv| {
                if (self.log_progress) self.writeActivity(kv.value.action, kv.value.name(), .completed);
            },
            .progress => {},
            .log => |log| self.writeLog(log),
        }
    }

    fn writeLog(self: *BuildProgress, log: daemon.build_events.Log) void {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = presentation.lockStderr(self.io, &stderr_buffer) catch return;
        defer stderr.deinit();
        const writer = stderr.writer();

        // Reset before and after every external record. Even an interrupted
        // write cannot leave our selected style active for subsequent output.
        const use_color = self.color_depth.enabled();
        presentation.reset(writer, use_color) catch return;
        defer {
            presentation.reset(writer, use_color) catch {};
            stderr.flush() catch {};
        }

        const active = if (log.activity_id) |id| self.activities.get(id) else null;
        const is_build_log = log.kind != .daemon;
        const system = if (is_build_log) "build" else "daemon";
        if (self.log_progress) {
            self.progress.writeLogPrefix(writer, system) catch return;
        }

        if (is_build_log) {
            if (active) |value| self.writeNoun(writer, value.name(), value.name()) catch return;
            writer.writeAll(if (active == null) "| " else " | ") catch return;
        }
        writer.writeAll(log.text) catch return;
        if (!std.mem.endsWith(u8, log.text, "\n")) writer.writeByte('\n') catch return;
    }

    fn writeActivity(self: *BuildProgress, action: Action, noun: []const u8, phase: Phase) void {
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
        self.progress.writeLogPrefix(writer, "daemon") catch return;
        self.writeActivityText(writer, action, noun, phase) catch return;
        writer.writeByte('\n') catch return;
    }

    fn writeActivityText(self: *BuildProgress, writer: *std.Io.Writer, action: Action, noun: []const u8, phase: Phase) !void {
        try presentation.foreground(writer, self.color_depth, presentation.verbColor(action.verbRole()), false);
        try writer.writeAll(switch (phase) {
            .ongoing => action.verb(),
            .completed => action.completedVerb(),
        });
        try presentation.reset(writer, self.color_depth.enabled());
        if (noun.len == 0) return;
        try writer.writeByte(' ');
        try self.writeNoun(writer, noun, noun);
    }

    fn writeNoun(self: *BuildProgress, writer: *std.Io.Writer, noun: []const u8, identity: []const u8) !void {
        try presentation.foreground(writer, self.color_depth, presentation.nounColor(identity), true);
        try writer.writeAll(noun);
        try presentation.reset(writer, self.color_depth.enabled());
    }
};

fn activityAction(activity: daemon.build_events.Activity) Action {
    return switch (activity.kind) {
        .build => .building,
        .substitute => if (std.mem.startsWith(u8, activity.detail, "local")) .copying else .fetching,
        .post_build_hook => .post_build,
    };
}

test "build activities retain daemon subjects as presentation identities" {
    const build: daemon.build_events.Activity = .{
        .id = 1,
        .kind = .build,
        .subject = "/nix/store/01234567890123456789012345678901-hello-1.0.drv",
        .detail = "",
    };
    try std.testing.expectEqual(Action.building, activityAction(build));
    const active = Active.init(activityAction(build), presentation.logNoun("/work", build.subject));
    try std.testing.expectEqualStrings("hello-1.0.drv", active.name());
    const copy: daemon.build_events.Activity = .{
        .id = 2,
        .kind = .substitute,
        .subject = "/nix/store/01234567890123456789012345678901-source",
        .detail = "local",
    };
    try std.testing.expectEqual(Action.copying, activityAction(copy));
    const fetch: daemon.build_events.Activity = .{
        .id = 3,
        .kind = .substitute,
        .subject = "/nix/store/01234567890123456789012345678901-source",
        .detail = "https://cache.example",
    };
    try std.testing.expectEqual(Action.fetching, activityAction(fetch));
    try std.testing.expectEqual(presentation.nounColor(fetch.subject), presentation.nounColor(fetch.subject));
    try std.testing.expectEqualStrings("built", Action.building.completedVerb());
    try std.testing.expectEqualStrings("copied", Action.copying.completedVerb());
}
