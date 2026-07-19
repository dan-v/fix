//! Rendering of evaluation errors and trace frames to stderr.

const std = @import("std");
const presentation = @import("presentation.zig");
const engine = @import("expr");
const Evaluator = engine.Evaluator;
const EvalTrace = engine.EvalTrace;

const default_trace_limit = 8;

/// Render an ordinary CLI failure with the same colored label used by
/// evaluation diagnostics. `format` is the text after `error: ` and may
/// contain daemon-provided continuation lines.
pub fn messageError(io: std.Io, use_color: bool, comptime format: []const u8, args: anytype) void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = presentation.lockStderr(io, &stderr_buffer) catch return;
    defer stderr.deinit();
    writeMessageError(stderr.writer(), use_color, format, args) catch return;
    stderr.flush() catch {};
}

fn writeMessageError(writer: *std.Io.Writer, use_color: bool, comptime format: []const u8, args: anytype) !void {
    try presentation.style(writer, use_color, .error_label);
    try writer.writeAll("error");
    try presentation.reset(writer, use_color);
    try writer.writeAll(": ");
    try writer.print(format, args);
    try writer.writeByte('\n');
}

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
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = try presentation.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    try writeEvalFailure(stderr.writer(), use_color, show_trace, ev, source, err, ev.getTrace(), true);
    try stderr.flush();
}

pub fn evaluationError(io: std.Io, use_color: bool, show_trace: bool, ev: *Evaluator, source: []const u8, err: anyerror) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = try presentation.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    try writeEvaluationError(stderr.writer(), use_color, show_trace, ev, source, err, ev.getTrace());
    try stderr.flush();
}

/// Writer-targeted variants used by terminal surfaces that own their output
/// region (notably the REPL transcript). Keeping the rendering here prevents
/// interactive and plain diagnostics from drifting apart.
pub fn evalFailureTo(writer: *std.Io.Writer, use_color: bool, show_trace: bool, ev: *Evaluator, source: []const u8, err: anyerror) !void {
    try writeEvalFailure(writer, use_color, show_trace, ev, source, err, ev.getTrace(), true);
}

pub fn evaluationErrorTo(writer: *std.Io.Writer, use_color: bool, show_trace: bool, ev: *Evaluator, source: []const u8, err: anyerror) !void {
    try writeEvaluationError(writer, use_color, show_trace, ev, source, err, ev.getTrace());
}

/// Render a parallel-input failure while evaluator source and trace state are
/// still alive. The caller can emit the owned bytes later, after workers are
/// quiescent, without reducing the error to its Zig error-set name.
pub fn captureEvalFailure(
    allocator: std.mem.Allocator,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: []const u8,
    failure: Evaluator.ParallelFailure,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeEvalFailure(
        &output.writer,
        use_color,
        show_trace,
        ev,
        source,
        failure.err,
        failure.trace,
        failure.diagnostics,
    );
    return allocator.dupe(u8, output.written());
}

fn writeEvalFailure(
    writer: *std.Io.Writer,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: []const u8,
    err: anyerror,
    trace: *const EvalTrace,
    diagnostics: bool,
) !void {
    if (diagnostics and ev.getDiagnostics().len > 0)
        try ev.writeDiagnostics(writer, source, use_color)
    else
        try writeEvaluationError(writer, use_color, show_trace, ev, source, err, trace);
}

fn writeEvaluationError(
    writer: *std.Io.Writer,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: []const u8,
    err: anyerror,
    trace: *const EvalTrace,
) !void {
    try presentation.style(writer, use_color, .error_label);
    try writer.writeAll("error");
    try presentation.reset(writer, use_color);
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

    try presentation.style(writer, use_color, .dim);
    try writer.writeAll("\ntrace:\n");
    try presentation.reset(writer, use_color);

    if (show_trace or frames.len <= default_trace_limit) {
        for (frames) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);
        return;
    }

    const head_count = default_trace_limit / 2;
    const tail_count = default_trace_limit - head_count;
    for (frames[0..head_count]) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);

    try presentation.style(writer, use_color, .dim);
    try writer.print("  ... {d} frames omitted; use --show-trace to show all\n", .{frames.len - default_trace_limit});
    try presentation.reset(writer, use_color);

    for (frames[frames.len - tail_count ..]) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);
}

fn writeTraceFrame(writer: *std.Io.Writer, use_color: bool, ev: *Evaluator, source: []const u8, frame: EvalTrace.Frame) !void {
    if (frame.kind == .evaluation) {
        const diag = frame.diagnostic orelse return;
        if (traceFrameSource(ev, source, frame)) |frame_source| {
            var located_diag = diag;
            located_diag.source_path = diag.source_path orelse frame.source_path orelse "expression";
            // The excerpt and caret already identify the expression, so omit a
            // redundant `near` fragment for VM trace frames.
            try ev.writeTraceDiagnostic(writer, frame_source, located_diag, use_color);
            return;
        }
        if (frame.source_path) |path| {
            try writer.print("  {s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.column, frame.message });
            return;
        }
        try writer.print("  expression:{d}:{d}: {s}\n", .{ diag.line, diag.column, frame.message });
        return;
    }

    // Error contexts are complete, user-controlled prose.  In particular,
    // nixpkgs often supplies messages beginning with "while evaluating";
    // adding our own generic prefix would duplicate it.  The frame kind, not
    // inspection of the message text, determines how it is rendered.
    try writer.print("  {s}\n", .{frame.message});
}

fn traceFrameSource(ev: *Evaluator, source: []const u8, frame: EvalTrace.Frame) ?[]const u8 {
    if (frame.source_path) |path| {
        return ev.readSourceFile(path) catch null;
    }
    return source;
}

test "trace contexts render their complete prose once" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    var trace = EvalTrace.init(std.testing.allocator);
    defer trace.deinit();
    try trace.pushContext("while evaluating definitions from `module.nix`");

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeTraceFrame(&output.writer, false, &ev, "", trace.frames.items[0]);

    try std.testing.expectEqualStrings(
        "  while evaluating definitions from `module.nix`\n",
        output.written(),
    );
}

test "message errors use the diagnostic error-label style" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeMessageError(&output.writer, true, "input {d} build failed: {s}", .{ 1, "boom" });
    try std.testing.expectEqualStrings(
        "\x1b[1;31merror\x1b[0m: input 1 build failed: boom\n",
        output.written(),
    );
}

test "trace diagnostics include source paths and keep excerpts on one line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "first\nsecond\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "module.nix", .data = source });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const source_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "module.nix",
    });
    defer std.testing.allocator.free(source_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    var trace = EvalTrace.init(std.testing.allocator);
    defer trace.deinit();
    try trace.pushDiagnosticFrame(source_path, .{
        .severity = .note,
        .kind = .compile,
        .line = 1,
        .column = 1,
        .offset = 0,
        .len = source.len,
        .token_type = null,
        .message = "while evaluating 'root'",
    });

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeTraceFrame(&output.writer, false, &ev, "unused", trace.frames.items[0]);

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "note: while evaluating 'root' at {s}:1:1\n   1 | first\n     | ^^^^^\n",
        .{source_path},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, output.written());
}
