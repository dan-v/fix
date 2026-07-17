//! Evaluation progress rendering for the CLI.

const std = @import("std");
const eval_progress = @import("expr").EvalProgress;
const Mutex = @import("base").sync.BlockingMutex;

pub const EvalProgress = struct {
    const max_active = 128;

    root: std.Progress.Node,
    active: [max_active]Active = undefined,
    active_len: usize = 0,
    /// Always-open parent for the coarse phase spans, opened on `session_begin`.
    /// Keeps at least one line visible during the windows where the demand path
    /// is blocked and the stage tree would otherwise be empty. Owned by the
    /// main thread (stage-event thread); the sampler only reads it as a parent.
    run_node: ?std.Progress.Node = null,
    /// The persistent "stats" subtree: a `stats` umbrella holding a section per
    /// subsystem (heap / scheduler / gc), each with per-metric child lines the
    /// sampler refreshes in place. Hangs off `run_node` as its first child (so
    /// the run is a single tree, stats above the eval spans). Built on the main
    /// thread in `sessionBegin`, then mutated only by the sampler thread — which
    /// is joined before `session_end`/`deinit` tear it down, so there's no
    /// cross-thread mutation of the same node.
    stats: ?Stats = null,
    /// What the demand path is currently blocked on, shown as a `waiting <loc>`
    /// node under the run node during the windows where the stage tree is empty
    /// (demand parked while helpers churn). Created and torn down lazily by the
    /// sampler thread as the block comes and goes, so it vanishes the moment
    /// work resumes. Sampler-owned, same as `stats`.
    waiting: ?std.Progress.Node = null,
    /// One grouping node per concurrent-span category (fetch / store / source),
    /// created lazily under the run node on the first span of that category and
    /// showing a live `[done/total]` count; individual spans nest under it.
    /// Created/read from any worker fiber, so guarded by `span_mu`. Persist for
    /// the session (ended in `endSessionNodes`).
    span_groups: [std.enums.values(eval_progress.SpanGroup).len]?std.Progress.Node =
        [_]?std.Progress.Node{null} ** std.enums.values(eval_progress.SpanGroup).len,
    span_mu: Mutex = .{},

    const Active = struct {
        stage: eval_progress.Stage,
        node: std.Progress.Node,
    };

    /// Live-counter node scaffold: a `stats` umbrella with one row per
    /// subsystem, each row carrying that section's whole compact readout. Every
    /// node is created up front in `Stats.build` and lives for the session; the
    /// sampler only mutates names. Future work will add sibling sections for
    /// the eval phases (eval / force / render / builds).
    const Stats = struct {
        node: std.Progress.Node, // "stats" umbrella
        heap: std.Progress.Node,
        sched: std.Progress.Node,
        gc: std.Progress.Node,

        fn build(parent: std.Progress.Node) Stats {
            var buf: [std.Progress.Node.max_name_len]u8 = undefined;
            const m: eval_progress.Metrics = .{}; // zero seed until the first sample
            const node = parent.start("stats", 0);
            return .{
                .node = node,
                .heap = node.start(fmtHeap(&buf, m), 0),
                .sched = node.start(fmtSched(&buf, m), 0),
                // Last child, so it sorts below the always-present sections.
                .gc = node.start(fmtGc(&buf, m), 0),
            };
        }

        /// Refresh every section row in place from one snapshot.
        fn update(self: *Stats, m: eval_progress.Metrics) void {
            var buf: [std.Progress.Node.max_name_len]u8 = undefined;
            self.heap.setName(fmtHeap(&buf, m));
            self.sched.setName(fmtSched(&buf, m));
            self.gc.setName(fmtGc(&buf, m));
        }

        /// End the rows before their `stats` parent (mirror of `build` order).
        fn deinit(self: *Stats) void {
            self.heap.end();
            self.sched.end();
            self.gc.end();
            self.node.end();
        }
    };

    pub fn init(io: std.Io, enabled: bool) EvalProgress {
        return .{
            .root = std.Progress.start(io, .{
                .root_name = "",
                .disable_printing = !enabled,
                .initial_delay_ns = .fromMilliseconds(180),
                // Paired with the evaluator's live-counter sample period
                // (`Evaluator.sample_period_ms`) — redrawing slower than the
                // sampler would hide samples; both are 50ms (20 Hz). The
                // redraw runs on std.Progress's own render thread, so like
                // the sampler it costs the eval path nothing.
                .refresh_rate_ns = .fromMilliseconds(50),
            }),
        };
    }

    pub fn deinit(self: *EvalProgress, success: bool) void {
        // Defensive: a well-formed run ends via `session_end`, but tear down
        // anything still open (the sampler is already stopped by this point).
        self.endSessionNodes();
        std.Progress.setStatus(if (success) .success else .failure);
        self.root.end();
    }

    /// End the run node, any dangling stage spans, and the metric lines, and
    /// null them so the next session (REPL) starts clean. Called from
    /// `session_end` and `deinit`; safe only once the sampler thread is joined.
    fn endSessionNodes(self: *EvalProgress) void {
        while (self.active_len != 0) {
            self.active_len -= 1;
            self.active[self.active_len].node.end();
        }
        if (self.waiting) |n| {
            n.end();
            self.waiting = null;
        }
        if (self.stats) |*s| {
            s.deinit();
            self.stats = null;
        }
        // Span group nodes (all children long since ended by their owners).
        for (&self.span_groups) |*g| if (g.*) |n| {
            n.end();
            g.* = null;
        };
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

    /// Concurrent-span support (see `eval_progress.Span`). A span is a child of
    /// its group's counting node — safe to open on one thread/fiber and close on
    /// another (unlike the single-writer `active[]` stage stack): std.Progress
    /// node start/end use a lock-free freelist, and `span_mu` only guards the
    /// lazy group-node creation + the per-group total bump. Ending a child span
    /// auto-increments the group's completed count, so the group renders
    /// `label [done/total]`. A `std.Progress.Node` is just its `index`, so we
    /// round-trip it through the opaque token with no allocation; node-storage
    /// exhaustion yields `Node.none`, whose `.end()` is a safe no-op.
    fn beginSpan(context: *anyopaque, group: eval_progress.SpanGroup, subject: []const u8) usize {
        const self: *EvalProgress = @ptrCast(@alignCast(context));
        self.span_mu.lock();
        defer self.span_mu.unlock();
        const gi = @intFromEnum(group);
        const parent = self.span_groups[gi] orelse blk: {
            const n = self.childNode(group.label());
            self.span_groups[gi] = n;
            break :blk n;
        };
        parent.increaseEstimatedTotalItems(1);
        const node = parent.start(subject[0..@min(subject.len, std.Progress.Node.max_name_len)], 0);
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
            .metrics => |m| self.updateMetrics(m),
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
        // Stats hangs off the run node as its first child (before any eval span,
        // which the demand path adds later), so the whole run is a single tree
        // rooted at "evaluating <label>". Built on the main thread before the
        // sampler is spawned, so the sampler only ever mutates these nodes.
        self.stats = Stats.build(self.run_node.?);
    }

    /// Refresh the stats subtree from a snapshot. Runs on the sampler thread;
    /// the nodes were created up front in `sessionBegin`, so this only mutates
    /// their names — the tree scaffold is the sampler's alone once the session
    /// is live. No-op before `sessionBegin` builds the tree.
    fn updateMetrics(self: *EvalProgress, m: eval_progress.Metrics) void {
        if (self.stats) |*s| s.update(m);
        self.updateWaiting(m);
    }

    /// Show/refresh/hide the `waiting <loc>` node under the run node to match
    /// the current block state. Runs on the sampler thread (and once on the
    /// main thread after it's joined, in `stopProgressSampler`) — the sole owner
    /// of `self.waiting`, so lazy create/end here is race-free.
    fn updateWaiting(self: *EvalProgress, m: eval_progress.Metrics) void {
        const run_node = self.run_node orelse return;
        const w = m.wait();
        if (w.len == 0) {
            if (self.waiting) |n| {
                n.end();
                self.waiting = null;
            }
            return;
        }
        var buf: [std.Progress.Node.max_name_len]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "waiting {s}", .{w}) catch "waiting";
        if (self.waiting) |n| {
            n.setName(name);
        } else {
            self.waiting = run_node.start(name, 0);
        }
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

// Per-section row formatters for the stats subtree (see `Stats`). Each writes
// one section's whole compact readout into `buf` (which must hold
// `max_name_len` bytes), prefixed by the section label. Pure so they're
// unit-testable; scratch buffers are 16 bytes — wide enough for any `count`/`mb`
// output.

fn fmtHeap(buf: []u8, m: eval_progress.Metrics) []const u8 {
    var objs: [16]u8 = undefined;
    var res: [16]u8 = undefined;
    var rss: [16]u8 = undefined;
    var frcd: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "heap · {s} objs · {s} reserved · {s} rss · {s} forced", .{
        count(&objs, m.objects),
        mb(&res, m.reserved_bytes),
        mb(&rss, m.rss_bytes),
        count(&frcd, m.forced),
    }) catch "";
}

/// The scheduler row. (What the demand path is blocked on lives on its own
/// `waiting` node under the run node — see `EvalProgress.updateMetrics` — since
/// it's eval status, not a scheduler counter.)
fn fmtSched(buf: []u8, m: eval_progress.Metrics) []const u8 {
    var sub: [16]u8 = undefined;
    var rej: [16]u8 = undefined;
    var stl: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "scheduler · {d} pending · {s} spec · {s} rejected · {s} steals", .{
        m.pending,
        count(&sub, m.spec_submitted),
        count(&rej, m.spec_rejected),
        count(&stl, m.steals),
    }) catch "";
}

/// The GC row.
fn fmtGc(buf: []u8, m: eval_progress.Metrics) []const u8 {
    var live: [16]u8 = undefined;
    var freed: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "gc · {d} collections · {s} live · {s} freed", .{
        m.gc_collections,
        mb(&live, m.gc_live_bytes),
        count(&freed, m.gc_freed_objects),
    }) catch "";
}

/// Compact human count into `buf`: bare below 1K, else a 1-decimal K/M/B
/// suffix (e.g. 1234 → "1.2K", 4_500_000 → "4.5M"). Returns "" on overflow.
fn count(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n < 1_000) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
    if (n < 1_000_000) return std.fmt.bufPrint(buf, "{d:.1}K", .{f / 1e3}) catch "";
    if (n < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.1}M", .{f / 1e6}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1}B", .{f / 1e9}) catch "";
}

/// Bytes → whole MiB into `buf` (e.g. "340MB"). Returns "" on overflow.
fn mb(buf: []u8, bytes: u64) []const u8 {
    const f: f64 = @floatFromInt(bytes);
    return std.fmt.bufPrint(buf, "{d:.0}MB", .{f / (1024.0 * 1024.0)}) catch "";
}

fn startStepNode(parent: std.Progress.Node, step: eval_progress.Step) std.Progress.Node {
    if (step.subject.len == 0) return parent.start(eval_progress.stageName(step.stage), 0);
    var buffer: [std.Progress.Node.max_name_len]u8 = undefined;
    const name = std.fmt.bufPrint(&buffer, "{s} {s}", .{
        eval_progress.stageName(step.stage),
        std.fs.path.basename(step.subject),
    }) catch eval_progress.stageName(step.stage);
    return parent.start(name, 0);
}

test "progress count formatter: bare / K / M / B thresholds" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", count(&b, 0));
    try std.testing.expectEqualStrings("999", count(&b, 999));
    try std.testing.expectEqualStrings("1.0K", count(&b, 1000));
    try std.testing.expectEqualStrings("1.2K", count(&b, 1234));
    try std.testing.expectEqualStrings("4.3M", count(&b, 4_334_128));
    try std.testing.expectEqualStrings("2.5B", count(&b, 2_500_000_000));
}

test "progress stats subtree lines render as expected" {
    // Numbers from a real `--max-memory=1200` NixOS eval (1 collection).
    var m: eval_progress.Metrics = .{
        .objects = 2_487_505,
        .reserved_bytes = 1215 * (1 << 20),
        .rss_bytes = 1760 * (1 << 20),
        .pending = 8,
        .forced = 12_345_678,
        .spec_submitted = 1_200_000,
        .spec_rejected = 34_000,
        .steals = 41_000,
        .gc_collections = 1,
        .gc_live_bytes = 224 * (1 << 20) + (7 << 20) / 10, // ~224.7 MB
        .gc_freed_objects = 4_334_128,
    };
    var buf: [std.Progress.Node.max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "heap · 2.5M objs · 1215MB reserved · 1760MB rss · 12.3M forced",
        fmtHeap(&buf, m),
    );
    try std.testing.expectEqualStrings(
        "scheduler · 8 pending · 1.2M spec · 34.0K rejected · 41.0K steals",
        fmtSched(&buf, m),
    );
    try std.testing.expectEqualStrings(
        "gc · 1 collections · 225MB live · 4.3M freed",
        fmtGc(&buf, m),
    );
    // The wait subject is not part of the scheduler row — it drives a separate
    // `waiting` node under the run node, so setting it changes nothing here.
    const w = "modules.nix:545";
    @memcpy(m.wait_buf[0..w.len], w);
    m.wait_len = w.len;
    try std.testing.expectEqualStrings(
        "scheduler · 8 pending · 1.2M spec · 34.0K rejected · 41.0K steals",
        fmtSched(&buf, m),
    );
}
