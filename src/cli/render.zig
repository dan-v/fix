//! Rendering of evaluation errors and trace frames to stderr.

const std = @import("std");
const cli = @import("cli.zig");
const diagnostic = @import("nix").diagnostic;
const eval = @import("nix").eval;
const Evaluator = eval.Evaluator;
const EvalTrace = eval.EvalTrace;

const default_trace_limit = 8;

/// Render a failed evaluation: a parse/scan diagnostic if one was recorded,
/// otherwise the evaluation error with its trace.
pub fn evalFailure(
    io: std.Io,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: []const u8,
    err: anyerror,
) !void {
    if (ev.getDiagnostics().len > 0) {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = try cli.lockStderr(io, &stderr_buffer);
        defer stderr.deinit();
        try diagnostic.writeAllWithOptions(stderr.writer(), source, ev.getDiagnostics(), .{ .color = use_color });
        try stderr.flush();
    } else {
        try evaluationError(io, use_color, show_trace, ev, source, err);
    }
}

pub fn evaluationError(io: std.Io, use_color: bool, show_trace: bool, ev: *Evaluator, source: []const u8, err: anyerror) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = try cli.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    const writer = stderr.writer();
    const trace = ev.getTrace();

    try cli.style(writer, use_color, .error_label);
    try writer.writeAll("error");
    try cli.reset(writer, use_color);
    if (err == error.DaemonError) {
        // An import-from-derivation build (or other on-demand store op) failed;
        // surface the daemon's own message, which the trace does not carry.
        try writer.print(": daemon: {s}\n", .{ev.lastStoreError() orelse "unknown store error"});
    } else if (trace.message) |message| {
        try writer.print(": {s}\n", .{message});
    } else {
        try writer.print(": evaluation failed with {s}\n", .{@errorName(err)});
    }

    try writeTraceFrames(writer, use_color, show_trace, ev, source, trace.frames.items);
    try stderr.flush();
}

fn writeTraceFrames(
    writer: *std.Io.Writer,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: []const u8,
    frames: []const EvalTrace.Frame,
) !void {
    if (frames.len == 0) return;

    try cli.style(writer, use_color, .dim);
    try writer.writeAll("\ntrace:\n");
    try cli.reset(writer, use_color);

    if (show_trace or frames.len <= default_trace_limit) {
        for (frames) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);
        return;
    }

    const head_count = default_trace_limit / 2;
    const tail_count = default_trace_limit - head_count;
    for (frames[0..head_count]) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);

    try cli.style(writer, use_color, .dim);
    try writer.print("  ... {d} frames omitted; use --show-trace to show all\n", .{frames.len - default_trace_limit});
    try cli.reset(writer, use_color);

    for (frames[frames.len - tail_count ..]) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);
}

fn writeTraceFrame(writer: *std.Io.Writer, use_color: bool, ev: *Evaluator, source: []const u8, frame: EvalTrace.Frame) !void {
    if (frame.diagnostic) |diag| {
        if (traceFrameSource(ev, source, frame)) |frame_source| {
            try diagnostic.writeAllWithOptions(writer, frame_source, &.{diag}, .{ .color = use_color });
            return;
        }
        if (frame.source_path) |path| {
            try writer.print("  {s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.column, frame.message });
            return;
        }
        try writer.print("  expression:{d}:{d}: {s}\n", .{ diag.line, diag.column, frame.message });
        return;
    }

    try writer.writeAll("  ");
    try cli.style(writer, use_color, .trace_label);
    try writer.writeAll("while evaluating");
    try cli.reset(writer, use_color);
    try writer.print(": {s}\n", .{frame.message});
}

fn traceFrameSource(ev: *Evaluator, source: []const u8, frame: EvalTrace.Frame) ?[]const u8 {
    if (frame.source_path) |path| {
        return ev.readSourceFile(path) catch null;
    }
    return source;
}
