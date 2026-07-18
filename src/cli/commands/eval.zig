//! `fix eval` — evaluate a Nix expression, file, or flake output and print the
//! value. This is the former default (no-subcommand) path, now a real command.

const std = @import("std");
const engine = @import("expr");
const progress_ui = @import("../progress.zig");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");
const debugger = @import("../debugger.zig");
const trace_setup = @import("../trace_setup.zig");
const stats = @import("../stats.zig");

const Evaluator = engine.Evaluator;

pub const synopsis =
    \\usage: fix eval [options] [paths... | -E <expression>... | --flake <installable>...]
    \\
    \\evaluate Nix expressions, files, or flake outputs and print each value in
    \\input order.
    \\with no source, evaluates ./default.nix.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null, .eval) catch |err| switch (err) {
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

    // The debugger needs a deterministic pause point: one worker, no
    // speculative forcing racing ahead of the break.
    const worker_count = if (options.debugger) 1 else try setup.workerCount(options);
    setup.applyMemoryBacking(options.hugetlb);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);
    if (options.read_write_mode) {
        // Store writes are observable. Keep them on the demand path so helper
        // speculation cannot instantiate derivations the user never demanded.
        ev.setParallelismToggles(true, true);
        ev.enableReadWriteEvaluation();
    }

    var console: debugger.Console = undefined;
    if (options.debugger) {
        ev.setParallelismToggles(true, true);
        // Named chunks make the backtrace read like `pkgs.hello (chunk #42)`.
        ev.setCaptureChunkNames(true);
        console = .{ .allocator = allocator, .io = init.io, .use_color = term.use_color };
        console.install(&ev);
    }

    const input_plan = eval_support.InputPlan.init(options, init.io);
    input_plan.validate(&ev) catch |err| {
        std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
        return 2;
    };
    const input_count = try input_plan.count();

    const timeline_source = if (input_count == 1)
        eval_support.sourceLabel(input_plan.selected(0).source_arg)
    else
        "multiple inputs";
    var progress = try progress_ui.Session.init(
        allocator,
        init.io,
        &ev,
        term,
        options,
        timeline_source,
    );
    var ok = false;
    defer progress.deinit(ok);
    progress.install();

    var vm_trace = try trace_setup.setupVmTrace(allocator, init.io, options);
    defer vm_trace.deinit(allocator);
    if (vm_trace.trace) |t| ev.setVmTrace(t);

    var thunks_setup = try trace_setup.setupThunkTrace(allocator, init.io, &ev, options);
    defer thunks_setup.deinit(allocator);
    if (thunks_setup.trace) |t| ev.setThunkTrace(t);

    ok = true;
    for (0..input_count) |index| {
        const input = input_plan.load(&ev, index) catch |err| {
            eval_support.reportInputReadError(input_count, index, err);
            ok = false;
            continue;
        };
        defer input.deinit(&ev);
        // Let the debugger show snippets for synthesized expressions.
        if (options.debugger) ev.setDebugSource(input.source.text);
        const input_ok = try eval_support.evaluateAndWrite(
            init.io,
            options.evaluationMode(),
            term.use_color,
            options.show_trace,
            &ev,
            input.source,
            input.label(),
        );
        ok = input_ok and ok;
    }
    vm_trace.finish();
    thunks_setup.finish();
    if (options.stats) stats.report(&ev);
    return if (ok) 0 else 1;
}
