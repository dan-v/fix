//! `fix print-dev-env` — print a derivation's build environment as a bash
//! script WITHOUT building the derivation itself. The `nix print-dev-env`
//! analogue that powers a direnv `use fix` integration.
//!
//!   eval "$(fix print-dev-env ./shell.nix)"     # enter the dev shell inline
//!   fix print-dev-env --flake .#devShell        # a flake devShell
//!
//! Mechanism (matching `nix develop`): evaluate the derivation, recover its
//! build recipe (env, inputDrvs, builder, stdenv, shellHook) via the derivation
//! debug record, then construct and BUILD a get-env derivation — a variant of
//! the target whose builder sources `$stdenv/setup`, runs the shellHook, and
//! dumps the resulting environment to `$out`. Because the env is computed inside
//! the build (wherever the store lives), this is pure and store-location
//! agnostic; we then read `$out` back (local disk, or the daemon for a remote
//! store) and emit it as a flat bash script.

const std = @import("std");
const engine = @import("expr");
const store = @import("store");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");

const Engine = engine.Engine;
const EnvVar = store.derivation.EnvVar;
const DrvOutput = store.derivation.DrvOutput;
const DrvInput = store.derivation.DrvInput;
const Drv = store.derivation.Drv;
const DebugRecord = store.derivation.DebugRecord;

pub const synopsis =
    \\usage: fix print-dev-env [options] (path | -E <expr> | --flake <installable>)
    \\
    \\Print the build environment of a derivation (e.g. a shell.nix / mkShell) as
    \\a bash script, without building the derivation. Source it to enter the shell:
    \\
    \\    eval "$(fix print-dev-env ./shell.nix)"
    \\
    \\or wire it into direnv with a `use fix` function (see contrib/direnv).
;

/// Runs in the get-env build (bash) to reproduce and dump the dev environment.
/// stdout is the build log; the filtered `export -p` dump is written to `$out`.
const get_env_script =
    \\set +eu 2>/dev/null || true
    \\export IN_NIX_SHELL="${IN_NIX_SHELL:-impure}"
    \\if [ -n "${stdenv:-}" ] && [ -e "$stdenv/setup" ]; then
    \\  source "$stdenv/setup" || true
    \\  eval "${shellHook:-}" || true
    \\fi
    \\export -p | while IFS= read -r __fix_line; do
    \\  case "$__fix_line" in
    \\    "declare -x HOME="*|"declare -x PWD="*|"declare -x OLDPWD"*|"declare -x SHLVL="*|"declare -x _="*) continue ;;
    \\    "declare -x PPID="*|"declare -x BASHPID="*|"declare -x IFS="*|"declare -x HOSTNAME="*) continue ;;
    \\    "declare -x SHELLOPTS="*|"declare -x BASHOPTS="*) continue ;;
    \\    "declare -x NIX_BUILD_TOP="*|"declare -x NIX_BUILD_CORES="*|"declare -x NIX_LOG_FD="*|"declare -x NIX_STORE="*) continue ;;
    \\    "declare -x NIX_ENFORCE_PURITY="*|"declare -x TMP="*|"declare -x TMPDIR="*|"declare -x TEMP="*|"declare -x TEMPDIR="*) continue ;;
    \\    "declare -x TERM="*|"declare -x TZ="*|"declare -x UID="*|"declare -x SHELL="*|"declare -x out="*|"declare -x outputs="*) continue ;;
    \\  esac
    \\  printf '%s\n' "$__fix_line"
    \\done > "$out"
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null, .print_dev_env) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .print_dev_env);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.source == null) {
        std.debug.print("error: give a source (path, -E <expr>, or --flake <installable>)\n\n{s}\n", .{synopsis});
        return 2;
    }

    const worker_count = try setup.workerCount(options);
    const memory_backing = setup.applyMemoryBacking(process, options.hugetlb);
    var settings = try setup.loadSettingsAndFlakeConfig(allocator, init, options);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, worker_count, memory_backing));
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options, &settings);
    ev.enableStoreWrites();
    // Retain each forced derivation's full recipe so we can build a get-env
    // variant of it (the normal eval path discards the Drv).
    ev.setDerivationDebug(true);

    // -- evaluate to a derivation --------------------------------------------
    const source_arg = options.source.?;
    if (eval_support.sourceRequiresFlakes(source_arg) and !ev.languagePolicy().flakes_enabled) {
        std.debug.print("error: {s}\n", .{args.errorMessage(error.FlakesFeatureRequired)});
        return 2;
    }
    var source = eval_support.getSource(&ev, init.io, source_arg, options) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer source.deinit(ev.hostAllocator());

    const value = ev.evaluatePathAt(source.slice(), source.base_path, eval_support.sourcePathOf(source_arg, source)) catch |err| {
        return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.slice(), err);
    };
    const paths = (ev.derivationBuildPaths(value) catch |err| {
        return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.slice(), err);
    }) orelse {
        std.debug.print("error: expression did not evaluate to a derivation\n", .{});
        return 1;
    };

    // -- construct the get-env derivation ------------------------------------
    const record = findRecord(ev.derivationDebugRecords(), paths.drv_path) orelse {
        std.debug.print("error: could not recover the build recipe for {s}\n", .{paths.drv_path});
        return 1;
    };
    for (record.env) |e| if (std.mem.eql(u8, e.name, "__json")) {
        std.debug.print("error: print-dev-env does not yet support __structuredAttrs derivations\n", .{});
        return 1;
    };

    // Everything the build phase needs must outlive the evaluator heap release.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original_drv = try a.dupe(u8, paths.drv_path);

    var drv = try buildGetEnvDrv(a, record, get_env_script);
    const computed = drv.computePaths(a, ev.storeResolver()) catch |err| {
        std.debug.print("error: computing get-env derivation: {s}\n", .{@errorName(err)});
        return 1;
    };
    const out_path = try a.dupe(u8, drv.outputs[0].path);

    // The get-env drv references the target's input .drvs; make them valid, then
    // write the get-env .drv itself.
    ev.ensureDerivationClosure(original_drv) catch |err| {
        return eval_support.buildFailure(init.io, term.use_color, ev.lastStoreError(), err);
    };
    ev.instantiateDrv(computed.drv_path, computed.drv_aterm, computed.drv_text_references) catch |err| {
        return eval_support.buildFailure(init.io, term.use_color, ev.lastStoreError(), err);
    };

    // -- build it (realizes buildInputs, runs get-env) -----------------------
    const derived = try std.fmt.allocPrint(a, "{s}!out", .{computed.drv_path});
    std.debug.print("computing dev environment…\n", .{});
    var build_session = ev.beginBuildPhase(&[_][]const u8{derived}, process.eval_release) catch |err| {
        return eval_support.buildFailure(init.io, term.use_color, ev.lastStoreError(), err);
    };
    defer build_session.deinit();
    build_session.buildPaths(&[_][]const u8{derived}, null, eval_support.buildMode(options)) catch |err| {
        return eval_support.buildFailure(init.io, term.use_color, build_session.lastStoreError(), err);
    };

    // -- read $out and emit --------------------------------------------------
    // `FIX_DEV_ENV_DAEMON_READ` forces the daemon (`NarFromPath`) read path even
    // for a local store — exercising the remote-read code against a local daemon.
    const force_daemon = init.environ_map.get("FIX_DEV_ENV_DAEMON_READ") != null;
    const data = (if (force_daemon)
        ev.readFileViaDaemon(allocator, out_path)
    else
        ev.readStorePathFile(init.io, allocator, out_path)) catch |err| {
        std.debug.print("error: reading the dev environment ({s}): {s}\n", .{ out_path, @errorName(err) });
        return 1;
    };
    defer allocator.free(data);

    var out_buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const w = &out.interface;
    try w.print(
        \\# fix print-dev-env — build environment for {s}
        \\# Source this (or use `use fix` in direnv) to enter the dev shell.
        \\
    , .{original_drv});
    try w.writeAll(data);
    try w.flush();
    return 0;
}

fn findRecord(records: []const DebugRecord, drv_path: []const u8) ?*const DebugRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.drv_path, drv_path)) return record;
    }
    return null;
}

/// A get-env variant of the recorded derivation: identical env / inputs / stdenv
/// bash, but a single `out` output whose builder dumps the environment. All
/// storage is arena-owned by the caller.
fn buildGetEnvDrv(a: std.mem.Allocator, record: *const DebugRecord, script: []const u8) !Drv {
    var env: std.ArrayListUnmanaged(EnvVar) = .empty;
    var have_out = false;
    var have_outputs = false;
    for (record.env) |e| {
        // Drop the target's non-`out` output vars (they'd point at unbuilt
        // paths); force a single `out` output.
        if (isOutputName(record.outputs, e.name) and !std.mem.eql(u8, e.name, "out")) continue;
        if (std.mem.eql(u8, e.name, "out")) {
            try env.append(a, .{ .name = try a.dupe(u8, "out"), .value = try a.dupe(u8, "") });
            have_out = true;
        } else if (std.mem.eql(u8, e.name, "outputs")) {
            try env.append(a, .{ .name = try a.dupe(u8, "outputs"), .value = try a.dupe(u8, "out") });
            have_outputs = true;
        } else {
            try env.append(a, .{ .name = try a.dupe(u8, e.name), .value = try a.dupe(u8, e.value) });
        }
    }
    if (!have_out) try env.append(a, .{ .name = try a.dupe(u8, "out"), .value = try a.dupe(u8, "") });
    if (!have_outputs) try env.append(a, .{ .name = try a.dupe(u8, "outputs"), .value = try a.dupe(u8, "out") });

    const outputs = try a.alloc(DrvOutput, 1);
    outputs[0] = .{ .name = try a.dupe(u8, "out"), .path = "", .hash_algo = "", .hash = "" };

    const input_drvs = try a.alloc(DrvInput, record.input_drvs.len);
    for (record.input_drvs, 0..) |in, i| {
        const outs = try a.alloc([]const u8, in.outputs.len);
        for (in.outputs, 0..) |o, j| outs[j] = try a.dupe(u8, o);
        input_drvs[i] = .{ .path = try a.dupe(u8, in.path), .outputs = outs };
    }
    const input_srcs = try a.alloc([]const u8, record.input_srcs.len);
    for (record.input_srcs, 0..) |s, i| input_srcs[i] = try a.dupe(u8, s);

    const argv = try a.alloc([]const u8, 2);
    argv[0] = try a.dupe(u8, "-c");
    argv[1] = try a.dupe(u8, script);

    return .{
        .name = try a.dupe(u8, record.name),
        .outputs = outputs,
        .input_drvs = input_drvs,
        .input_srcs = input_srcs,
        .system = try a.dupe(u8, record.system),
        .builder = try a.dupe(u8, record.builder),
        .args = argv,
        .env = try env.toOwnedSlice(a),
    };
}

fn isOutputName(outputs: []const DrvOutput, name: []const u8) bool {
    for (outputs) |o| if (std.mem.eql(u8, o.name, name)) return true;
    return false;
}
