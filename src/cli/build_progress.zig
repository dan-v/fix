//! Build progress adapter: drives a set of `std.Progress` nodes off the daemon's
//! typed activity/log stream (a node per build/substitution, updated
//! with `done/expected` progress). Nodes hang under the run node of the shared
//! `EvalProgress`, so eval and build render as one tree. Daemon-provided prose
//! and styling never enter progress node names; this layer owns both.

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

    fn accent(self: Action) presentation.Accent {
        return switch (self) {
            .building => .magenta,
            .copying => .green,
            .fetching => .cyan,
            .post_build => .green,
        };
    }
};

const Active = struct {
    node: std.Progress.Node,
    action: Action,
    noun: [std.Progress.Node.max_name_len]u8,
    noun_len: u8,

    fn init(node: std.Progress.Node, action: Action, noun: []const u8) Active {
        var active: Active = .{
            .node = node,
            .action = action,
            .noun = undefined,
            .noun_len = @intCast(@min(noun.len, std.Progress.Node.max_name_len)),
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
    use_color: bool,
    show_progress: bool,
    /// Active activity id -> its node.
    nodes: std.AutoHashMapUnmanaged(u64, Active) = .empty,
    mu: sync.BlockingMutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, use_color: bool, show_progress: bool, progress: *EvalProgress) BuildProgress {
        return .{
            .progress = progress,
            .allocator = allocator,
            .io = io,
            .use_color = use_color,
            .show_progress = show_progress,
        };
    }

    /// End all active nodes and free. Idempotent (safe to call before session
    /// teardown and again via defer).
    pub fn deinit(self: *BuildProgress) void {
        self.mu.lock();
        defer self.mu.unlock();
        var it = self.nodes.valueIterator();
        while (it.next()) |active| active.node.end();
        self.nodes.deinit(self.allocator);
        self.nodes = .empty;
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
                var label_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
                const action = activityAction(activity);
                const noun = activityNoun(activity);
                // std.Progress clips names to the terminal width by raw byte
                // count. ANSI here could therefore lose its trailing reset;
                // keep the tree label plain and color only writes we own.
                const label = activityLabel(&label_buffer, action, noun);
                const node = self.progress.childNode(label);
                if (self.nodes.fetchRemove(activity.id)) |old| old.value.node.end();
                self.nodes.put(self.allocator, activity.id, Active.init(node, action, noun)) catch node.end();
                if (!self.show_progress) self.writeActivity(action, noun);
            },
            .stop => |id| if (self.nodes.fetchRemove(id)) |kv| kv.value.node.end(),
            .progress => |update| if (self.nodes.get(update.id)) |active| {
                if (update.expected != 0) active.node.setEstimatedTotalItems(update.expected);
                active.node.setCompletedItems(update.done);
            },
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
        presentation.reset(writer, self.use_color) catch return;
        defer {
            presentation.reset(writer, self.use_color) catch {};
            stderr.flush() catch {};
        }

        if (log.kind != .daemon) {
            const active = if (log.activity_id) |id| self.nodes.get(id) else null;
            if (active) |value| {
                self.writeActivityText(writer, value.action, value.name()) catch return;
            } else {
                const action: Action = if (log.kind == .post_build) .post_build else .building;
                self.writeActivityText(writer, action, "") catch return;
            }
            writer.writeAll(if (log.kind == .post_build) " (post) | " else " | ") catch return;
        }
        writer.writeAll(log.text) catch return;
        if (!std.mem.endsWith(u8, log.text, "\n")) writer.writeByte('\n') catch return;
    }

    fn writeActivity(self: *BuildProgress, action: Action, noun: []const u8) void {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = presentation.lockStderr(self.io, &stderr_buffer) catch return;
        defer stderr.deinit();
        const writer = stderr.writer();

        presentation.reset(writer, self.use_color) catch return;
        defer {
            presentation.reset(writer, self.use_color) catch {};
            stderr.flush() catch {};
        }
        self.writeActivityText(writer, action, noun) catch return;
        writer.writeByte('\n') catch return;
    }

    fn writeActivityText(self: *BuildProgress, writer: *std.Io.Writer, action: Action, noun: []const u8) !void {
        try presentation.accent(writer, self.use_color, action.accent(), false);
        try writer.writeAll(action.verb());
        try presentation.reset(writer, self.use_color);
        if (noun.len == 0) return;
        try writer.writeByte(' ');
        try presentation.accent(writer, self.use_color, nounAccent(noun), true);
        try writer.writeAll(noun);
        try presentation.reset(writer, self.use_color);
    }
};

fn activityAction(activity: daemon.build_events.Activity) Action {
    return switch (activity.kind) {
        .build => .building,
        .substitute => if (std.mem.startsWith(u8, activity.detail, "local")) .copying else .fetching,
        .post_build_hook => .post_build,
    };
}

fn activityNoun(activity: daemon.build_events.Activity) []const u8 {
    const name = storePathName(activity.subject);
    return switch (activity.kind) {
        .build, .post_build_hook => stripDrv(name),
        .substitute => name,
    };
}

fn activityLabel(buffer: []u8, action: Action, noun: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ action.verb(), noun }) catch noun[0..@min(noun.len, buffer.len)];
}

fn nounAccent(noun: []const u8) presentation.Accent {
    // Keep noun colors disjoint from the verb palette so grammar stays clear.
    const palette = [_]presentation.Accent{ .red, .yellow, .blue };
    return palette[std.hash.Wyhash.hash(0, noun) % palette.len];
}

fn storePathName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 33 and base[32] == '-') return base[33..];
    return base;
}

fn stripDrv(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".drv")) name[0 .. name.len - 4] else name;
}

test "build activity labels are owned presentation" {
    var buffer: [std.Progress.Node.max_name_len]u8 = undefined;
    const build: daemon.build_events.Activity = .{
        .id = 1,
        .kind = .build,
        .subject = "/nix/store/01234567890123456789012345678901-hello-1.0.drv",
        .detail = "",
    };
    try std.testing.expectEqualStrings("building hello-1.0", activityLabel(&buffer, activityAction(build), activityNoun(build)));
    const copy: daemon.build_events.Activity = .{
        .id = 2,
        .kind = .substitute,
        .subject = "/nix/store/01234567890123456789012345678901-source",
        .detail = "local",
    };
    try std.testing.expectEqualStrings("copying source", activityLabel(&buffer, activityAction(copy), activityNoun(copy)));
    const fetch: daemon.build_events.Activity = .{
        .id = 3,
        .kind = .substitute,
        .subject = "/nix/store/01234567890123456789012345678901-source",
        .detail = "https://cache.example",
    };
    try std.testing.expectEqualStrings("fetching source", activityLabel(&buffer, activityAction(fetch), activityNoun(fetch)));
    try std.testing.expectEqual(nounAccent("source"), nounAccent("source"));
}
