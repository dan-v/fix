//! `fix run` — evaluate to a derivation, build it, and exec a program from its
//! output (`$out/bin/<mainProgram|pname|name>`), forwarding any args after `--`.
//! The nix run analogue.

const std = @import("std");
const fix = @import("fix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const run = @import("run.zig");

const Evaluator = fix.Evaluator;

pub const synopsis =
    \\usage: fix run [options] [path | -e <expr>] [-- args...]
    \\
    \\evaluate to a derivation, build it, and run $out/bin/<program> (from
    \\meta.mainProgram, else pname, else name). Arguments after `--` are passed
    \\to the program. With no source, uses ./default.nix (or, with --flake, the
    \\flake in the current directory).
;

pub fn run_cmd(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .run);
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
    var torn = false;
    defer if (!torn) progress.deinit(false);
    if (term.show_progress) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin(run.sourceLabel(source_arg));
    ev.startProgressSampler();

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
    const program = (try ev.derivationProgram(result)) orelse {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        std.debug.print("error: could not determine a program name to run\n", .{});
        return 1;
    };

    ev.stopProgressSampler();

    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    var build_progress = cli.build_progress.BuildProgress.init(allocator, &progress);
    const build_sink = if (term.show_progress) build_progress.sink() else null;
    ev.buildDerivations(&.{derived}, build_sink, run.buildMode(options)) catch |err| {
        build_progress.deinit();
        ev.progressSessionEnd();
        return run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    };
    // Tear the progress bar down before the program takes over the terminal.
    build_progress.deinit();
    ev.progressSessionEnd();
    progress.deinit(true);
    torn = true;

    // Assemble argv = [$out/bin/<program>] ++ (args after `--`) and exec it.
    const exe = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ out_path, program });
    defer allocator.free(exe);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    while (args_iter.next()) |a| try argv.append(allocator, a);

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
    }) catch |err| {
        std.debug.print("error: running {s}: {s}\n", .{ exe, @errorName(err) });
        return 127;
    };
    const status = child.wait(init.io) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return switch (status) {
        .exited => |code| code,
        else => 1,
    };
}
