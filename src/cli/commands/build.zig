//! `fix build` — evaluate to a derivation, instantiate its closure, realize it
//! (build or substitute the outputs) via the daemon, link `./result`, and print
//! the output path. The nix build analogue.

const std = @import("std");
const engine = @import("expr");
const realization_workflow = @import("../realize.zig");
const progress_ui = @import("../progress.zig");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");

const Engine = engine.Engine;

pub const synopsis =
    \\usage: fix build [options] [paths... | -E <expr>... | --flake <installable>...]
    \\
    \\evaluate to a derivation, build (or substitute) its outputs, link ./result,
    \\and print the output path. With no source, uses ./default.nix.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null, .build) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .build);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);

    const worker_count = try setup.workerCount(options);
    const memory_backing = setup.applyMemoryBacking(process, options.hugetlb);
    var settings = try setup.loadSettingsAndFlakeConfig(allocator, init, options);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, worker_count, memory_backing));
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options, &settings);

    ev.enableStoreWrites();

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

    const inputs = try allocator.alloc(realization_workflow.BuildInput, input_count);
    var loaded: usize = 0;
    defer {
        for (inputs[0..loaded]) |*input| input.deinit(&ev);
        allocator.free(inputs);
    }

    while (loaded < inputs.len) : (loaded += 1) {
        inputs[loaded] = input_plan.load(&ev, loaded) catch |err| {
            eval_support.reportInputReadError(input_count, loaded, err);
            return 1;
        };
    }

    const code = if (options.dry_run)
        try realization_workflow.dryRunMany(allocator, init.io, &ev, process.eval_release, term, options, inputs)
    else
        try realization_workflow.realizeMany(allocator, init.io, &ev, process.eval_release, term, options, progress.renderer(), inputs);
    ok = code == 0;
    return code;
}

pub const makeLink = realization_workflow.makeLink;
pub const linkRoot = realization_workflow.linkRoot;
pub const numberedName = realization_workflow.numberedName;
