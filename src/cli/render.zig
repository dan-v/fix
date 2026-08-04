//! Rendering of evaluation errors and trace frames to stderr.

const std = @import("std");
const presentation = @import("presentation.zig");
const engine = @import("expr");
const Engine = engine.Engine;
const EvalTrace = engine.EvalTrace;

const default_trace_limit = 8;

/// Render an ordinary CLI failure with the same colored label used by
/// evaluation diagnostics. `format` is the text after `error: ` and may
/// contain daemon-provided continuation lines.
pub fn messageError(io: std.Io, use_color: bool, comptime format: []const u8, args: anytype) void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = presentation.lockStderr(io, &stderr_buffer) catch return;
    defer stderr.deinit();
    messageErrorTo(stderr.writer(), use_color, format, args) catch return;
    stderr.flush() catch {};
}

pub fn messageErrorTo(writer: *std.Io.Writer, use_color: bool, comptime format: []const u8, args: anytype) !void {
    try writeLabel(writer, use_color, .error_label, "error");
    try writer.print(format, args);
    try writer.writeByte('\n');
}

/// Render a non-fatal condition with a colored `warning:` label.
pub fn messageWarning(io: std.Io, use_color: bool, comptime format: []const u8, args: anytype) void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = presentation.lockStderr(io, &stderr_buffer) catch return;
    defer stderr.deinit();
    messageWarningTo(stderr.writer(), use_color, format, args) catch return;
    stderr.flush() catch {};
}

pub fn messageWarningTo(writer: *std.Io.Writer, use_color: bool, comptime format: []const u8, args: anytype) !void {
    try writeLabel(writer, use_color, .warning, "warning");
    try writer.print(format, args);
    try writer.writeByte('\n');
}

/// A `hint:` continuation line naming an action the user can take.
pub fn hintTo(writer: *std.Io.Writer, use_color: bool, comptime format: []const u8, args: anytype) !void {
    try writeLabel(writer, use_color, .note_label, "hint");
    try writer.print(format, args);
    try writer.writeByte('\n');
}

fn writeLabel(writer: *std.Io.Writer, use_color: bool, which: presentation.Style, label: []const u8) !void {
    try presentation.style(writer, use_color, which);
    try writer.writeAll(label);
    try presentation.reset(writer, use_color);
    try writer.writeAll(": ");
}

/// Render a failure caught as a Zig error: `error: <context>: <friendly
/// name>`, plus a `hint:` line when the error has a known remedy. This is the
/// user-facing spelling for caught errors; never print `@errorName` directly.
pub fn caughtError(io: std.Io, use_color: bool, err: anyerror, comptime context: []const u8, args: anytype) void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = presentation.lockStderr(io, &stderr_buffer) catch return;
    defer stderr.deinit();
    caughtErrorTo(stderr.writer(), use_color, err, context, args) catch return;
    stderr.flush() catch {};
}

pub fn caughtErrorTo(writer: *std.Io.Writer, use_color: bool, err: anyerror, comptime context: []const u8, args: anytype) !void {
    try writeLabel(writer, use_color, .error_label, "error");
    if (context.len > 0) {
        try writer.print(context, args);
        try writer.writeAll(": ");
    }
    try writer.print("{f}\n", .{friendly(err)});
    if (errorHint(err)) |remedy| try hintTo(writer, use_color, "{s}", .{remedy});
}

/// Wrap a caught Zig error for `{f}` display: well-known errors render as
/// prose ("no such file or directory"); the rest de-camelize their error name
/// ("LockFileInvalid" → "lock file invalid") so users never see
/// `error.CamelCase` verbatim.
pub fn friendly(err: anyerror) FriendlyError {
    return .{ .err = err };
}

pub const FriendlyError = struct {
    err: anyerror,

    pub fn format(self: FriendlyError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (describeError(self.err)) |prose| return writer.writeAll(prose);
        const name = @errorName(self.err);
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c)) {
                const follows_word = i > 0 and (std.ascii.isLower(name[i - 1]) or std.ascii.isDigit(name[i - 1]));
                const starts_word = i + 1 < name.len and std.ascii.isLower(name[i + 1]);
                if (follows_word or (i > 0 and starts_word)) try writer.writeByte(' ');
                try writer.writeByte(std.ascii.toLower(c));
            } else {
                try writer.writeByte(c);
            }
        }
    }
};

fn describeError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        error.OutOfMemory => "out of memory",
        error.BrokenPipe => "broken pipe",
        error.ConnectionRefused => "connection refused",
        error.ConnectionResetByPeer => "connection reset by peer",
        error.CurrentWorkingDirectoryUnlinked => "the current working directory no longer exists",
        error.StoreUnavailable => "cannot reach the nix-daemon",
        error.Unexpected => "unexpected system error",
        else => null,
    };
}

/// An actionable remedy for errors whose fix is environment-level rather than
/// call-site-specific. Context-dependent hints belong at the call site.
pub fn errorHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.StoreUnavailable, error.ConnectionRefused => "check that the nix-daemon is running (e.g. `systemctl status nix-daemon`), or point --store/NIX_REMOTE at a reachable store",
        error.FlakesFeatureRequired => "re-run with `--extra-experimental-features flakes`, or add `experimental-features = nix-command flakes` to nix.conf",
        error.CurrentWorkingDirectoryUnlinked => "cd to an existing directory and re-run",
        else => null,
    };
}

/// Render an argument/usage error, before command settings exist: color is
/// auto-detected from the environment. `offending` names the argument that
/// failed to parse, when the parser recorded it.
pub fn usageError(
    io: std.Io,
    env: *const std.process.Environ.Map,
    message: []const u8,
    offending: ?[]const u8,
    synopsis: []const u8,
) void {
    const use_color = presentation.colorDepth(.auto, io, env).enabled();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = presentation.lockStderr(io, &stderr_buffer) catch return;
    defer stderr.deinit();
    writeUsageError(stderr.writer(), use_color, message, offending, synopsis) catch return;
    stderr.flush() catch {};
}

fn writeUsageError(writer: *std.Io.Writer, use_color: bool, message: []const u8, offending: ?[]const u8, synopsis: []const u8) !void {
    try writeLabel(writer, use_color, .error_label, "error");
    try writer.writeAll(message);
    if (offending) |arg| try writer.print(": {s}", .{arg});
    try writer.writeAll("\n\n");
    try writer.writeAll(synopsis);
    try writer.writeByte('\n');
}

/// Render a failed evaluation: a parse/scan diagnostic if one was recorded,
/// otherwise the evaluation error with its trace.
pub fn evalFailure(
    io: std.Io,
    use_color: bool,
    show_trace: bool,
    ev: *Engine,
    source: []const u8,
    err: anyerror,
) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = try presentation.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    try writeEvalFailure(stderr.writer(), use_color, show_trace, ev, source, err, ev.getTrace(), true);
    try stderr.flush();
}

pub fn evaluationError(io: std.Io, use_color: bool, show_trace: bool, ev: *Engine, source: []const u8, err: anyerror) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = try presentation.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    if (ev.getDiagnostics().len > 0)
        try ev.writeDiagnostics(stderr.writer(), source, use_color);
    try writeEvaluationError(stderr.writer(), use_color, show_trace, ev, source, err, ev.getTrace());
    try stderr.flush();
}

/// Render non-fatal diagnostics retained by a successful evaluation (currently
/// parser deprecations). Error paths use `evalFailure`, which already renders
/// the report and must not call this as well.
pub fn evalDiagnostics(io: std.Io, use_color: bool, ev: *Engine, source: []const u8) !void {
    if (ev.getDiagnostics().len == 0) return;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = try presentation.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    try ev.writeDiagnostics(stderr.writer(), source, use_color);
    try stderr.flush();
}

/// Writer-targeted variants used by terminal surfaces that own their output
/// region (notably the REPL transcript). Keeping the rendering here prevents
/// interactive and plain diagnostics from drifting apart.
pub fn evalFailureTo(writer: *std.Io.Writer, use_color: bool, show_trace: bool, ev: *Engine, source: []const u8, err: anyerror) !void {
    try writeEvalFailure(writer, use_color, show_trace, ev, source, err, ev.getTrace(), true);
}

pub fn evaluationErrorTo(writer: *std.Io.Writer, use_color: bool, show_trace: bool, ev: *Engine, source: []const u8, err: anyerror) !void {
    try writeEvaluationError(writer, use_color, show_trace, ev, source, err, ev.getTrace());
}

/// Render a parallel-input failure while evaluator source and trace state are
/// still alive. The caller can emit the owned bytes later, after workers are
/// quiescent, without reducing the error to its Zig error-set name.
pub fn captureEvalFailure(
    allocator: std.mem.Allocator,
    use_color: bool,
    show_trace: bool,
    ev: *Engine,
    source: []const u8,
    failure: Engine.ParallelFailure,
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
    ev: *Engine,
    source: []const u8,
    err: anyerror,
    trace: *const EvalTrace,
    diagnostics: bool,
) !void {
    if (diagnostics) {
        const items = ev.getDiagnostics();
        const has_error = for (items) |item| {
            if (item.severity == .err) break true;
        } else false;
        if (has_error) return ev.writeDiagnostics(writer, source, use_color);
        if (items.len > 0) try ev.writeDiagnostics(writer, source, use_color);
    }
    try writeEvaluationError(writer, use_color, show_trace, ev, source, err, trace);
}

fn writeEvaluationError(
    writer: *std.Io.Writer,
    use_color: bool,
    show_trace: bool,
    ev: *Engine,
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
        try writer.print(": evaluation failed: {f}\n", .{friendly(err)});
    }

    try writeTraceFrames(writer, use_color, show_trace, ev, source, trace.frames.items);
}

fn writeTraceFrames(
    writer: *std.Io.Writer,
    use_color: bool,
    show_trace: bool,
    ev: *Engine,
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

fn writeTraceFrame(writer: *std.Io.Writer, use_color: bool, ev: *Engine, source: []const u8, frame: EvalTrace.Frame) !void {
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

fn traceFrameSource(ev: *Engine, source: []const u8, frame: EvalTrace.Frame) ?[]const u8 {
    if (frame.source_path) |path| {
        return ev.readSourceFile(path) catch null;
    }
    return source;
}

test "friendly errors read as prose, never error.CamelCase" {
    var buffer: [128]u8 = undefined;

    var known = std.Io.Writer.fixed(&buffer);
    try known.print("{f}", .{friendly(error.FileNotFound)});
    try std.testing.expectEqualStrings("no such file or directory", known.buffered());

    var decamelized = std.Io.Writer.fixed(&buffer);
    try decamelized.print("{f}", .{friendly(error.LockFileInvalid)});
    try std.testing.expectEqualStrings("lock file invalid", decamelized.buffered());

    var acronym = std.Io.Writer.fixed(&buffer);
    try acronym.print("{f}", .{friendly(error.TlsInitializationFailed)});
    try std.testing.expectEqualStrings("tls initialization failed", acronym.buffered());
}

test "caught errors carry an actionable hint when one is known" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try caughtErrorTo(&output.writer, false, error.StoreUnavailable, "", .{});
    try std.testing.expectEqualStrings(
        "error: cannot reach the nix-daemon\n" ++
            "hint: check that the nix-daemon is running (e.g. `systemctl status nix-daemon`), " ++
            "or point --store/NIX_REMOTE at a reachable store\n",
        output.written(),
    );

    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    try caughtErrorTo(&plain.writer, false, error.FileNotFound, "reading input {d}", .{2});
    try std.testing.expectEqualStrings("error: reading input 2: no such file or directory\n", plain.written());
}

test "usage errors name the offending argument" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeUsageError(&output.writer, false, "unknown option", "--frobnicate", "usage: fix eval [options]");
    try std.testing.expectEqualStrings(
        "error: unknown option: --frobnicate\n\nusage: fix eval [options]\n",
        output.written(),
    );
}

test "trace contexts render their complete prose once" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
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

test "parser warnings do not hide a later runtime error" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const source = ".5 + \"x\"";
    try std.testing.expectError(error.TypeError, ev.evaluate(source));

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeEvalFailure(&output.writer, false, false, &ev, source, error.TypeError, ev.getTrace(), true);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "warning: floating point literal without a leading zero") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "error: type error") != null);
}

test "message errors use the diagnostic error-label style" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try messageErrorTo(&output.writer, true, "input {d} build failed: {s}", .{ 1, "boom" });
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

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
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
