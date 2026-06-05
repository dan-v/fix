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
};

pub fn stageName(stage: Stage) []const u8 {
    return switch (stage) {
        .parse => "parse",
        .compile => "compile",
        .evaluate => "evaluate",
        .import => "import",
        .derivation => "derivation",
        .render => "render",
    };
}

test "stage names are stable" {
    try std.testing.expectEqualStrings("evaluate", stageName(.evaluate));
}
