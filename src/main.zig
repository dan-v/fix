//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const eval = @import("eval.zig");
const repl = @import("cli/repl.zig");
const disasm_cmd = @import("cli/disasm.zig");
const inspect_cmd = @import("cli/inspect.zig");
const trace_cmd = @import("cli/trace.zig");
const thunks_cmd = @import("cli/thunks.zig");
const timeline = @import("probe/timeline.zig");
const stats = @import("cli/stats.zig");
const args = @import("cli/args.zig");
const run = @import("cli/run.zig");
const trace_setup = @import("cli/trace_setup.zig");
const tjit_hot = @import("jit/hot.zig");
const block_cache = @import("runtime").block_cache;
const Evaluator = eval.Evaluator;

const usage = args.usage;
const ArgsIterator = std.process.Args.Iterator;
const SubcommandRun = *const fn (std.process.Init, *ArgsIterator) anyerror!u8;
const Subcommand = struct { name: []const u8, run: SubcommandRun };

const subcommands = [_]Subcommand{
    .{ .name = "disasm", .run = disasm_cmd.run },
    .{ .name = "inspect", .run = inspect_cmd.run },
    .{ .name = "trace", .run = trace_cmd.run },
    .{ .name = "thunks", .run = thunks_cmd.run },
};

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
    var big_blocks = block_cache.BlockCacheAllocator.init(init.gpa);
    defer big_blocks.deinit();
    const allocator = if (comptime builtin.mode == .Debug) debug_gpa.allocator() else big_blocks.allocator();

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    const prog_name = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    _ = prog_name;

    const first_arg = args_iter.next();
    if (first_arg) |first| {
        const code = runSubcommand(first, init, &args_iter) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (code) |exit_code| std.process.exit(exit_code);
    }

    const options = args.parse(&args_iter, first_arg) catch |err| {
        std.debug.print("error: {s}\n\n{s}", .{ args.errorMessage(err), usage });
        std.process.exit(1);
    };

    const worker_count: u8 = options.workers orelse if (builtin.single_threaded)
        1
    else
        @intCast(@min(@as(u32, 8), @as(u32, @intCast(try std.Thread.getCpuCount()))));

    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    // Lazy shells only matter for lazy-XML rendering; elsewhere the wrap
    // is pure thunk-allocation overhead (see `vm.lazy_shells_visible`).
    ev.lazy_shells_visible = options.output == .xml;
    ev.pipe_operators_enabled = options.pipe_operators;
    ev.setParallelismToggles(options.disable_spec_thunks, options.disable_fanout);
    ev.setDerivationDebug(options.derivation_debug.enabled());
    ev.max_memory_bytes = options.max_memory;
    ev.setEnvironment(init.environ_map);
    try ev.setBasePathFromCurrentPath(init.io);
    if (init.environ_map.get("NIX_PATH")) |nix_path| try ev.setNixPath(nix_path);
    const use_color = cli.shouldColor(options.color, init.io, init.environ_map);
    const show_progress = cli.shouldProgress(options.progress, init.io, init.environ_map);
    if (use_color) std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch {};

    if (options.repl) {
        if (options.source != null) {
            std.debug.print("error: --repl does not take an expression or file\n\n{s}", .{usage});
            std.process.exit(1);
        }
        var progress = cli.EvalProgress.init(init.io, show_progress);
        var repl_ok = false;
        defer progress.deinit(repl_ok);
        // Only wire the sink when we'll actually draw: it drives a per-quantum
        // counter sampler (a /proc RSS read + scheduler tally), so a null sink
        // keeps that fully out of the hot path when progress is off.
        if (show_progress) ev.setProgressSink(progress.sink());
        try repl.run_loop(allocator, init.io, options, use_color, &ev);
        repl_ok = true;
        return;
    }

    const source_arg = options.source orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    const source = run.getSource(&ev, source_arg) catch |err| {
        std.debug.print("Error reading source: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var progress = cli.EvalProgress.init(init.io, show_progress);
    errdefer progress.deinit(false);
    // Only wire the sink when we'll actually draw (see the REPL path above):
    // keeps the per-quantum counter sampler out of the hot path when off.
    if (show_progress) ev.setProgressSink(progress.sink());

    var vm_trace = try trace_setup.setupVmTrace(allocator, init.io, options);
    defer vm_trace.deinit(allocator);
    if (vm_trace.trace) |t| ev.setVmTrace(t);

    var thunks_setup = try trace_setup.setupThunkTrace(allocator, init.io, &ev, options);
    defer thunks_setup.deinit(allocator);
    if (thunks_setup.trace) |t| ev.setThunkTrace(t);

    // Tracing-JIT diagnostics (trace dumps, hot-anchor list, exec counters)
    // print during/after eval only when stats are requested; otherwise a
    // `-Dtjit` build stays quiet. Must be set before evaluation since traces
    // are dumped as they're recorded.
    if (comptime tjit_hot.enabled) {
        tjit_hot.report_enabled = options.print_sched_stats;
    }

    // Timeline is always compiled in and RUNTIME-gated: `--timeline[=path]`
    // calls `init()` which flips the runtime gate on; without it the probe
    // stays dormant (one predictable branch at quantum granularity, ~free).
    const timeline_path = options.timeline_path;
    if (timeline_path != null) {
        timeline.init(allocator, worker_count, 1 << 21, &ev.intern);
        timeline.setFlowSample(options.timeline_flows);
        // Stamp push times so steal arrows anchor to the producing quantum.
        ev.scheduler.setTraceFlows(true);
        timeline.setSource(switch (source_arg) {
            .file => |p| p,
            .expr => "(expression)",
        });
    }

    const eval_label = switch (source_arg) {
        .file => |p| std.fs.path.basename(p),
        .expr => "expression",
    };
    const ok = try run.evaluateAndWrite(init.io, options.evaluationMode(), use_color, options.show_trace, options.derivation_debug, &ev, source.text, eval_label);
    progress.deinit(ok);

    if (timeline_path) |p| timeline.dump(init.io, p, worker_count);
    vm_trace.finish();
    thunks_setup.finish();
    if (options.print_sched_stats) stats.report(&ev);
    if (!ok) {
        std.process.exit(1);
    }
}

fn runSubcommand(name: []const u8, init: std.process.Init, args_iter: *ArgsIterator) !?u8 {
    inline for (subcommands) |subcommand| {
        if (std.mem.eql(u8, name, subcommand.name)) {
            return try subcommand.run(init, args_iter);
        }
    }
    return null;
}
