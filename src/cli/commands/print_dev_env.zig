//! `fix print-dev-env` — print a derivation's build environment as a bash
//! script WITHOUT building the derivation itself. The `nix print-dev-env`
//! analogue that powers a direnv `use fix` integration.
//!
//!   eval "$(fix print-dev-env ./shell.nix)"     # enter the dev shell inline
//!   fix print-dev-env --flake .#devShell        # a flake devShell
//!
//! Mechanism: evaluate the derivation, recover its build environment (env vars,
//! stdenv, shellHook, builder) via the derivation debug record, realize only
//! its INPUT derivations (buildInputs / stdenv — not the derivation itself),
//! then run the derivation's own bash to `source $stdenv/setup` and dump the
//! resulting environment as a flat, side-effect-free bash script.

const std = @import("std");
const engine = @import("expr");
const store = @import("store");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");

const Evaluator = engine.Evaluator;
const EnvMap = std.process.Environ.Map;
const EnvVar = store.derivation.EnvVar;
const DebugRecord = store.derivation.DebugRecord;

pub const synopsis =
    \\usage: fix print-dev-env [options] (path | -E <expr> | --flake <installable>)
    \\
    \\Print the build environment of a derivation (e.g. a shell.nix / mkShell) as
    \\a bash script, without building the derivation. Source it to enter the shell:
    \\
    \\    eval "$(fix print-dev-env ./shell.nix)"
    \\
    \\or wire it into direnv with a `use fix` function (see docs/direnv).
;

/// The build environment we keep after the evaluator heap is released.
const DevEnv = struct {
    builder: []u8,
    env: []EnvVar,
    input_paths: [][]u8,

    fn deinit(self: *DevEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.builder);
        for (self.env) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        allocator.free(self.env);
        for (self.input_paths) |p| allocator.free(p);
        allocator.free(self.input_paths);
    }
};

/// Sourced by bash to reproduce the dev environment. `exec 1>&2` sends stdenv's
/// setup + shellHook chatter to stderr; only the filtered `declare -px` dump
/// reaches `$__FIX_ENV_OUT`, which `fix` reads back and prints on stdout.
const get_env_script =
    \\exec 1>&2
    \\set +eu 2>/dev/null || true
    \\export IN_NIX_SHELL="${IN_NIX_SHELL:-impure}"
    \\export NIX_BUILD_TOP="$(mktemp -d "${TMPDIR:-/tmp}/fix-nix-shell.XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}")"
    \\export TMP="$NIX_BUILD_TOP" TEMP="$NIX_BUILD_TOP" TMPDIR="$NIX_BUILD_TOP" TEMPDIR="$NIX_BUILD_TOP"
    \\if [ -n "${stdenv:-}" ] && [ -e "$stdenv/setup" ]; then
    \\  source "$stdenv/setup" || true
    \\  eval "${shellHook:-}" || true
    \\fi
    \\trap - EXIT
    \\__fix_out="$__FIX_ENV_OUT"
    \\export -p | while IFS= read -r __fix_line; do
    \\  case "$__fix_line" in
    \\    "declare -x HOME="*|"declare -x PWD="*|"declare -x OLDPWD"*|"declare -x SHLVL="*|"declare -x _="*) continue ;;
    \\    "declare -x PPID="*|"declare -x BASHPID="*|"declare -x IFS="*|"declare -x HOSTNAME="*) continue ;;
    \\    "declare -x SHELLOPTS="*|"declare -x BASHOPTS="*) continue ;;
    \\    "declare -x NIX_BUILD_TOP="*|"declare -x TMP="*|"declare -x TMPDIR="*|"declare -x TEMP="*|"declare -x TEMPDIR="*) continue ;;
    \\    "declare -x TERM="*|"declare -x TZ="*|"declare -x UID="*|"declare -x SHELL="*|"declare -x __FIX_ENV_OUT="*) continue ;;
    \\  esac
    \\  printf '%s\n' "$__fix_line"
    \\done > "$__fix_out"
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
    setup.applyMemoryBacking(options.hugetlb);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);
    ev.enableStoreWrites();
    // Retain each forced derivation's full recipe so we can recover the build
    // environment in-memory (the normal eval path discards it).
    ev.setDerivationDebug(true);

    // -- evaluate to a derivation --------------------------------------------
    const source_arg = options.source.?;
    if (eval_support.sourceRequiresFlakes(source_arg) and !ev.languagePolicy().flakes_enabled) {
        std.debug.print("error: {s}\n", .{args.errorMessage(error.FlakesFeatureRequired)});
        return 2;
    }
    const source = eval_support.getSource(&ev, init.io, source_arg, options) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer source.deinit(ev.hostAllocator());

    const value = ev.evaluatePathAt(source.text, source.base_path, eval_support.sourcePathOf(source_arg, source)) catch |err| {
        return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    };
    const paths = (ev.derivationBuildPaths(value) catch |err| {
        return try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.text, err);
    }) orelse {
        std.debug.print("error: expression did not evaluate to a derivation\n", .{});
        return 1;
    };
    const drv_path = try allocator.dupe(u8, paths.drv_path);
    defer allocator.free(drv_path);

    // -- recover the build environment ---------------------------------------
    const record = findRecord(ev.derivationDebugRecords(), drv_path) orelse {
        std.debug.print("error: could not recover the build environment for {s}\n", .{drv_path});
        return 1;
    };
    for (record.env) |e| if (std.mem.eql(u8, e.name, "__json")) {
        std.debug.print("error: print-dev-env does not yet support __structuredAttrs derivations\n", .{});
        return 1;
    };
    var dev = try copyDevEnv(allocator, record);
    defer dev.deinit(allocator);

    // -- realize the INPUT derivations (not the derivation itself) -----------
    if (dev.input_paths.len > 0) {
        std.debug.print("realizing dev-shell inputs (buildInputs, stdenv)…\n", .{});
        var build_session = ev.beginBuildPhase(dev.input_paths, process.eval_release) catch |err| {
            return eval_support.buildFailure(init.io, term.use_color, ev.lastStoreError(), err);
        };
        defer build_session.deinit();
        build_session.buildPaths(dev.input_paths, null, eval_support.buildMode(options)) catch |err| {
            return eval_support.buildFailure(init.io, term.use_color, build_session.lastStoreError(), err);
        };
    }

    return emit(allocator, init, &dev, drv_path);
}

fn findRecord(records: []const DebugRecord, drv_path: []const u8) ?*const DebugRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.drv_path, drv_path)) return record;
    }
    return null;
}

fn copyDevEnv(allocator: std.mem.Allocator, record: *const DebugRecord) !DevEnv {
    const builder = try allocator.dupe(u8, record.builder);
    errdefer allocator.free(builder);

    const env = try allocator.alloc(EnvVar, record.env.len);
    var filled: usize = 0;
    errdefer {
        for (env[0..filled]) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        allocator.free(env);
    }
    for (record.env, 0..) |e, i| {
        env[i] = .{ .name = try allocator.dupe(u8, e.name), .value = try allocator.dupe(u8, e.value) };
        filled = i + 1;
    }

    var inputs: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (inputs.items) |p| allocator.free(p);
        inputs.deinit(allocator);
    }
    for (record.input_drvs) |input| {
        var outs: std.Io.Writer.Allocating = .init(allocator);
        defer outs.deinit();
        if (input.outputs.len == 0) {
            try outs.writer.writeAll("*");
        } else for (input.outputs, 0..) |o, i| {
            if (i > 0) try outs.writer.writeByte(',');
            try outs.writer.writeAll(o);
        }
        try inputs.append(allocator, try std.fmt.allocPrint(allocator, "{s}!{s}", .{ input.path, outs.written() }));
    }

    return .{ .builder = builder, .env = env, .input_paths = try inputs.toOwnedSlice(allocator) };
}

fn emit(allocator: std.mem.Allocator, init: std.process.Init, dev: *const DevEnv, drv_path: []const u8) !u8 {
    const tmp_base = init.environ_map.get("TMPDIR") orelse "/tmp";
    const env_out = try std.fmt.allocPrint(allocator, "{s}/fix-dev-env-{s}", .{ tmp_base, std.fs.path.basename(drv_path) });
    defer allocator.free(env_out);
    defer std.Io.Dir.cwd().deleteFile(init.io, env_out) catch {};

    var env = EnvMap.init(allocator);
    defer env.deinit();
    for (dev.env) |e| try env.put(e.name, e.value);
    // Bootstrap PATH/HOME so setup's early tools resolve; setup then rebuilds
    // PATH from the realized inputs. These names are filtered from the dump.
    if (init.environ_map.get("PATH")) |p| try env.put("PATH", p);
    try env.put("HOME", init.environ_map.get("HOME") orelse tmp_base);
    try env.put("TMPDIR", tmp_base);
    try env.put("IN_NIX_SHELL", "impure");
    try env.put("__FIX_ENV_OUT", env_out);

    var child = std.process.spawn(init.io, .{
        .argv = &[_][]const u8{ dev.builder, "-c", get_env_script },
        .environ_map = &env,
    }) catch |err| {
        std.debug.print("error: launching {s}: {s}\n", .{ dev.builder, @errorName(err) });
        return 127;
    };
    _ = child.wait(init.io) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };

    const data = std.Io.Dir.cwd().readFileAlloc(init.io, env_out, allocator, .limited(64 << 20)) catch |err| {
        std.debug.print("error: capturing the dev environment: {s}\n", .{@errorName(err)});
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
    , .{drv_path});
    try w.writeAll(data);
    try w.flush();
    return 0;
}
