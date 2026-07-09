//! `fix shell` — build one or more derivations and launch an interactive shell
//! (or run a `-- command`) with their `$out/bin` on PATH. The nix shell / the
//! everyday `nix-shell -p` analogue.
//!
//!   fix shell -p ripgrep jq            # packages from <nixpkgs>
//!   fix shell -e '(import <nixpkgs> {}).hello'
//!   fix shell -p ripgrep -- rg --version

const std = @import("std");
const fix = @import("fix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const run = @import("run.zig");

const Evaluator = fix.Evaluator;
const EnvMap = std.process.Environ.Map;

pub const usage =
    \\usage: fix shell [options] (-p <pkgs...> | -e <expr> | --file <path> | --flake <inst>) [-- cmd args...]
    \\
    \\build one or more derivations and start a shell with their $out/bin on PATH.
    \\With `-- cmd args`, run that command in the environment instead of a shell.
    \\
    \\options:
    \\  -p, --packages NAMES   packages (attr paths) from <nixpkgs>, e.g. -p ripgrep jq
    \\  -e, --expr EXPR / --file PATH / --flake INSTALLABLE
    \\  --experimental-features FEATS / --extra-experimental-features FEATS
    \\  --show-trace / --color[=when] / --no-color / --progress[=when] / --no-progress
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

    if (options.packages.items.len == 0 and options.source == null) {
        std.debug.print("error: give packages (-p) or an expression (-e/--file/--flake)\n\n{s}", .{usage});
        return 2;
    }

    const worker_count = try setup.workerCount(options);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);
    ev.enableStoreWrites();

    // Collect the output paths whose bin/ dirs go on PATH.
    var out_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out_paths.deinit(allocator);

    const failed = if (options.packages.items.len > 0)
        try realizePackages(allocator, init, &ev, term, options, &out_paths)
    else
        try realizeSource(allocator, init, &ev, term, options, &out_paths);
    if (failed) |code| return code;

    return launch(allocator, init, out_paths.items, args_iter);
}

/// Build each `-p` package from `<nixpkgs>`, appending its outPath. Returns a
/// non-null exit code on failure (already reported).
fn realizePackages(allocator: std.mem.Allocator, init: std.process.Init, ev: *Evaluator, term: setup.Terminal, options: args.Options, out_paths: *std.ArrayListUnmanaged([]const u8)) !?u8 {
    ev.progressSessionBegin("packages");
    ev.startProgressSampler();
    defer ev.progressSessionEnd();

    const nixpkgs = ev.evaluate("import <nixpkgs> { }") catch |err| {
        ev.stopProgressSampler();
        return try run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, "import <nixpkgs> {}", err);
    };

    var derived: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (derived.items) |d| allocator.free(d);
        derived.deinit(allocator);
    }

    for (options.packages.items) |name| {
        const drv = (ev.attrPathValue(nixpkgs, name) catch |err| {
            ev.stopProgressSampler();
            return try run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, name, err);
        }) orelse {
            ev.stopProgressSampler();
            std.debug.print("error: '{s}' not found in <nixpkgs>\n", .{name});
            return 1;
        };
        const drv_path = (ev.derivationDrvPath(drv) catch |err| {
            ev.stopProgressSampler();
            return try run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, name, err);
        }) orelse {
            ev.stopProgressSampler();
            std.debug.print("error: '{s}' is not a derivation\n", .{name});
            return 1;
        };
        try out_paths.append(allocator, (try ev.derivationOutPath(drv)) orelse drv_path);
        try derived.append(allocator, try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path}));
    }

    ev.stopProgressSampler();
    ev.buildDerivations(derived.items, null) catch |err| {
        return try run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, "packages", err);
    };
    return null;
}

/// Build the `-e`/`--file`/`--flake` derivation, appending its outPath.
fn realizeSource(allocator: std.mem.Allocator, init: std.process.Init, ev: *Evaluator, term: setup.Terminal, options: args.Options, out_paths: *std.ArrayListUnmanaged([]const u8)) !?u8 {
    const source_arg = options.source.?;
    if (source_arg == .flake and !ev.flakes_enabled) {
        std.debug.print("error: {s}\n", .{args.errorMessage(error.FlakesFeatureRequired)});
        return 2;
    }
    const source = run.getSource(ev, source_arg) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer if (source_arg == .flake) ev.allocator.free(source.text);

    ev.progressSessionBegin(run.sourceLabel(source_arg));
    ev.startProgressSampler();
    defer ev.progressSessionEnd();

    const result = ev.evaluate(source.text) catch |err| {
        ev.stopProgressSampler();
        return try run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.text, err);
    };
    const drv_path = (ev.derivationDrvPath(result) catch |err| {
        ev.stopProgressSampler();
        return try run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.text, err);
    }) orelse {
        ev.stopProgressSampler();
        std.debug.print("error: expression did not evaluate to a derivation\n", .{});
        return 1;
    };
    try out_paths.append(allocator, (try ev.derivationOutPath(result)) orelse drv_path);

    ev.stopProgressSampler();
    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    ev.buildDerivations(&.{derived}, null) catch |err| {
        return try run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, ev, source.text, err);
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
