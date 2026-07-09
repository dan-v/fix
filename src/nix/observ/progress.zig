//! Evaluator progress events.
//!
//! This module deliberately has no terminal or formatting knowledge. The
//! evaluator can report durable work boundaries while the CLI decides whether
//! those events become a status line, log lines, or nothing at all.

const std = @import("std");

pub const Stage = enum {
    parse,
    compile,
    evaluate,
    import,
    derivation,
    store,
    render,
};

pub const Step = struct {
    stage: Stage,
    subject: []const u8 = "",
};

/// A periodic snapshot of live evaluator counters. Deliberately a plain
/// bag of numbers with no formatting knowledge — the producer (a worker-0
/// safepoint sampler, reusing the same reads that feed the `--timeline`
/// counter tracks) fills it, and the CLI decides how to render it. GC
/// fields are 0 in a non-`-Dgc` build (and until the first collection).
pub const Metrics = struct {
    // Heap object stores (live slot counts + committed bytes).
    objects: u64 = 0,
    values: u64 = 0,
    attrs: u64 = 0,
    reserved_bytes: u64 = 0,
    /// Resident set size (current), read from /proc.
    rss_bytes: u64 = 0,
    // Scheduler activity.
    pending: u64 = 0,
    /// Thunks forced (scheduler pops) — cumulative throughput.
    forced: u64 = 0,
    steals: u64 = 0,
    spec_submitted: u64 = 0,
    spec_rejected: u64 = 0,
    // Collector (`-Dgc`).
    gc_collections: u64 = 0,
    gc_live_bytes: u64 = 0,
    gc_freed_objects: u64 = 0,
    /// What the demand path is currently blocked on (a source loc like
    /// "modules.nix:545"), or empty when it isn't blocked. Inline so the
    /// snapshot is self-contained when handed across the sampler boundary.
    wait_buf: [ProgressWait.cap]u8 = undefined,
    wait_len: u8 = 0,

    pub fn wait(self: *const Metrics) []const u8 {
        return self.wait_buf[0..self.wait_len];
    }
};

/// A shared, single-writer / single-reader record of what the demand path is
/// currently blocked on. Written by the demand fiber (worker 0) at a blocking
/// safepoint and read by the progress sampler thread — so the empty-stage-tree
/// windows (demand blocked while helpers churn) still say what's being waited
/// on. Deliberately lock-free and best-effort: a torn read is cosmetic only,
/// so no seqlock. Only touched when progress is actually being drawn.
pub const ProgressWait = struct {
    pub const cap = 56;

    buf: [cap]u8 = undefined,
    len: std.atomic.Value(u8) = .init(0),

    pub fn set(self: *ProgressWait, text: []const u8) void {
        const n = @min(text.len, cap);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len.store(@intCast(n), .release);
    }

    pub fn clear(self: *ProgressWait) void {
        self.len.store(0, .release);
    }

    /// Copy the current subject into `out`; returns the byte count written.
    pub fn read(self: *const ProgressWait, out: []u8) usize {
        const n = @min(@as(usize, self.len.load(.acquire)), out.len, cap);
        @memcpy(out[0..n], self.buf[0..n]);
        return n;
    }
};

pub const Event = union(enum) {
    begin: Step,
    end: Step,
    instant: Step,
    metrics: Metrics,
    /// Set the item count `[completed/total]` on the *current* (innermost) stage
    /// span — e.g. the render node while the top-level result is walked. `total`
    /// 0 means "unknown" (renders a bare count). Emitted on the demand path only.
    count: Count,
    /// Open the always-visible run node (parent for the coarse phase spans);
    /// payload is a human label for what's being evaluated.
    session_begin: []const u8,
    /// Close the run node and the per-run metric lines.
    session_end: void,
};

pub const Count = struct {
    completed: usize,
    total: usize,
};

pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, Event) void,

    pub fn emit(self: Sink, event: Event) void {
        self.emit_fn(self.context, event);
    }

    pub fn begin(self: Sink, stage: Stage, subject: []const u8) void {
        self.emit(.{ .begin = .{ .stage = stage, .subject = subject } });
    }

    pub fn end(self: Sink, stage: Stage, subject: []const u8) void {
        self.emit(.{ .end = .{ .stage = stage, .subject = subject } });
    }

    pub fn instant(self: Sink, stage: Stage, subject: []const u8) void {
        self.emit(.{ .instant = .{ .stage = stage, .subject = subject } });
    }

    pub fn metrics(self: Sink, m: Metrics) void {
        self.emit(.{ .metrics = m });
    }

    pub fn count(self: Sink, completed: usize, total: usize) void {
        self.emit(.{ .count = .{ .completed = completed, .total = total } });
    }

    pub fn sessionBegin(self: Sink, label: []const u8) void {
        self.emit(.{ .session_begin = label });
    }

    pub fn sessionEnd(self: Sink) void {
        self.emit(.{ .session_end = {} });
    }
};

pub fn stageName(stage: Stage) []const u8 {
    return switch (stage) {
        .parse => "parse",
        .compile => "compile",
        .evaluate => "evaluate",
        .import => "import",
        .derivation => "derivation",
        .store => "store",
        .render => "render",
    };
}

test "stage names are stable" {
    try std.testing.expectEqualStrings("evaluate", stageName(.evaluate));
}
