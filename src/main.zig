//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const eval = @import("eval.zig");
const diagnostic = @import("diagnostic.zig");
const Evaluator = eval.Evaluator;

const usage =
    \\usage: fix [options] (<expression> | -e <expression> | --file <path>)
    \\
    \\options:
    \\  --json                 write the evaluated value as JSON
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
            std.debug.print("Evaluation error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    switch (options.output) {
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
