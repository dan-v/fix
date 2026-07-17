//! Evaluator progress events.
//!
//! This module deliberately has no terminal or formatting knowledge. The
//! evaluator can report durable work boundaries while the CLI decides whether
//! those events become a status line, log lines, or nothing at all.

const std = @import("std");
const store_progress = @import("store").progress;

pub const SpanKind = store_progress.SpanKind;
pub const Span = store_progress.Span;
pub const SpanSink = store_progress.SpanSink;

pub const Stage = enum {
    parse,
    compile,
    evaluate,
    import,
    derivation,
    store,
    build,
    render,
};

pub const Step = struct {
    stage: Stage,
    subject: []const u8 = "",
};

pub const Event = union(enum) {
    begin: Step,
    end: Step,
    instant: Step,
    /// Show what the demand fiber is blocked on until `wait_end`. Emitted by
    /// that fiber immediately before and after it parks, so no polling or
    /// cross-thread snapshot is needed.
    wait_begin: []const u8,
    wait_end: void,
    /// Set the item count `[completed/total]` on the *current* (innermost) stage
    /// span — e.g. the render node while the top-level result is walked. `total`
    /// 0 means "unknown" (renders a bare count). Emitted on the demand path only.
    count: Count,
    /// Open the always-visible run node (parent for the coarse phase spans);
    /// payload is a human label for what's being evaluated.
    session_begin: []const u8,
    /// Close the run node and any per-run child nodes.
    session_end: void,
};

pub const Count = struct {
    completed: usize,
    total: usize,
};

/// The demand-path half of the progress protocol: the single-writer LIFO
/// stage stack (`begin`/`end`/`instant`/`count`) plus wait and per-run session
/// events. The stage stack is NOT thread-safe — exactly one logical
/// writer may drive it: the main thread during single-threaded setup, then
/// the demand fiber (which emits sequentially even if a steal migrates it
/// across workers). That is why this is a separate type from `SpanSink`: the
/// evaluator hands it out only to the demand fiber's execution context
/// (`eval/workers/context.zig`, read via `VM.ctx`), so an off-demand stage emit
/// has no handle to call
/// through — helpers only ever hold the thread-safe `SpanSink`. Don't add a
/// bypass. (`session_*` bracket the run on the main thread; wait events are
/// emitted serially by the same demand fiber that owns the stage stack.)
pub const StageSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, Event) void,

    pub fn emit(self: StageSink, event: Event) void {
        self.emit_fn(self.context, event);
    }

    pub fn begin(self: StageSink, stage: Stage, subject: []const u8) void {
        self.emit(.{ .begin = .{ .stage = stage, .subject = subject } });
    }

    pub fn end(self: StageSink, stage: Stage, subject: []const u8) void {
        self.emit(.{ .end = .{ .stage = stage, .subject = subject } });
    }

    pub fn instant(self: StageSink, stage: Stage, subject: []const u8) void {
        self.emit(.{ .instant = .{ .stage = stage, .subject = subject } });
    }

    pub fn waitBegin(self: StageSink, subject: []const u8) void {
        self.emit(.{ .wait_begin = subject });
    }

    pub fn waitEnd(self: StageSink) void {
        self.emit(.{ .wait_end = {} });
    }

    pub fn count(self: StageSink, completed: usize, total: usize) void {
        self.emit(.{ .count = .{ .completed = completed, .total = total } });
    }

    pub fn sessionBegin(self: StageSink, label: []const u8) void {
        self.emit(.{ .session_begin = label });
    }

    pub fn sessionEnd(self: StageSink) void {
        self.emit(.{ .session_end = {} });
    }
};

/// Both halves of the progress protocol, as one CLI implementation installs
/// them on the Evaluator (`setProgressSink`). The evaluator splits it from
/// there: every VM gets `spans`; only the demand VM ever sees `stage`.
pub const Sink = struct {
    stage: StageSink,
    spans: SpanSink,
};

pub fn stageName(stage: Stage) []const u8 {
    return switch (stage) {
        .parse => "parse",
        .compile => "compile",
        .evaluate => "evaluate",
        .import => "import",
        .derivation => "derivation",
        .store => "store",
        .build => "build",
        .render => "render",
    };
}

test "stage names are stable" {
    try std.testing.expectEqualStrings("evaluate", stageName(.evaluate));
}
