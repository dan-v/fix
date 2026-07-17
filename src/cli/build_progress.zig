//! Build progress group: drives a set of `std.Progress` nodes off the daemon's
//! build activity/log stream (a node per build/substitute/download, updated
//! with `done/expected` progress). Nodes hang under the run node of the shared
//! `EvalProgress`, so eval and build render as one tree.

const std = @import("std");
const engine = @import("nix");
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

    pub fn sink(self: *BuildProgress) engine.BuildSink {
        return .{
            .context = self,
            .emit_fn = emit,
        };
    }

    fn emit(context: *anyopaque, event: engine.BuildEvent) void {
        const self: *BuildProgress = @ptrCast(@alignCast(context));
        switch (event) {
            .start => |activity| {
                const node = self.progress.childNode(activity.text);
                self.nodes.put(self.allocator, activity.id, node) catch node.end();
            },
            .stop => |id| if (self.nodes.fetchRemove(id)) |kv| kv.value.end(),
            .progress => |update| if (self.nodes.get(update.id)) |node| {
                if (update.expected != 0) node.setEstimatedTotalItems(update.expected);
                node.setCompletedItems(update.done);
            },
            .log => {},
        }
    }
};
