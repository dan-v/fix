//! Shared evaluator setup for the eval-producing subcommands (`eval`, `repl`,
//! and later `instantiate`/`build`/`run`). Folds the worker-count formula and
//! the `Options → Evaluator` configuration block that each subcommand would
//! otherwise duplicate.

const std = @import("std");
const builtin = @import("builtin");
const fix = @import("fix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const nix_conf = @import("nix_conf.zig");

const Evaluator = fix.Evaluator;

/// Resolve the worker-thread count: an explicit `--workers`, else
/// `min(8, cpu_count)` (1 when single-threaded).
pub fn workerCount(options: args.Options) !u8 {
    return options.workers orelse if (builtin.single_threaded)
        1
    else
        @intCast(@min(@as(u32, 8), @as(u32, @intCast(try std.Thread.getCpuCount()))));
}

pub const Terminal = struct {
    use_color: bool,
    show_progress: bool,
};

/// Apply the shared `Options → Evaluator` configuration (feature toggles,
/// parallelism, environment, base path, NIX_PATH) and resolve the terminal
/// color/progress policy. Enables ANSI on stderr when coloring.
pub fn configure(ev: *Evaluator, init: std.process.Init, options: args.Options) !Terminal {
    // Lazy shells only matter for lazy-XML rendering; elsewhere the wrap is
    // pure thunk-allocation overhead (see `vm.lazy_shells_visible`).
    ev.lazy_shells_visible = options.output == .xml;
    ev.setParallelismToggles(options.disable_spec_thunks, options.disable_fanout);
    ev.setDerivationDebug(options.derivation_debug.enabled());
    ev.max_memory_bytes = options.max_memory;
    // Must precede `nix_conf.load`: it reads `ev.environment()` for `NIX_CONFIG`
    // and the XDG/HOME-relative user config path.
    ev.setEnvironment(init.environ_map);

    // Experimental features and the concurrent-fetch cap both come from
    // `nix.conf` (best-effort: unreadable config just uses defaults), so load it
    // once. The CLI-parsed feature set is the starting point; unless the CLI
    // *replaced* it with `--experimental-features`, the config's
    // `experimental-features` is the base and any `--extra-experimental-features`
    // additions are layered on top (Nix precedence). Config-sourced features
    // that `fix` doesn't recognize are silently skipped, as in Nix.
    var features = options.experimental_features;
    var http_conn: u64 = 25; // Nix default; 0 = unlimited.
    // Start from the loaded config (empty if unreadable), then layer `--option`
    // overrides on top at highest precedence, before reading the settings fix
    // acts on.
    var settings = nix_conf.load(ev.allocator, ev) catch nix_conf.Settings{ .allocator = ev.allocator };
    defer settings.deinit();
    for (options.option_overrides.items) |o| try settings.put(o.name, o.value);
    if (!options.experimental_features_reset) {
        if (settings.get("experimental-features")) |list|
            args.mergeConfigFeatures(&features, list);
    }
    http_conn = settings.getUint("http-connections") orelse 25;

    ev.pipe_operators_enabled = features.contains(.pipe_operators);
    ev.flakes_enabled = features.contains(.flakes);
    // `flakes` implies `fetch-tree` (as in Nix).
    ev.fetch_tree_enabled = features.contains(.fetch_tree) or ev.flakes_enabled;
    ev.setFetchConnections(@intCast(@min(http_conn, @as(u64, std.math.maxInt(u32)))));
    try ev.setBasePathFromCurrentPath(init.io);
    try applyNixPath(ev, init, options);

    const use_color = cli.shouldColor(options.color, init.io, init.environ_map);
    const show_progress = cli.shouldProgress(options.progress, init.io, init.environ_map);
    if (use_color) std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch {};
    return .{ .use_color = use_color, .show_progress = show_progress };
}

/// Build the evaluator's search path from `-I`/`--include` entries followed by
/// `$NIX_PATH`. Command-line entries come first so they take precedence, as in
/// Nix. A no-op when neither is present.
fn applyNixPath(ev: *Evaluator, init: std.process.Init, options: args.Options) !void {
    const env_path = init.environ_map.get("NIX_PATH");
    if (options.include.items.len == 0) {
        if (env_path) |nix_path| try ev.setNixPath(nix_path);
        return;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ev.allocator);
    for (options.include.items) |entry| {
        if (buf.items.len != 0) try buf.append(ev.allocator, ':');
        try buf.appendSlice(ev.allocator, entry);
    }
    if (env_path) |nix_path| {
        if (nix_path.len != 0) {
            try buf.append(ev.allocator, ':');
            try buf.appendSlice(ev.allocator, nix_path);
        }
    }
    try ev.setNixPath(buf.items);
}
