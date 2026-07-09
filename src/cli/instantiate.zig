//! `fix instantiate` — evaluate an expression/file/flake to a derivation,
//! write its `.drv` closure to the store (as each derivation is forced), and
//! print the top-level `.drv` path. The nix-instantiate analogue.

const std = @import("std");
const fix = @import("fix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const run = @import("run.zig");
const store = @import("runtime").store;

const Evaluator = fix.Evaluator;

pub const usage =
    \\usage: fix instantiate [options] (-e <expr> | --file <path> | --flake <installable>)
    \\
    \\evaluate to a derivation, add its .drv closure to the store, and print the
    \\top-level .drv path.
    \\
    \\options:
    \\  -e, --expr EXPR        evaluate expression text
    \\  --file PATH            evaluate a file
    \\  --flake INSTALLABLE    evaluate a flake output (requires the flakes feature)
    \\  --experimental-features FEATS / --extra-experimental-features FEATS
    \\  --show-trace           show full evaluation traces on error
    \\  --color[=when] / --no-color / --progress[=when] / --no-progress
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

    // Attach the daemon store: forcing a derivation now writes its `.drv`.
    const daemon = store.DaemonStore.connect(allocator, init.io, store.default_socket_path) catch |err| {
        std.debug.print("error: connecting to nix-daemon at {s}: {s}\n", .{ store.default_socket_path, @errorName(err) });
        return 1;
    };
    defer daemon.deinit();
    ev.attachDaemon(daemon);

    var progress = cli.EvalProgress.init(init.io, term.show_progress);
    var ok = false;
    defer progress.deinit(ok);
    if (term.show_progress) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin(label(source_arg));
    defer ev.progressSessionEnd();
    ev.startProgressSampler();
    defer ev.stopProgressSampler();

    const result = ev.evaluate(source.text) catch |err| {
        try render.evalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
        return 1;
    };

    const drv_path = ev.derivationDrvPath(result) catch |err| {
        if (err == error.DaemonError) {
            std.debug.print("error: daemon: {s}\n", .{daemon.last_error orelse "unknown"});
            return 1;
        }
        try render.evalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
        return 1;
    } orelse {
        std.debug.print("error: expression did not evaluate to a derivation\n", .{});
        return 1;
    };

    ok = true;
    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("{s}\n", .{drv_path});
    try w.interface.flush();
    return 0;
}

const render = @import("render.zig");

fn label(source_arg: args.SourceArg) []const u8 {
    return switch (source_arg) {
        .file => |p| std.fs.path.basename(p),
        .expr => "expression",
        .flake => |inst| inst,
    };
}
