//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const process_support = @import("process_support");
const commands = cli.commands;
const command_match = cli.command_match;
const command_meta = cli.command_meta;

const ArgsIterator = std.process.Args.Iterator;
const Subcommand = struct {
    meta: command_meta.Command,
    run: commands.Runner,
};

const subcommand_count = blk: {
    var count = 0;
    for (command_meta.table) |command| {
        if (command_meta.enabled(command.kind)) count += 1;
    }
    break :blk count;
};

const subcommands = blk: {
    var result: [subcommand_count]Subcommand = undefined;
    var index = 0;
    for (command_meta.table) |command| {
        if (command_meta.enabled(command.kind)) {
            result[index] = .{ .meta = command, .run = commands.runner(command.kind) };
            index += 1;
        }
    }
    break :blk result;
};

const subcommand_names = blk: {
    var names: [subcommands.len][]const u8 = undefined;
    for (subcommands, 0..) |subcommand, index| names[index] = subcommand.meta.name;
    break :blk names;
};

fn writeTopUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll("usage: fix <command> [options]\n\ncommands:\n");
    inline for (subcommands) |c| {
        try writer.print("  {s:<12} {s}\n", .{ c.meta.name, c.meta.summary });
    }
    try writer.writeAll("\nrun `fix <command> -h` for command-specific help.\n");
}

/// Render the top-level usage into a heap buffer for one-shot printing.
fn topUsage(allocator: std.mem.Allocator) []const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    writeTopUsage(&buf.writer) catch return "usage: fix <command> [options]\n";
    return buf.toOwnedSlice() catch "usage: fix <command> [options]\n";
}

pub fn main(init: std.process.Init) !void {
    // Debug builds retain allocator diagnostics without capturing a stack on
    // every allocation, which would serialize evaluation on the unwind path.
    var debug_gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug_gpa.deinit();
    // Release builds reuse large temporary blocks to avoid repeated mappings
    // and first-touch faults.
    var big_blocks = process_support.LargeBlockAllocator.init(init.gpa);
    defer big_blocks.deinit();
    const allocator = if (comptime builtin.mode == .Debug) debug_gpa.allocator() else big_blocks.allocator();
    const process: cli.ProcessContext = .{
        .allocator = allocator,
        .eval_release = .{ .context = &big_blocks, .run = trimLargeBlocks },
        .memory_backing = big_blocks.hugePolicy(),
        .exits_after_command = true,
    };

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // argv[0]

    // A subcommand is required. Missing/unknown commands are a usage error:
    // print to stderr and exit nonzero (2). `-h`/`--help` prints to stdout and
    // exits 0 (POSIX).
    const command = args_iter.next() orelse {
        usageFailure(init, allocator, "missing command", .{});
    };

    if (cli.presentation.isHelpFlag(command)) {
        cli.presentation.printHelp(init.io, topUsage(allocator));
        std.process.exit(0);
    }

    const subcommand = switch (command_match.resolve(&subcommand_names, command)) {
        .match => |index| &subcommands[index],
        .ambiguous => {
            var candidates: std.Io.Writer.Allocating = .init(allocator);
            for (subcommands) |candidate| {
                if (std.mem.startsWith(u8, candidate.meta.name, command))
                    candidates.writer.print(" {s}", .{candidate.meta.name}) catch {};
            }
            usageFailure(init, allocator, "ambiguous command '{s}' (could be:{s})", .{ command, candidates.written() });
        },
        .none => {
            usageFailure(init, allocator, "unknown command '{s}'", .{command});
        },
    };
    std.process.exit(runSubcommand(subcommand, process, init, &args_iter));
}

/// Report a top-level usage error with the shared colored `error:` label,
/// follow with the command list, and exit 2.
fn usageFailure(init: std.process.Init, allocator: std.mem.Allocator, comptime format: []const u8, format_args: anytype) noreturn {
    const use_color = cli.presentation.colorDepth(.auto, init.io, init.environ_map).enabled();
    failure: {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = cli.presentation.lockStderr(init.io, &stderr_buffer) catch break :failure;
        defer stderr.deinit();
        cli.render.messageErrorTo(stderr.writer(), use_color, format, format_args) catch break :failure;
        stderr.writer().print("\n{s}", .{topUsage(allocator)}) catch break :failure;
        stderr.flush() catch {};
    }
    std.process.exit(2);
}

fn runSubcommand(subcommand: *const Subcommand, process: cli.ProcessContext, init: std.process.Init, args_iter: *ArgsIterator) u8 {
    return subcommand.run(process, init, args_iter) catch |err| {
        // `error.ConfigError` (e.g. a bad nix.conf include) already printed
        // its own message; don't double-report.
        if (err != error.ConfigError) {
            const use_color = cli.presentation.colorDepth(.auto, init.io, init.environ_map).enabled();
            cli.render.caughtError(init.io, use_color, err, "", .{});
        }
        return 1;
    };
}

fn trimLargeBlocks(context: *anyopaque) void {
    const blocks: *process_support.LargeBlockAllocator = @ptrCast(@alignCast(context));
    blocks.trim();
}
