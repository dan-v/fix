//! `fix instantiate` — evaluate an expression/file/flake to a derivation,
//! write its `.drv` closure to the store (as each derivation is forced), and
//! print the top-level `.drv` path. The nix-instantiate analogue.

const std = @import("std");
const fix = @import("fix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const run = @import("run.zig");

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
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
        error.Help => {
            cli.printHelp(init.io, usage);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}", .{ args.errorMessage(err), usage });
            return 2;
        },
    };
    defer options.packages.deinit(allocator);

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

    // Forcing a derivation now writes its `.drv` (and sources) to the store.
    // The daemon connects lazily on the first write.
    ev.enableStoreWrites();

    var progress = cli.EvalProgress.init(init.io, term.show_progress);
    var ok = false;
    defer progress.deinit(ok);
    if (term.show_progress) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin(label(source_arg));
    defer ev.progressSessionEnd();
    ev.startProgressSampler();
    defer ev.stopProgressSampler();

    const result = ev.evaluate(source.text) catch |err| {
        return storeOrEvalFailure(init, term, options, &ev, source.text, err);
    };

    const drv_path = ev.derivationDrvPath(result) catch |err| {
        return storeOrEvalFailure(init, term, options, &ev, source.text, err);
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

/// Render a store-op failure (daemon down / daemon error) specially, else fall
/// back to the normal eval-failure trace.
fn storeOrEvalFailure(init: std.process.Init, term: setup.Terminal, options: args.Options, ev: *Evaluator, source: []const u8, err: anyerror) !u8 {
    switch (err) {
        error.DaemonError => std.debug.print("error: daemon: {s}\n", .{ev.lastStoreError() orelse "unknown"}),
        error.StoreUnavailable => std.debug.print("error: cannot reach the nix-daemon (is it running?)\n", .{}),
        else => try render.evalFailure(init.io, term.use_color, options.show_trace, ev, source, err),
    }
    return 1;
}

fn label(source_arg: args.SourceArg) []const u8 {
    return switch (source_arg) {
        .file => |p| std.fs.path.basename(p),
        .expr => "expression",
        .flake => |inst| inst,
    };
}
