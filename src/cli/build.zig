//! `fix build` — evaluate to a derivation, instantiate its closure, realize it
//! (build or substitute the outputs) via the daemon, link `./result`, and print
//! the output path. The nix build analogue.

const std = @import("std");
const fix = @import("fix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const run = @import("run.zig");

const Evaluator = fix.Evaluator;

pub const synopsis =
    \\usage: fix build [options] [path | -e <expr>]
    \\
    \\evaluate to a derivation, build (or substitute) its outputs, link ./result,
    \\and print the output path. With no source, uses ./default.nix (or, with
    \\--flake, the flake in the current directory).
;

pub fn run_cmd(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
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

    const source_arg = options.source orelse options.defaultSource();

    const worker_count = try setup.workerCount(options);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);

    if (source_arg == .flake and !ev.flakes_enabled) {
        std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(error.FlakesFeatureRequired), synopsis });
        return 2;
    }

    const source = run.getSource(&ev, source_arg, options) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer if (source.owned) ev.allocator.free(source.text);

    ev.enableStoreWrites();

    var progress = cli.EvalProgress.init(init.io, term.show_progress);
    var ok = false;
    defer progress.deinit(ok);
    if (term.show_progress) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin(run.sourceLabel(source_arg));
    ev.startProgressSampler();

    // Evaluate + instantiate the .drv closure.
    const result = ev.evaluate(source.text) catch |err| {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        return run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    };
    const drv_path = (ev.derivationDrvPath(result) catch |err| {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        return run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    }) orelse {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        std.debug.print("error: expression did not evaluate to a derivation\n", .{});
        return 1;
    };
    const out_path = (try ev.derivationOutPath(result)) orelse drv_path;

    // Stop the eval sampler; keep the progress session open so build activity
    // nodes render under the same tree.
    ev.stopProgressSampler();

    // Legacy derived-path wire form `<drvpath>!<outputs>` (`*` = all outputs).
    // This daemon (Lix) parses that, not the newer `<drvpath>^*` form.
    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);

    var build_progress = cli.build_progress.BuildProgress.init(allocator, &progress);
    defer build_progress.deinit();
    const build_sink = if (term.show_progress) build_progress.sink() else null;
    ev.buildDerivations(&.{derived}, build_sink) catch |err| {
        ev.progressSessionEnd();
        return run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    };
    build_progress.deinit();
    ev.progressSessionEnd();
    ok = true;

    if (!options.no_link) linkResult(init.io, out_path) catch |err| {
        std.debug.print("warning: could not create ./result: {s}\n", .{@errorName(err)});
    };

    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("{s}\n", .{out_path});
    try w.interface.flush();
    return 0;
}

fn linkResult(io: std.Io, out_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, "result") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.symLink(io, out_path, "result", .{});
}
