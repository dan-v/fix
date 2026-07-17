//! Evaluation progress rendering for the CLI.

const std = @import("std");
const eval_progress = @import("expr").EvalProgress;

pub const EvalProgress = struct {
    const max_active = 128;

    root: std.Progress.Node,
    active: [max_active]Active = undefined,
    active_len: usize = 0,
    /// Always-open parent for the coarse phase spans, opened on `session_begin`.
    /// Keeps at least one line visible during the windows where the demand path
    /// is blocked and the stage tree would otherwise be empty.
    run_node: ?std.Progress.Node = null,
    /// What the demand path is currently blocked on, shown as a `waiting <loc>`
    /// node under the run node during the windows where the stage tree is empty
    /// (demand parked while helpers churn). The demand fiber creates it before
    /// parking and ends it as soon as work resumes.
    waiting: ?std.Progress.Node = null,
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
        // Defensive: a well-formed run ends via `session_end`, but tear down
        // anything still open.
        self.endSessionNodes();
        std.Progress.setStatus(if (success) .success else .failure);
        self.root.end();
    }

    /// End the run node and any dangling child nodes, and null them so the next
    /// session (REPL) starts clean. Called from `session_end` and `deinit`.
    fn endSessionNodes(self: *EvalProgress) void {
        while (self.active_len != 0) {
            self.active_len -= 1;
            self.active[self.active_len].node.end();
        }
        if (self.waiting) |n| {
            n.end();
            self.waiting = null;
        }
        if (self.run_node) |n| {
            n.end();
            self.run_node = null;
        }
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

    /// Create a child node under the run node for a build activity (a build /
    /// substitute / download). Caller ends it. Used by the build progress
    /// group, which drives its own set of nodes off the daemon activity stream.
    pub fn childNode(self: *EvalProgress, name: []const u8) std.Progress.Node {
        const parent = self.run_node orelse self.root;
        return parent.start(name[0..@min(name.len, std.Progress.Node.max_name_len)], 0);
    }

    /// Concurrent-span support (see `eval_progress.Span`). Each activity is a
    /// direct child of the run node and is safe to open on one thread/fiber and
    /// close on another. A `std.Progress.Node` is just its index, so we
    /// round-trip it through the opaque token with no allocation.
    fn beginSpan(context: *anyopaque, subject: []const u8) usize {
        const self: *EvalProgress = @ptrCast(@alignCast(context));
        const node = self.childNode(subject);
        return @intFromEnum(node.index);
    }

    fn endSpan(context: *anyopaque, token: usize) void {
        _ = context;
        const node: std.Progress.Node = .{ .index = @enumFromInt(@as(u8, @intCast(token))) };
        node.end();
    }

    /// Report download bytes on a fetch span. `std.Progress` renders the node as
    /// `subject [downloaded/total]`; nodes are updated lock-free, so this is safe
    /// from the off-demand fetch thread. `total` 0 means the size isn't known yet
    /// (no Content-Length), leaving a bare downloaded count.
    fn updateSpan(context: *anyopaque, token: usize, downloaded: u64, total: u64) void {
        _ = context;
        const node: std.Progress.Node = .{ .index = @enumFromInt(@as(u8, @intCast(token))) };
        if (total != 0) node.setEstimatedTotalItems(@intCast(@min(total, std.math.maxInt(usize))));
        node.setCompletedItems(@intCast(@min(downloaded, std.math.maxInt(usize))));
    }

    fn emit(context: *anyopaque, event: eval_progress.Event) void {
        const self: *EvalProgress = @ptrCast(@alignCast(context));
        switch (event) {
            .begin => |step| self.beginStep(step),
            .end => |step| self.endStep(step.stage),
            .instant => |step| self.instantStep(step),
            .wait_begin => |subject| self.beginWaiting(subject),
            .wait_end => self.endWaiting(),
            .count => |c| self.updateCount(c),
            .session_begin => |label| self.sessionBegin(label),
            .session_end => self.endSessionNodes(),
        }
    }

    /// Apply an `[completed/total]` item count to the innermost stage span (the
    /// node the demand path is currently working under — e.g. render). Runs on
    /// the demand/main thread, same as the stage events that own `active[]`.
    fn updateCount(self: *EvalProgress, c: eval_progress.Count) void {
        if (self.active_len == 0) return;
        const node = self.active[self.active_len - 1].node;
        node.setEstimatedTotalItems(c.total);
        node.setCompletedItems(c.completed);
    }

    fn sessionBegin(self: *EvalProgress, label: []const u8) void {
        if (self.run_node != null) return;
        var buf: [std.Progress.Node.max_name_len]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "evaluating {s}", .{label}) catch "evaluating";
        self.run_node = self.root.start(name, 0);
    }

    fn beginWaiting(self: *EvalProgress, subject: []const u8) void {
        const run_node = self.run_node orelse return;
        if (subject.len == 0) return;
        var buf: [std.Progress.Node.max_name_len]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "waiting {s}", .{subject}) catch "waiting";
        if (self.waiting) |n| {
            n.setName(name);
        } else {
            self.waiting = run_node.start(name, 0);
        }
    }

    fn endWaiting(self: *EvalProgress) void {
        if (self.waiting) |n| n.end();
        self.waiting = null;
    }

    fn beginStep(self: *EvalProgress, step: eval_progress.Step) void {
        const parent = if (self.active_len != 0)
            self.active[self.active_len - 1].node
        else
            (self.run_node orelse self.root);
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
