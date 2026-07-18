//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const process_support = @import("process_support");
const commands = cli.commands;
const command_match = cli.command_match;
const command_meta = cli.command_meta;

const ArgsIterator = std.process.Args.Iterator;
const SubcommandRun = *const fn (cli.ProcessContext, std.process.Init, *ArgsIterator) anyerror!u8;
const Subcommand = struct {
    meta: command_meta.Command,
    run: SubcommandRun,
};

fn commandEnabled(comptime kind: command_meta.Kind) bool {
    return switch (kind) {
        .thunks => cli.thunks_log_enabled,
        .trace => cli.vm_trace_enabled,
        else => true,
    };
}

fn commandRun(comptime kind: command_meta.Kind) SubcommandRun {
    return switch (kind) {
        .build => commands.build.run,
        .completions => commands.completions.run,
        .disasm => commands.disasm.run,
        .eval => commands.eval.run,
        .instantiate => commands.instantiate.run,
        .parse => commands.parse.run,
        .repl => commands.repl.run,
        .run => commands.run.run,
        .shell => commands.shell.run,
        .@"switch" => commands.@"switch".run,
        .thunks => commands.thunks.run,
        .trace => commands.trace.run,
    };
}

const subcommand_count = blk: {
    var count = 0;
    for (command_meta.table) |command| {
        if (commandEnabled(command.kind)) count += 1;
    }
    break :blk count;
};

const subcommands = blk: {
    var result: [subcommand_count]Subcommand = undefined;
    var index = 0;
    for (command_meta.table) |command| {
        if (commandEnabled(command.kind)) {
            result[index] = .{ .meta = command, .run = commandRun(command.kind) };
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
    // The std-provided Debug `gpa` captures a DWARF stack trace on every
    // alloc/free, under a global mutex. On an eval-heavy run that's a ~30x
    // slowdown (w=1 nixos_toplevel: ~80s vs ~3s ReleaseSafe) — slow enough
    // to look like a hang, and it masks any real parallelism behaviour
    // because the allocator serialises everything. Use our own
    // DebugAllocator with trace capture off: same double-free / leak
    // detection, none of the per-alloc unwind cost. Release builds keep
    // the fast std `gpa` untouched (perf numbers depend on it).
    var debug_gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug_gpa.deinit();
    // Release: wrap the gpa in the large-block reuse cache — SmpAllocator
    // maps/unmaps every >=64KB allocation, and the eval's ~9K large
    // temporaries otherwise re-minor-fault ~2GB of pages per run (>20% of
    // w=1 wall in fault handling). See runtime/block_cache.zig.
    var big_blocks = process_support.LargeBlockAllocator.init(init.gpa);
    defer big_blocks.deinit();
    const allocator = if (comptime builtin.mode == .Debug) debug_gpa.allocator() else big_blocks.allocator();
    const process: cli.ProcessContext = .{
        .allocator = allocator,
        .eval_release = .{ .context = &big_blocks, .run = trimLargeBlocks },
    };

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // argv[0]

    // A subcommand is required. Missing/unknown commands are a usage error:
    // print to stderr and exit nonzero (2). `-h`/`--help` prints to stdout and
    // exits 0 (POSIX).
    const command = args_iter.next() orelse {
        std.debug.print("{s}", .{topUsage(allocator)});
        std.process.exit(2);
    };

    if (cli.presentation.isHelpFlag(command)) {
        cli.presentation.printHelp(init.io, topUsage(allocator));
        std.process.exit(0);
    }

    const subcommand = switch (command_match.resolve(&subcommand_names, command)) {
        .match => |index| &subcommands[index],
        .ambiguous => {
            std.debug.print("fix: ambiguous command '{s}' (could be:", .{command});
            for (subcommands) |candidate| {
                if (std.mem.startsWith(u8, candidate.meta.name, command))
                    std.debug.print(" {s}", .{candidate.meta.name});
            }
            std.debug.print(")\n\n{s}", .{topUsage(allocator)});
            std.process.exit(2);
        },
        .none => {
            std.debug.print("fix: unknown command '{s}'\n\n{s}", .{ command, topUsage(allocator) });
            std.process.exit(2);
        },
    };
    std.process.exit(runSubcommand(subcommand, process, init, &args_iter));
}

fn runSubcommand(subcommand: *const Subcommand, process: cli.ProcessContext, init: std.process.Init, args_iter: *ArgsIterator) u8 {
    return subcommand.run(process, init, args_iter) catch |err| {
        // `error.ConfigError` (e.g. a bad nix.conf include) already printed
        // its own message; don't double-report.
        if (err != error.ConfigError) std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn trimLargeBlocks(context: *anyopaque) void {
    const blocks: *process_support.LargeBlockAllocator = @ptrCast(@alignCast(context));
    blocks.trim();
}
