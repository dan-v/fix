//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const process_support = @import("process_support");
const commands = cli.commands;
const command_match = cli.command_match;

const ArgsIterator = std.process.Args.Iterator;
const SubcommandRun = *const fn (cli.ProcessContext, std.process.Init, *ArgsIterator) anyerror!u8;
const Subcommand = struct {
    name: []const u8,
    summary: []const u8,
    run: SubcommandRun,
};

const subcommands = [_]Subcommand{
    .{ .name = "build", .summary = "evaluate to a derivation, build its outputs, and link ./result", .run = commands.build.run },
    .{ .name = "disasm", .summary = "disassemble compiled bytecode for an expression", .run = commands.disasm.run },
    .{ .name = "eval", .summary = "evaluate an expression, file, or flake output and print the value", .run = commands.eval.run },
    .{ .name = "instantiate", .summary = "evaluate to a derivation and add its .drv closure to the store", .run = commands.instantiate.run },
    .{ .name = "parse", .summary = "parse an expression and print its AST as JSON", .run = commands.parse.run },
    .{ .name = "repl", .summary = "start an interactive read-eval-print loop", .run = commands.repl.run },
    .{ .name = "run", .summary = "build a derivation and run a program from its output", .run = commands.run.run },
    .{ .name = "shell", .summary = "build a derivation and open a shell with its bin/ on PATH", .run = commands.shell.run },
    .{ .name = "switch", .summary = "build and activate a NixOS/nix-darwin/home-manager configuration", .run = commands.@"switch".run },
} ++ (if (cli.thunks_log_enabled) [_]Subcommand{
    .{ .name = "thunks", .summary = "diff thunks-logs to find divergent resolutions", .run = commands.thunks.run },
} else [_]Subcommand{}) ++ (if (cli.vm_trace_enabled) [_]Subcommand{
    .{ .name = "trace", .summary = "work with binary VM trace files", .run = commands.trace.run },
} else [_]Subcommand{});

const subcommand_names = blk: {
    var names: [subcommands.len][]const u8 = undefined;
    for (subcommands, 0..) |subcommand, index| names[index] = subcommand.name;
    break :blk names;
};

fn writeTopUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll("usage: fix <command> [options]\n\ncommands:\n");
    inline for (subcommands) |c| {
        try writer.print("  {s:<12} {s}\n", .{ c.name, c.summary });
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
                if (std.mem.startsWith(u8, candidate.name, command))
                    std.debug.print(" {s}", .{candidate.name});
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
