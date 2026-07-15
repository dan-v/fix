//! Build progress group: drives a set of `std.Progress` nodes off the daemon's
//! build activity/log stream (a node per build/substitute/download, updated
//! with `done/expected` progress). Nodes hang under the run node of the shared
//! `EvalProgress`, so eval and build render as one tree.

const std = @import("std");
const store = @import("runtime").store;
const eval_progress = @import("fix").eval_progress;
const EvalProgress = @import("cli.zig").EvalProgress;

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

/// Build progress for the eager build pump, which runs off the demand fiber on
/// its own thread. Unlike `BuildProgress` (which drives the demand-path child
/// nodes), this routes every activity through the thread-safe *concurrent-span*
/// channel (`SpanSink`, the `.build` group) — the only progress path an
/// off-demand thread may touch without corrupting the demand fiber's
/// single-writer stage stack. Driven solely by the pump thread (one connection
/// = one serial stderr stream), so its `id -> Span` map needs no lock.
pub const EagerBuildSink = struct {
    spans: eval_progress.SpanSink,
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(u64, eval_progress.Span) = .empty,

    pub fn init(allocator: std.mem.Allocator, spans: eval_progress.SpanSink) EagerBuildSink {
        return .{ .spans = spans, .allocator = allocator };
    }

    pub fn deinit(self: *EagerBuildSink) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |span| self.spans.endSpan(span.*);
        self.nodes.deinit(self.allocator);
        self.nodes = .empty;
    }

    pub fn sink(self: *EagerBuildSink) store.BuildSink {
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
        const self: *EagerBuildSink = @ptrCast(@alignCast(context));
        const span = self.spans.beginSpan(.build, text);
        self.nodes.put(self.allocator, id, span) catch self.spans.endSpan(span);
    }

    fn onStop(context: *anyopaque, id: u64) void {
        const self: *EagerBuildSink = @ptrCast(@alignCast(context));
        if (self.nodes.fetchRemove(id)) |kv| self.spans.endSpan(kv.value);
    }

    fn onProgress(context: *anyopaque, id: u64, done: u64, expected: u64) void {
        const self: *EagerBuildSink = @ptrCast(@alignCast(context));
        if (self.nodes.get(id)) |span| self.spans.updateSpan(span, done, expected);
    }

    fn onLog(context: *anyopaque, line: []const u8) void {
        _ = context;
        _ = line;
    }
};
