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

pub const usage =
    \\usage: fix run [options] (-e <expr> | --file <path> | --flake <installable>) [-- args...]
    \\
    \\evaluate to a derivation, build it, and run $out/bin/<program> (from
    \\meta.mainProgram, else pname, else name). Arguments after `--` are passed
    \\to the program.
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
    const program = (try ev.derivationProgram(result)) orelse {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        std.debug.print("error: could not determine a program name to run\n", .{});
        return 1;
    };

    ev.stopProgressSampler();
    ev.progressSessionEnd();

    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    ev.buildDerivations(&.{derived}) catch |err| {
        return run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    };

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
