//! `fix shell` — build one or more derivations and launch an interactive shell
//! (or run a `-- command`) with their `$out/bin` on PATH. The nix shell / the
//! everyday `nix-shell -p` analogue.
//!
//!   fix shell -p ripgrep jq            # packages from <nixpkgs>
//!   fix shell -E '(import <nixpkgs> {}).hello'
//!   fix shell -p ripgrep -- rg --version

const std = @import("std");
const engine = @import("expr");
const store = @import("store");
const progress_ui = @import("../progress.zig");
const build_progress_ui = @import("../build_progress.zig");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");

const Evaluator = engine.Evaluator;
const EnvMap = std.process.Environ.Map;
const BuildSink = store.daemon.BuildSink;

pub const synopsis =
    \\usage: fix shell [options] (-p <pkgs...> | path | -E <expr> | --flake <installable>) [-- cmd args...]
    \\
    \\build one or more derivations and start a shell with their $out/bin on PATH.
    \\With `-- cmd args`, run that command in the environment instead of a shell.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null, .shell) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .shell);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.sources.items.len > 1) {
        std.debug.print("error: this command accepts one expression or file\n\n{s}\n", .{synopsis});
        return 2;
    }

    if (options.packages.items.len == 0 and options.source == null) {
        std.debug.print("error: give packages (-p) or a source (-E/--file/--flake)\n\n{s}\n", .{synopsis});
        return 2;
    }

    const worker_count = try setup.workerCount(options);
    setup.applyMemoryBacking(options.hugetlb);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);
    ev.enableStoreWrites();

    var progress = progress_ui.EvalProgress.init(init.io, ev.basePath() orelse "", term.log_progress, term.color_depth, options.verbose);
    var torn = false;
    defer if (!torn) progress.deinit(false);
    if (term.progressEnabled()) ev.setProgressSink(progress.sink());
    var build_progress = build_progress_ui.BuildProgress.init(allocator, init.io, term.color_depth, term.log_progress, &progress);
    const build_sink = build_progress.sink();

    const label = if (options.packages.items.len > 0) "packages" else eval_support.sourceLabel(options.source.?);
    ev.progressSessionBegin(label);

    // Collect the output paths whose bin/ dirs go on PATH. Owned copies —
    // they must survive the evaluator's build-phase memory release (which
    // frees the intern table the raw attr strings borrow).
    var out_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (out_paths.items) |p| allocator.free(p);
        out_paths.deinit(allocator);
    }

    const failed = if (options.packages.items.len > 0)
        try realizePackages(allocator, init, &ev, process.eval_release, term, options, build_sink, &out_paths)
    else
        try realizeSource(allocator, init, &ev, process.eval_release, term, options, build_sink, &out_paths);

    // Tear progress state down before the shell/command takes over.
    build_progress.deinit();
    ev.progressSessionEnd();
    progress.deinit(failed == null);
    torn = true;
    if (failed) |code| return code;

    return launch(allocator, init, out_paths.items, args_iter);
}

/// Build each `-p` package from `<nixpkgs>`, appending its outPath. Returns a
/// non-null exit code on failure (already reported).
fn realizePackages(allocator: std.mem.Allocator, init: std.process.Init, ev: *Evaluator, release_action: ?engine.ReleaseAction, term: setup.Terminal, options: args.Options, sink: ?BuildSink, out_paths: *std.ArrayListUnmanaged([]const u8)) !?u8 {
    const nixpkgs = ev.evaluate("import <nixpkgs> { }") catch |err| {
        return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, "import <nixpkgs> {}", err);
    };

    var derived: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (derived.items) |d| allocator.free(d);
        derived.deinit(allocator);
    }

    for (options.packages.items) |name| {
        const drv = (ev.attrPathValue(nixpkgs, name) catch |err| {
            return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, name, err);
        }) orelse {
            std.debug.print("error: '{s}' not found in <nixpkgs>\n", .{name});
            return 1;
        };
        const drv_path = (ev.derivationDrvPath(drv) catch |err| {
            return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, name, err);
        }) orelse {
            std.debug.print("error: '{s}' is not a derivation\n", .{name});
            return 1;
        };
        try out_paths.append(allocator, try allocator.dupe(u8, (try ev.derivationOutPath(drv)) orelse drv_path));
        try derived.append(allocator, try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path}));
    }

    // Evaluation is done and its results are copied out: drop the language
    // heap (see build.zig) concurrently with the build phase, which can run
    // for minutes and needs only the daemon connection.
    var build_session = ev.beginBuildPhase(derived.items, release_action) catch |err| {
        return eval_support.buildFailure(ev.lastStoreError(), err);
    };
    defer build_session.deinit();
    build_session.buildPaths(derived.items, sink, eval_support.buildMode(options)) catch |err| {
        return eval_support.buildFailure(build_session.lastStoreError(), err);
    };
    return null;
}

/// Build the `-E`/`--file`/`--flake` derivation, appending its outPath.
fn realizeSource(allocator: std.mem.Allocator, init: std.process.Init, ev: *Evaluator, release_action: ?engine.ReleaseAction, term: setup.Terminal, options: args.Options, sink: ?BuildSink, out_paths: *std.ArrayListUnmanaged([]const u8)) !?u8 {
    const source_arg = options.source.?;
    if (eval_support.sourceRequiresFlakes(source_arg) and !ev.languagePolicy().flakes_enabled) {
        std.debug.print("error: {s}\n", .{args.errorMessage(error.FlakesFeatureRequired)});
        return 2;
    }
    const source = eval_support.getSource(ev, init.io, source_arg, options) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer source.deinit(ev.hostAllocator());

    const result = ev.evaluatePathAt(source.text, source.base_path, eval_support.sourcePathOf(source_arg, source)) catch |err| {
        return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.text, err);
    };
    const drv_path = (ev.derivationDrvPath(result) catch |err| {
        return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.text, err);
    }) orelse {
        std.debug.print("error: expression did not evaluate to a derivation\n", .{});
        return 1;
    };
    try out_paths.append(allocator, try allocator.dupe(u8, (try ev.derivationOutPath(result)) orelse drv_path));

    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    // See realizePackages: results are copied out, so free the language heap
    // concurrently with the build phase.
    var build_session = ev.beginBuildPhase(&.{derived}, release_action) catch |err| {
        return eval_support.buildFailure(ev.lastStoreError(), err);
    };
    defer build_session.deinit();
    build_session.buildPaths(&.{derived}, sink, eval_support.buildMode(options)) catch |err| {
        return eval_support.buildFailure(build_session.lastStoreError(), err);
    };
    return null;
}

/// Launch `$SHELL` (or the `-- command` remaining in `args_iter`) with each
/// output's `bin/` prepended to PATH. Returns the child's exit code.
fn launch(allocator: std.mem.Allocator, init: std.process.Init, out_paths: []const []const u8, args_iter: *std.process.Args.Iterator) !u8 {
    var env = EnvMap.init(allocator);
    defer env.deinit();
    for (init.environ_map.keys(), init.environ_map.values()) |k, v| try env.put(k, v);

    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(allocator);
    for (out_paths) |out| {
        try path_buf.appendSlice(allocator, out);
        try path_buf.appendSlice(allocator, "/bin:");
    }
    try path_buf.appendSlice(allocator, init.environ_map.get("PATH") orelse "");
    try env.put("PATH", path_buf.items);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    if (args_iter.next()) |first| {
        try argv.append(allocator, first);
        while (args_iter.next()) |a| try argv.append(allocator, a);
    } else {
        try argv.append(allocator, init.environ_map.get("SHELL") orelse "/bin/sh");
    }

    var child = std.process.spawn(init.io, .{ .argv = argv.items, .environ_map = &env }) catch |err| {
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
