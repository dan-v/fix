//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const repl = cli.repl;
const disasm_cmd = cli.disasm;
const inspect_cmd = cli.inspect;
const trace_cmd = cli.trace;
const thunks_cmd = cli.thunks;
const store_cmd = cli.store;
const eval_cmd = cli.eval;
const instantiate_cmd = cli.instantiate;
const build_cmd = cli.build;
const block_cache = @import("base").block_cache;
const mem_tag = @import("runtime").mem_tag;

const ArgsIterator = std.process.Args.Iterator;
const SubcommandRun = *const fn (std.mem.Allocator, std.process.Init, *ArgsIterator) anyerror!u8;
const Subcommand = struct {
    name: []const u8,
    summary: []const u8,
    run: SubcommandRun,
};

const subcommands = [_]Subcommand{
    .{ .name = "eval", .summary = "evaluate an expression, file, or flake output and print the value", .run = eval_cmd.run_cmd },
    .{ .name = "instantiate", .summary = "evaluate to a derivation and add its .drv closure to the store", .run = instantiate_cmd.run_cmd },
    .{ .name = "build", .summary = "evaluate to a derivation, build its outputs, and link ./result", .run = build_cmd.run_cmd },
    .{ .name = "repl", .summary = "start an interactive read-eval-print loop", .run = repl.run_cmd },
    .{ .name = "disasm", .summary = "disassemble compiled bytecode for an expression", .run = disasm_cmd.run },
    .{ .name = "inspect", .summary = "evaluate and dump evaluator statistics", .run = inspect_cmd.run },
    .{ .name = "trace", .summary = "work with binary VM trace files", .run = trace_cmd.run },
    .{ .name = "thunks", .summary = "diff thunks-logs to find divergent resolutions", .run = thunks_cmd.run },
    .{ .name = "store", .summary = "query the nix-daemon (protocol version, path validity)", .run = store_cmd.run },
};

fn writeTopUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll("usage: fix <command> [options]\n\ncommands:\n");
    inline for (subcommands) |c| {
        try writer.print("  {s:<9} {s}\n", .{ c.name, c.summary });
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
    var big_blocks = block_cache.BlockCacheAllocator(mem_tag.vma).init(init.gpa);
    defer big_blocks.deinit();
    const allocator = if (comptime builtin.mode == .Debug) debug_gpa.allocator() else big_blocks.allocator();

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

    if (cli.isHelpFlag(command)) {
        cli.printHelp(init.io, topUsage(allocator));
        std.process.exit(0);
    }

    const code = runSubcommand(command, allocator, init, &args_iter) orelse {
        std.debug.print("fix: unknown command '{s}'\n\n{s}", .{ command, topUsage(allocator) });
        std.process.exit(2);
    };
    std.process.exit(code);
}

fn runSubcommand(name: []const u8, allocator: std.mem.Allocator, init: std.process.Init, args_iter: *ArgsIterator) ?u8 {
    inline for (subcommands) |subcommand| {
        if (std.mem.eql(u8, name, subcommand.name)) {
            return subcommand.run(allocator, init, args_iter) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                return 1;
            };
        }
    }
    return null;
}
