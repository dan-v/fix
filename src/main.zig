//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const eval = @import("eval.zig");
const diagnostic = @import("diagnostic.zig");
const Evaluator = eval.Evaluator;
const Value = @import("value.zig").Value;

const usage =
    \\usage: fix [options] (<expression> | -e <expression> | --file <path>)
    \\
    \\options:
    \\  --json                 write the evaluated value as JSON
    \\  --show-trace           show full evaluation traces
    \\  --color[=when]         color diagnostics: auto, always, never
    \\  --no-color             disable color diagnostics
    \\  -h, --help             show this help
    \\
;

const OutputFormat = enum {
    nix,
    json,
};

const ColorMode = enum {
    auto,
    always,
    never,
};

const SourceArg = union(enum) {
    expr: []const u8,
    file: []const u8,
};

const Options = struct {
    output: OutputFormat = .nix,
    color: ColorMode = .auto,
    show_trace: bool = false,
    source: ?SourceArg = null,

    fn setSource(self: *Options, source: SourceArg) !void {
        if (self.source != null) return error.TooManySources;
        self.source = source;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    const prog_name = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    _ = prog_name;

    const options = parseOptions(&args_iter) catch |err| {
        std.debug.print("error: {s}\n\n{s}", .{ optionErrorMessage(err), usage });
        std.process.exit(1);
    };

    const worker_count: u8 = if (builtin.single_threaded)
        1
    else
        @intCast(@min(@as(u32, 8), @as(u32, @intCast(try std.Thread.getCpuCount()))));

    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    ev.setEnvironment(init.environ_map);
    try ev.setBasePathFromCurrentPath(init.io);
    if (init.environ_map.get("NIX_PATH")) |nix_path| try ev.setNixPath(nix_path);
    const use_color = shouldColor(options.color, init.io, init.environ_map);
    if (use_color) std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch {};

    const source_arg = options.source orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    const source = getSource(&ev, source_arg) catch |err| {
        std.debug.print("Error reading source: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const result = ev.evaluate(source.text) catch |err| {
        if (ev.getDiagnostics().len > 0) {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
            try diagnostic.writeAllWithOptions(&stderr.interface, source.text, ev.getDiagnostics(), .{ .color = use_color });
            try stderr.interface.flush();
        } else {
            try writeEvaluationError(init.io, use_color, options.show_trace, &ev, err);
        }
        std.process.exit(1);
    };

    writeResult(init.io, options.output, &ev, result) catch |err| {
        try writeEvaluationError(init.io, use_color, options.show_trace, &ev, err);
        std.process.exit(1);
    };
}

fn writeResult(io: std.Io, output: OutputFormat, ev: *Evaluator, result: Value) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    switch (output) {
        .nix => try ev.writeValue(&stdout.interface, result),
        .json => try ev.writeJsonValue(&stdout.interface, result),
    }
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

const Source = struct {
    text: []const u8,
};

fn getSource(
    ev: *Evaluator,
    source: SourceArg,
) !Source {
    return switch (source) {
        .expr => |text| .{ .text = text },
        .file => |path| .{ .text = try ev.readSourceFile(path) },
    };
}

fn parseOptions(args_iter: *std.process.Args.Iterator) !Options {
    var options: Options = .{};

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.output = .json;
        } else if (std.mem.eql(u8, arg, "--show-trace")) {
            options.show_trace = true;
        } else if (std.mem.eql(u8, arg, "--color")) {
            options.color = .always;
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            options.color = parseColorMode(arg["--color=".len..]) orelse return error.InvalidColorMode;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            options.color = .never;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-e")) {
            try options.setSource(.{ .expr = args_iter.next() orelse return error.MissingExpression });
        } else if (std.mem.eql(u8, arg, "--file")) {
            try options.setSource(.{ .file = args_iter.next() orelse return error.MissingPath });
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            try options.setSource(.{ .expr = arg });
        }
    }

    return options;
}

fn optionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingExpression => "missing expression after -e",
        error.MissingPath => "missing path after --file",
        error.TooManySources => "provide only one expression or file",
        error.InvalidColorMode => "expected --color to be auto, always, or never",
        error.UnknownOption => "unknown option",
        else => @errorName(err),
    };
}

fn parseColorMode(text: []const u8) ?ColorMode {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

fn shouldColor(mode: ColorMode, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => autoColor(io, env),
    };
}

fn autoColor(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("NO_COLOR")) |_| return false;
    if (env.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return std.Io.File.stderr().isTty(io) catch false;
}

const TraceStyle = enum {
    error_label,
    trace_label,
    dim,
};

const default_trace_limit = 8;

fn writeEvaluationError(io: std.Io, use_color: bool, show_trace: bool, ev: *const Evaluator, err: anyerror) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const writer = &stderr.interface;
    const trace = ev.getTrace();

    try traceStyle(writer, use_color, .error_label);
    try writer.writeAll("error");
    try traceReset(writer, use_color);
    if (trace.message) |message| {
        try writer.print(": {s}\n", .{message});
    } else {
        try writer.print(": evaluation failed with {s}\n", .{@errorName(err)});
    }

    try writeTraceFrames(writer, use_color, show_trace, trace.frames.items);
    try writer.flush();
}

fn writeTraceFrames(writer: *std.Io.Writer, use_color: bool, show_trace: bool, frames: []const []const u8) !void {
    if (frames.len == 0) return;

    try traceStyle(writer, use_color, .dim);
    try writer.writeAll("\ntrace:\n");
    try traceReset(writer, use_color);

    if (show_trace or frames.len <= default_trace_limit) {
        for (frames) |frame| try writeTraceFrame(writer, use_color, frame);
        return;
    }

    const head_count = default_trace_limit / 2;
    const tail_count = default_trace_limit - head_count;
    for (frames[0..head_count]) |frame| try writeTraceFrame(writer, use_color, frame);

    try traceStyle(writer, use_color, .dim);
    try writer.print("  ... {d} frames omitted; use --show-trace to show all\n", .{frames.len - default_trace_limit});
    try traceReset(writer, use_color);

    for (frames[frames.len - tail_count ..]) |frame| try writeTraceFrame(writer, use_color, frame);
}

fn writeTraceFrame(writer: *std.Io.Writer, use_color: bool, frame: []const u8) !void {
    try writer.writeAll("  ");
    try traceStyle(writer, use_color, .trace_label);
    try writer.writeAll("while evaluating");
    try traceReset(writer, use_color);
    try writer.print(": {s}\n", .{frame});
}

fn traceStyle(writer: *std.Io.Writer, use_color: bool, style: TraceStyle) !void {
    if (!use_color) return;
    try writer.writeAll(switch (style) {
        .error_label => "\x1b[1;31m",
        .trace_label => "\x1b[36m",
        .dim => "\x1b[2m",
    });
}

fn traceReset(writer: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try writer.writeAll("\x1b[0m");
}
