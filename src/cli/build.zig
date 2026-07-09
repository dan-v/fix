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
    ev.buildDerivations(&.{derived}, build_sink, run.buildMode(options)) catch |err| {
        ev.progressSessionEnd();
        return run.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    };
    build_progress.deinit();
    ev.progressSessionEnd();
    ok = true;

    // The output link, which — as in nix-build — is registered as an indirect
    // GC root. `--add-root PATH` relocates it (and, per nix-store/-instantiate,
    // makes a direct root unless `--indirect`); `--out-link`/`-o` name it;
    // `--no-out-link` suppresses it (unless `--add-root` asks for one).
    const link_name = options.add_root orelse (if (options.no_link) null else (options.out_link orelse "result"));
    if (link_name) |name| {
        const indirect = options.add_root == null or options.indirect;
        linkRoot(init.io, allocator, &ev, name, out_path, indirect);
    }
    if (options.add_drv_link) {
        const name = options.drv_link orelse "derivation";
        makeLink(init.io, name, drv_path) catch |err| {
            std.debug.print("warning: could not create ./{s}: {s}\n", .{ name, @errorName(err) });
        };
    }

    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("{s}\n", .{out_path});
    try w.interface.flush();
    return 0;
}

/// Replace `./<name>` with a symlink to `target` (the result/derivation link).
pub fn makeLink(io: std.Io, name: []const u8, target: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.symLink(io, target, name, .{});
}

/// Create the symlink `name` -> `target` and register `name` as a GC root, as
/// nix does. `indirect` picks an indirect root (the daemon records
/// `<gcroots>/auto/<hash>` -> `name`, so `name` may live anywhere) versus a
/// direct root (the symlink itself, effective only under the gcroots dir).
/// Warns (does not fail) on any step. Shared by `build` and `instantiate`.
pub fn linkRoot(io: std.Io, allocator: std.mem.Allocator, ev: *Evaluator, name: []const u8, target: []const u8, indirect: bool) void {
    makeLink(io, name, target) catch |err| {
        std.debug.print("warning: could not create {s}: {s}\n", .{ name, @errorName(err) });
        return;
    };
    const abs = absPath(io, allocator, name) catch |err| {
        std.debug.print("warning: could not resolve {s}: {s}\n", .{ name, @errorName(err) });
        return;
    };
    defer allocator.free(abs);
    if (!indirect) {
        // A direct root is just the symlink; the GC only honors it when it lives
        // under the gcroots dir. Warn otherwise, as nix does.
        if (!std.mem.startsWith(u8, abs, "/nix/var/nix/gcroots/"))
            std.debug.print("warning: {s} is not in the gcroots directory, so it will not be an effective GC root (pass --indirect)\n", .{abs});
        return;
    }
    ev.addIndirectRoot(abs) catch |err| {
        std.debug.print("warning: could not register GC root {s}: {s}\n", .{ abs, @errorName(err) });
    };
}

/// Absolute, normalized (cwd-joined) form of `name` — the link path the daemon
/// roots. `resolve` collapses `.`/`..` so the root path is canonical.
fn absPath(io: std.Io, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(name)) return std.fs.path.resolve(allocator, &.{name});
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, name });
}
