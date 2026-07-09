//! `fix disasm` — pretty-print compiled bytecode for an expression.

const std = @import("std");
const fix = @import("fix");
const eval = fix.eval;
const bytecode = fix.bytecode;
const cli = @import("cli.zig");
const builtin = @import("builtin");

const Evaluator = eval.Evaluator;
const ChunkId = @import("runtime").types.ChunkId;

const usage =
    \\usage: fix disasm [options] (-e <expression> | --file <path>)
    \\
    \\options:
    \\  -e, --expr EXPR    expression to compile
    \\  --file PATH        read expression from PATH
    \\  --chunk N          disassemble only chunk #N (defaults to all reachable)
    \\  --no-recurse       only show the top chunk
    \\  --no-source        omit source-span annotations
    \\  --no-constants     omit constant pool listing
    \\  -h, --help         show this help
    \\
;

const SourceArg = @import("args.zig").SourceArg;

const Options = struct {
    source: ?SourceArg = null,
    chunk: ?ChunkId = null,
    recurse: bool = true,
    show_source: bool = true,
    show_constants: bool = true,
};

pub fn run(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const options = parseOptions(args_iter) catch |err| switch (err) {
        error.Help => {
            cli.printHelp(init.io, usage);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}", .{ optionErrorMessage(err), usage });
            return 2;
        },
    };

    const source_arg = options.source orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const worker_count: u8 = if (builtin.single_threaded)
        1
    else
        @intCast(@min(@as(u32, 4), @as(u32, @intCast(try std.Thread.getCpuCount()))));

    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    ev.setEnvironment(init.environ_map);
    try ev.setBasePathFromCurrentPath(init.io);
    if (init.environ_map.get("NIX_PATH")) |nix_path| try ev.setNixPath(nix_path);

    const source = switch (source_arg) {
        .expr => |text| text,
        .file => |path| try ev.readSourceFile(path),
        .flake => {
            std.debug.print("error: --flake is not supported by this subcommand\n", .{});
            return 1;
        },
    };
    const source_path = switch (source_arg) {
        .expr => null,
        .file => |path| path,
        .flake => unreachable,
    };

    const top_id = ev.compileSource(source, source_path) catch |err| {
        std.debug.print("error: compilation failed: {s}\n", .{@errorName(err)});
        return 1;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &stdout.interface;

    const symbols = bytecode.disasm.Symbols{
        .intern = ev.internTable(),
        .registry = ev.chunkRegistry(),
    };
    const opts = bytecode.disasm.Options{
        .show_constants = options.show_constants,
        .show_source = options.show_source,
        .recurse = options.recurse,
        .max_depth = 16,
    };

    const target_id = options.chunk orelse top_id;
    const chunk = ev.getChunk(target_id) orelse {
        std.debug.print("error: chunk #{d} not found\n", .{target_id});
        return 1;
    };
    try bytecode.disasm.writeChunk(writer, target_id, chunk, symbols, opts);
    try writer.flush();
    return 0;
}

fn parseOptions(args_iter: *std.process.Args.Iterator) !Options {
    var options: Options = .{};
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.Help;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--expr")) {
            const text = args_iter.next() orelse return error.MissingExpression;
            if (options.source != null) return error.TooManySources;
            options.source = .{ .expr = text };
        } else if (std.mem.eql(u8, arg, "--file")) {
            const path = args_iter.next() orelse return error.MissingPath;
            if (options.source != null) return error.TooManySources;
            options.source = .{ .file = path };
        } else if (std.mem.eql(u8, arg, "--chunk")) {
            const text = args_iter.next() orelse return error.MissingChunkId;
            options.chunk = std.fmt.parseInt(ChunkId, text, 10) catch return error.InvalidChunkId;
        } else if (std.mem.eql(u8, arg, "--no-recurse")) {
            options.recurse = false;
        } else if (std.mem.eql(u8, arg, "--no-source")) {
            options.show_source = false;
        } else if (std.mem.eql(u8, arg, "--no-constants")) {
            options.show_constants = false;
        } else if (cli.parseWhen(arg)) |_| {
            // Ignored — no progress/color for disasm.
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

fn optionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingExpression => "missing expression after -e or --expr",
        error.MissingPath => "missing path after --file",
        error.MissingChunkId => "missing N after --chunk",
        error.InvalidChunkId => "expected --chunk to be a non-negative integer",
        error.TooManySources => "provide only one expression or file",
        error.UnknownOption => "unknown option",
        else => @errorName(err),
    };
}
