//! Build progress group: drives a set of `std.Progress` nodes off the daemon's
//! build activity/log stream (a node per build/substitute/download, updated
//! with `done/expected` progress). Nodes hang under the run node of the shared
//! `EvalProgress`, so eval and build render as one tree.

const std = @import("std");
const store = @import("nix").host.store;
const EvalProgress = @import("progress.zig").EvalProgress;

pub const BuildProgress = struct {
    progress: *EvalProgress,
    allocator: std.mem.Allocator,
    /// Active activity id -> its node.
    nodes: std.AutoHashMapUnmanaged(u64, std.Progress.Node) = .empty,

    pub fn init(allocator: std.mem.Allocator, progress: *EvalProgress) BuildProgress {
        return .{ .progress = progress, .allocator = allocator };
    }

    /// End all active nodes and free. Idempotent (safe to call before session
    /// teardown and again via defer).
    pub fn deinit(self: *BuildProgress) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| node.end();
        self.nodes.deinit(self.allocator);
        self.nodes = .empty;
    }

    pub fn sink(self: *BuildProgress) store.BuildSink {
        return .{
            .context = self,
            .on_start = onStart,
            .on_stop = onStop,
            .on_progress = onProgress,
            .on_log = onLog,
        };
    }

    fn onStart(context: *anyopaque, id: u64, activity_type: u64, text: []const u8) void {
        _ = activity_type;
        const self: *BuildProgress = @ptrCast(@alignCast(context));
        const node = self.progress.childNode(text);
        self.nodes.put(self.allocator, id, node) catch node.end();
    }

    fn onStop(context: *anyopaque, id: u64) void {
        const self: *BuildProgress = @ptrCast(@alignCast(context));
        if (self.nodes.fetchRemove(id)) |kv| kv.value.end();
    }

    fn onProgress(context: *anyopaque, id: u64, done: u64, expected: u64) void {
        const self: *BuildProgress = @ptrCast(@alignCast(context));
        if (self.nodes.get(id)) |node| {
            if (expected != 0) node.setEstimatedTotalItems(expected);
            node.setCompletedItems(done);
        }
    }

    fn onLog(context: *anyopaque, line: []const u8) void {
        // The activity nodes are the progress display; raw log lines (available
        // via `nix log`) are dropped so they don't fight the progress bar.
        _ = context;
        _ = line;
    }
};
