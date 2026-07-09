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
    ev.pipe_operators_enabled = options.experimental_features.contains(.pipe_operators);
    ev.flakes_enabled = options.experimental_features.contains(.flakes);
    // `flakes` implies `fetch-tree` (as in Nix).
    ev.fetch_tree_enabled = options.experimental_features.contains(.fetch_tree) or ev.flakes_enabled;
    ev.setParallelismToggles(options.disable_spec_thunks, options.disable_fanout);
    ev.setDerivationDebug(options.derivation_debug.enabled());
    ev.max_memory_bytes = options.max_memory;
    ev.setEnvironment(init.environ_map);
    // Concurrent-fetch cap from nix.conf `http-connections` (Nix default 25;
    // 0 = unlimited). Best-effort: unreadable config just uses the default.
    if (nix_conf.load(ev.allocator, ev)) |loaded| {
        var settings = loaded;
        defer settings.deinit();
        const http_conn = settings.getUint("http-connections") orelse 25;
        ev.setFetchConnections(@intCast(@min(http_conn, @as(u64, std.math.maxInt(u32)))));
    } else |_| {
        ev.setFetchConnections(25);
    }
    try ev.setBasePathFromCurrentPath(init.io);
    if (init.environ_map.get("NIX_PATH")) |nix_path| try ev.setNixPath(nix_path);

    const use_color = cli.shouldColor(options.color, init.io, init.environ_map);
    const show_progress = cli.shouldProgress(options.progress, init.io, init.environ_map);
    if (use_color) std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch {};
    return .{ .use_color = use_color, .show_progress = show_progress };
}
