//! `fix shell` — evaluate to a derivation, build it, and launch an interactive
//! shell (or run a `-- command`) with the derivation's `$out/bin` prepended to
//! PATH. The nix shell analogue.

const std = @import("std");
const fix = @import("fix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const run = @import("run.zig");

const Evaluator = fix.Evaluator;
const EnvMap = std.process.Environ.Map;

pub const usage =
    \\usage: fix shell [options] (-e <expr> | --file <path> | --flake <installable>) [-- cmd args...]
    \\
    \\evaluate to a derivation, build it, and start a shell with its $out/bin on
    \\PATH. With `-- cmd args`, run that command in the environment instead of an
    \\interactive shell.
    \\
    \\options:
    \\  -e, --expr EXPR / --file PATH / --flake INSTALLABLE
    \\  --experimental-features FEATS / --extra-experimental-features FEATS
    \\  --show-trace / --color[=when] / --no-color / --progress[=when] / --no-progress
    \\  -h, --help             show this help
    \\
;

pub fn run_cmd(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const options = args.parse(args_iter, null) catch |err| switch (err) {
        error.Help => {
            cli.printHelp(init.io, usage);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}", .{ args.errorMessage(err), usage });
            return 2;
        },
    };

    const source_arg = options.source orelse {
        std.debug.print("error: no expression, file, or flake given\n\n{s}", .{usage});
        return 2;
    };

    const worker_count = try setup.workerCount(options);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);

    if (source_arg == .flake and !ev.flakes_enabled) {
        std.debug.print("error: {s}\n\n{s}", .{ args.errorMessage(error.FlakesFeatureRequired), usage });
        return 2;
    }

    const source = run.getSource(&ev, source_arg) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer if (source_arg == .flake) ev.allocator.free(source.text);

    ev.enableStoreWrites();
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

    ev.stopProgressSampler();
    ev.progressSessionEnd();

    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    ev.buildDerivations(&.{derived}) catch |err| {
        return run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    };

    // Build the child environment: a copy of ours with `$out/bin` on PATH.
    var env = EnvMap.init(allocator);
    defer env.deinit();
    for (init.environ_map.keys(), init.environ_map.values()) |k, v| try env.put(k, v);
    const old_path = init.environ_map.get("PATH") orelse "";
    const new_path = try std.fmt.allocPrint(allocator, "{s}/bin:{s}", .{ out_path, old_path });
    defer allocator.free(new_path);
    try env.put("PATH", new_path);

    // argv = the `-- command` if given, else the user's interactive shell.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    if (args_iter.next()) |first| {
        try argv.append(allocator, first);
        while (args_iter.next()) |a| try argv.append(allocator, a);
    } else {
        try argv.append(allocator, init.environ_map.get("SHELL") orelse "/bin/sh");
    }

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &env,
    }) catch |err| {
        std.debug.print("error: launching {s}: {s}\n", .{ argv.items[0], @errorName(err) });
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
