//! `fix instantiate` — evaluate an expression/file/flake to a derivation,
//! write its `.drv` closure to the store (as each derivation is forced), and
//! print the top-level `.drv` path. The nix-instantiate analogue.

const std = @import("std");
const engine = @import("expr");
const progress_ui = @import("../progress.zig");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");
const stats = @import("../stats.zig");
const build = @import("build.zig");

const Engine = engine.Engine;

pub const synopsis =
    \\usage: fix instantiate [options] [paths... | -E <expr>... | --flake <installable>...]
    \\       fix instantiate --find-file [options] names...
    \\
    \\evaluate to derivations, add their .drv closures to the store, and print
    \\the top-level .drv paths in input order. With no source, uses ./default.nix.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null, .instantiate) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .instantiate);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);

    const worker_count = try setup.workerCount(&options);
    const memory_backing = setup.applyMemoryBacking(process, options.hugetlb);
    var settings = try setup.loadSettingsAndFlakeConfig(allocator, init, &options);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, worker_count, memory_backing));
    defer ev.deinit();
    const term = try setup.configure(&ev, init, &options, &settings);

    const input_plan = eval_support.InputPlan.init(&options, init.io);
    if (!options.find_file) {
        input_plan.validate(&ev) catch |err| {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        };
    }
    const input_count = if (options.find_file) options.sources.items.len else try input_plan.count();
    const timeline_source = if (options.find_file)
        "find-file"
    else if (input_count == 1)
        eval_support.sourceLabel(input_plan.selected(0).source_arg)
    else
        "multiple inputs";
    var progress = try progress_ui.Session.init(
        allocator,
        init.io,
        &ev,
        term,
        &options,
        timeline_source,
    );
    var ok = false;
    defer progress.deinit(ok);
    progress.install();

    if (options.find_file) {
        const code = try findFiles(init.io, &ev, options.sources.items);
        if (options.stats) stats.report(&ev);
        ok = code == 0;
        return code;
    }

    // Forcing a derivation now writes its `.drv` (and sources) to the store.
    // The daemon connects lazily on the first write.
    ev.enableStoreWrites();

    ok = true;
    for (0..input_count) |index| {
        var input = input_plan.load(&ev, index) catch |err| {
            eval_support.reportInputReadError(input_count, index, err);
            ok = false;
            continue;
        };
        defer input.deinit(&ev);
        ok = (try instantiateOne(allocator, init, term, &options, &ev, input, index)) and ok;
    }
    if (options.stats) stats.report(&ev);
    return if (ok) 0 else 1;
}

fn findFiles(io: std.Io, ev: *Engine, sources: []const args.SourceArg) !u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    for (sources) |source| {
        const name = switch (source) {
            .expr => |text| text,
            .file => |path| path,
            .flake => |installable| installable,
        };
        const path = ev.resolveLookupPath(ev.hostAllocator(), name) catch |err| {
            try stdout.interface.flush();
            if (err == error.FileNotFound)
                std.debug.print("error: file '{s}' was not found in the Nix search path (add it using $NIX_PATH or -I)\n", .{name})
            else
                std.debug.print("error: looking up file '{s}': {s}\n", .{ name, @errorName(err) });
            return 1;
        };
        defer ev.hostAllocator().free(path);
        try stdout.interface.print("{s}\n", .{path});
        try stdout.interface.flush();
    }
    return 0;
}

fn instantiateOne(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    term: setup.Terminal,
    options: *const args.Options,
    ev: *Engine,
    input: eval_support.LoadedInput,
    index: usize,
) !bool {
    const source = input.source;
    const result = ev.evaluatePathAt(source.slice(), source.base_path, source.abs_path) catch |err| {
        _ = try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.slice(), err);
        return false;
    };
    const drv_path = ev.derivationDrvPath(result) catch |err| {
        _ = try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.slice(), err);
        return false;
    } orelse {
        std.debug.print("error: input {d} did not evaluate to a derivation\n", .{index + 1});
        return false;
    };

    // Materialize the `.drv` closure, but do not build its outputs.
    ev.ensureDerivationClosure(drv_path) catch |err| {
        _ = try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.slice(), err);
        return false;
    };

    if (options.add_root) |root_path| {
        const name = try build.numberedName(allocator, root_path, index);
        defer allocator.free(name);
        build.linkRoot(init.io, allocator, ev, setup.stateDir(init), name, drv_path, options.indirect);
    }
    if (options.add_drv_link) {
        const name = try build.numberedName(allocator, options.drv_link orelse "derivation", index);
        defer allocator.free(name);
        build.makeLink(init.io, name, drv_path) catch |err| {
            std.debug.print("warning: could not create ./{s}: {s}\n", .{ name, @errorName(err) });
        };
    }

    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("{s}\n", .{drv_path});
    try w.interface.flush();
    return true;
}
