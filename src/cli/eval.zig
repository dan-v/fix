//! `fix eval` — evaluate a Nix expression, file, or flake output and print the
//! value. This is the former default (no-subcommand) path, now a real command.

const std = @import("std");
const engine = @import("expr");
const progress_ui = @import("progress.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const eval_support = @import("eval_support.zig");
const debugger = @import("debugger.zig");
const trace_setup = @import("trace_setup.zig");
const stats = @import("stats.zig");
const timeline = engine.probe.timeline;

const Evaluator = engine.Evaluator;

pub const synopsis =
    \\usage: fix eval [options] [path | -e <expression>]
    \\
    \\evaluate a Nix expression, file, or flake output and print the value.
    \\with no source, evaluates ./default.nix (or, with --flake, the flake in the
    \\current directory).
;

pub fn run(process: @import("process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .eval);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);

    const source_arg = options.source orelse options.defaultSource();

    // The debugger needs a deterministic pause point: one worker, no
    // speculative forcing racing ahead of the break.
    const worker_count = if (options.debugger) 1 else try setup.workerCount(options);
    setup.applyMemoryBacking(options.hugetlb);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);

    var console: debugger.Console = undefined;
    if (options.debugger) {
        ev.setParallelismToggles(true, true);
        // Named chunks make the backtrace read like `pkgs.hello (chunk #42)`.
        ev.setCaptureChunkNames(true);
        console = .{ .allocator = allocator, .io = init.io, .use_color = term.use_color };
        console.install(&ev);
    }

    if (source_arg == .flake and !ev.languagePolicy().flakes_enabled) {
        std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(error.FlakesFeatureRequired), synopsis });
        return 2;
    }

    const source = eval_support.getSource(&ev, source_arg, options) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    // `--flake` and `-A`/`--arg` wrapping synthesize source text on
    // the evaluator's host allocator; plain expr/file text is borrowed (argv) or owned by the
    // evaluator's file cache.
    defer source.deinit(ev.hostAllocator());
    // Let the debugger show a source snippet for a `-e` expression (files it
    // reads from the FileCache).
    if (options.debugger) ev.setDebugSource(source.text);

    var progress = progress_ui.EvalProgress.init(init.io, term.show_progress);
    errdefer progress.deinit(false);
    // Only wire the sink when we'll actually draw: it drives a ~100ms counter
    // sampler, so a null sink keeps that fully out of the hot path when off.
    if (term.show_progress) ev.setProgressSink(progress.sink());

    var vm_trace = try trace_setup.setupVmTrace(allocator, init.io, options);
    defer vm_trace.deinit(allocator);
    if (vm_trace.trace) |t| ev.setVmTrace(t);

    var thunks_setup = try trace_setup.setupThunkTrace(allocator, init.io, &ev, options);
    defer thunks_setup.deinit(allocator);
    if (thunks_setup.trace) |t| ev.setThunkTrace(t);

    // Timeline is always compiled in and RUNTIME-gated: `--timeline[=path]`
    // calls `init()` which flips the runtime gate on; without it the probe
    // stays dormant (one predictable branch at quantum granularity, ~free).
    const timeline_path = options.timeline_path;
    if (timeline_path != null) {
        timeline.init(allocator, worker_count, 1 << 21, ev.internTable());
        timeline.setFlowSample(options.timeline_flows);
        ev.setTraceFlows(true);
        timeline.setSource(switch (source_arg) {
            .file => |p| p,
            .expr => "(expression)",
            .flake => |inst| inst,
        });
    }

    const eval_label = switch (source_arg) {
        .file => |p| std.fs.path.basename(p),
        .expr => "expression",
        .flake => |inst| inst,
    };
    const ok = try eval_support.evaluateAndWrite(init.io, options.evaluationMode(), term.use_color, options.show_trace, options.derivation_debug, &ev, source.text, eval_support.sourcePathOf(source_arg, source), eval_label);
    progress.deinit(ok);

    if (timeline_path) |p| timeline.dump(init.io, p, worker_count);
    vm_trace.finish();
    thunks_setup.finish();
    if (options.print_sched_stats) stats.report(&ev);
    return if (ok) 0 else 1;
}
