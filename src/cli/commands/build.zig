//! `fix build` — evaluate to a derivation, instantiate its closure, realize it
//! (build or substitute the outputs) via the daemon, link `./result`, and print
//! the output path. The nix build analogue.

const std = @import("std");
const engine = @import("expr");
const realization_workflow = @import("../realize.zig");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");

const Evaluator = engine.Evaluator;

pub const synopsis =
    \\usage: fix build [options] [paths... | -e <expr>...]
    \\
    \\evaluate to a derivation, build (or substitute) its outputs, link ./result,
    \\and print the output path. With no source, uses ./default.nix (or, with
    \\--flake, the flake in the current directory).
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
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
    setup.applyMemoryBacking(options.hugetlb);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);

    ev.enableStoreWrites();

    var default_sources = [_]args.SourceArg{options.defaultSource()};
    const source_args = if (options.sources.items.len == 0) default_sources[0..] else options.sources.items;
    const selector_count = if (options.attrs.items.len == 0) 1 else options.attrs.items.len;
    const input_count = try std.math.mul(usize, source_args.len, selector_count);
    const inputs = try allocator.alloc(realization_workflow.BuildInput, input_count);
    var loaded: usize = 0;
    defer {
        for (inputs[0..loaded]) |input| input.source.deinit(ev.hostAllocator());
        allocator.free(inputs);
    }

    for (source_args) |source_arg| {
        if (source_arg == .flake and !ev.languagePolicy().flakes_enabled) {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(error.FlakesFeatureRequired), synopsis });
            return 2;
        }
        var selector_index: usize = 0;
        while (selector_index < selector_count) : (selector_index += 1) {
            var input_options = options;
            input_options.attr = if (options.attrs.items.len == 0) null else options.attrs.items[selector_index];
            const source = eval_support.getSource(&ev, source_arg, input_options) catch |err| {
                std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
                return 1;
            };
            inputs[loaded] = .{ .source = source };
            loaded += 1;
        }
    }

    return realization_workflow.realizeMany(allocator, init.io, &ev, process.eval_release, term, options, inputs);
}

pub const makeLink = realization_workflow.makeLink;
pub const linkRoot = realization_workflow.linkRoot;
