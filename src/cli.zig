//! Small shared CLI presentation layer.
//!
//! Output policy lives here: terminal detection, color styles, and small
//! formatting primitives. Evaluation progress itself is backed by `std.Progress`.

const std = @import("std");
const eval_progress = @import("eval/progress.zig");

pub const When = enum {
    auto,
    always,
    never,
};

pub fn parseWhen(text: []const u8) ?When {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

pub fn stderrInteractive(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return std.Io.File.stderr().isTty(io) catch false;
}

pub fn shouldColor(mode: When, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => autoColor(stderrInteractive(io, env), env),
    };
}

pub fn autoColor(interactive: bool, env: *const std.process.Environ.Map) bool {
    if (!interactive) return false;
    if (env.get("NO_COLOR")) |_| return false;
    return true;
}

pub fn shouldProgress(mode: When, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => stderrInteractive(io, env),
    };
}

pub const Style = enum {
    heading,
    section,
    label,
    name,
    path,
    hash,
    dim,
    error_label,
    note_label,
    trace_label,
    success,
    warning,
};

pub fn styleCode(use_color: bool, which: Style) []const u8 {
    if (!use_color) return "";
    return switch (which) {
        .heading => "\x1b[1;35m",
        .section => "\x1b[1;36m",
        .label => "\x1b[36m",
        .name => "\x1b[1m",
        .path => "\x1b[32m",
        .hash => "\x1b[33m",
        .dim => "\x1b[2m",
        .error_label => "\x1b[1;31m",
        .note_label => "\x1b[1;36m",
        .trace_label => "\x1b[36m",
        .success => "\x1b[32m",
        .warning => "\x1b[33m",
    };
}

pub fn resetCode(use_color: bool) []const u8 {
    return if (use_color) "\x1b[0m" else "";
}

pub fn style(writer: *std.Io.Writer, use_color: bool, which: Style) !void {
    if (use_color) try writer.writeAll(styleCode(true, which));
}

pub fn reset(writer: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try writer.writeAll(resetCode(true));
}

pub fn writeLabel(writer: *std.Io.Writer, use_color: bool, label: []const u8) !void {
    try style(writer, use_color, .label);
    try writer.writeAll(label);
    try reset(writer, use_color);
}

pub const Stderr = struct {
    io: std.Io,
    locked: std.Io.LockedStderr,

    pub fn writer(self: *Stderr) *std.Io.Writer {
        return &self.locked.file_writer.interface;
    }

    pub fn flush(self: *Stderr) !void {
        try self.writer().flush();
    }

    pub fn deinit(self: *Stderr) void {
        self.io.unlockStderr();
    }
};

pub fn lockStderr(io: std.Io, buffer: []u8) std.Io.Cancelable!Stderr {
    return .{
        .io = io,
        .locked = try io.lockStderr(buffer, null),
    };
}

pub fn writeMaybePath(writer: *std.Io.Writer, use_color: bool, value: []const u8) !void {
    const is_path = isPathLike(value);
    if (is_path) try style(writer, use_color, .path);
    try writer.writeAll(value);
    if (is_path) try reset(writer, use_color);
}

pub fn isPathLike(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "/nix/store/") or std.mem.endsWith(u8, value, ".drv");
}

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
    /// Live counter lines, created lazily and refreshed via `setName`. These
    /// are owned exclusively by the sampler thread while a session runs (the
    /// sampler is joined before `session_end`/`deinit` touch them), so there's
    /// no cross-thread mutation of the same node.
    stats_node: ?std.Progress.Node = null,
    spec_node: ?std.Progress.Node = null,
    gc_node: ?std.Progress.Node = null,

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
        if (self.gc_node) |n| { n.end(); self.gc_node = null; }
        if (self.spec_node) |n| { n.end(); self.spec_node = null; }
        if (self.stats_node) |n| { n.end(); self.stats_node = null; }
        if (self.run_node) |n| { n.end(); self.run_node = null; }
    }

    pub fn sink(self: *EvalProgress) eval_progress.Sink {
        return .{
            .context = self,
            .emit_fn = emit,
        };
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
    }

    /// Refresh the live counter lines: a heap/wait readout, a speculation line,
    /// and (once the collector has run) a GC line whose item count is the
    /// collection tally. Runs on the sampler thread; these nodes are its alone.
    fn updateMetrics(self: *EvalProgress, m: eval_progress.Metrics) void {
        var buf: [std.Progress.Node.max_name_len]u8 = undefined;
        if (self.stats_node == null) self.stats_node = self.root.start("", 0);
        self.stats_node.?.setName(formatStats(&buf, m));

        if (self.spec_node == null) self.spec_node = self.root.start("", 0);
        self.spec_node.?.setName(formatSpec(&buf, m));

        if (m.gc_collections == 0) return;
        if (self.gc_node == null) self.gc_node = self.root.start("gc", 0);
        self.gc_node.?.setName(formatGc(&buf, m));
        self.gc_node.?.setCompletedItems(m.gc_collections);
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

/// The heap readout line (see `EvalProgress.updateMetrics`). When the demand
/// path is blocked, appends what it's waiting on — so the stage-tree-empty
/// windows still say something. Pure so it's unit-testable; `buf` must hold
/// `max_name_len` bytes.
fn formatStats(buf: []u8, m: eval_progress.Metrics) []const u8 {
    var objs: [16]u8 = undefined;
    var frcd: [16]u8 = undefined;
    var heap: [16]u8 = undefined;
    var rss: [16]u8 = undefined;
    const w = m.wait();
    if (w.len == 0) {
        return std.fmt.bufPrint(buf, "{s} objs · heap {s} · rss {s} · {s} forced", .{
            count(&objs, m.objects),
            mb(&heap, m.reserved_bytes),
            mb(&rss, m.rss_bytes),
            count(&frcd, m.forced),
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s} objs · heap {s} · rss {s} · {s} forced · waiting {s}", .{
        count(&objs, m.objects),
        mb(&heap, m.reserved_bytes),
        mb(&rss, m.rss_bytes),
        count(&frcd, m.forced),
        w,
    }) catch "";
}

/// The speculation-activity line: backlog + cumulative spec/steal counters.
fn formatSpec(buf: []u8, m: eval_progress.Metrics) []const u8 {
    var sub: [16]u8 = undefined;
    var rej: [16]u8 = undefined;
    var stl: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{d} pending · {s} spec · {s} rejected · {s} steals", .{
        m.pending,
        count(&sub, m.spec_submitted),
        count(&rej, m.spec_rejected),
        count(&stl, m.steals),
    }) catch "";
}

/// The collector line (shown once `gc_collections > 0`).
fn formatGc(buf: []u8, m: eval_progress.Metrics) []const u8 {
    var live: [16]u8 = undefined;
    var freed: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "gc ×{d} · {s} live · {s} freed", .{
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

test "parse terminal policy" {
    try std.testing.expectEqual(When.auto, parseWhen("auto").?);
    try std.testing.expect(parseWhen("sometimes") == null);
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

test "progress stats/spec/gc lines render as expected" {
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
        "2.5M objs · heap 1215MB · rss 1760MB · 12.3M forced",
        formatStats(&buf, m),
    );
    // Blocked on a source loc → the waiting clause appears.
    const w = "modules.nix:545";
    @memcpy(m.wait_buf[0..w.len], w);
    m.wait_len = w.len;
    try std.testing.expectEqualStrings(
        "2.5M objs · heap 1215MB · rss 1760MB · 12.3M forced · waiting modules.nix:545",
        formatStats(&buf, m),
    );
    try std.testing.expectEqualStrings(
        "8 pending · 1.2M spec · 34.0K rejected · 41.0K steals",
        formatSpec(&buf, m),
    );
    try std.testing.expectEqualStrings(
        "gc ×1 · 225MB live · 4.3M freed",
        formatGc(&buf, m),
    );
}
