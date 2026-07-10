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
const rstore = @import("runtime").store;
const hugetlb = @import("base").hugetlb;

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

/// Resolve process-level memory-backing policy that must be decided BEFORE
/// `Evaluator.init` maps the heap (the flat object store picks its mapping
/// at init): hugetlb mode, precedence `--hugetlb` (`cli_mode`, null for
/// subcommands without the shared parser) > `FIX_HUGETLB` env > `auto`.
/// Deliberately NOT a nix.conf setting: config loads in `configure`, after
/// the heap already exists, so a config-sourced value could only half-apply.
/// Call before `Evaluator.init` in every eval-producing subcommand.
pub fn applyMemoryBacking(cli_mode: ?hugetlb.Mode, init: std.process.Init) void {
    const mode = cli_mode orelse blk: {
        if (init.environ_map.get("FIX_HUGETLB")) |v| {
            if (hugetlb.parseMode(v)) |m| break :blk m;
            std.debug.print("fix: warning: ignoring invalid FIX_HUGETLB value '{s}' (expected auto, on, or off)\n", .{v});
        }
        break :blk .auto;
    };
    hugetlb.setMode(mode);
}

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
    // A fatal config problem (e.g. a missing required `include`) aborts with a
    // printed message, like Nix; a missing top-level nix.conf is not an error.
    var settings = try nix_conf.load(ev.allocator, init.environ_map, init.io);
    defer settings.deinit();
    // `--option NAME VALUE` overrides; `--option extra-NAME VALUE` appends (Nix).
    for (options.option_overrides.items) |o| try settings.setOrAppend(o.name, o.value);
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
    if (settings.getUint("download-attempts")) |n|
        ev.setDownloadAttempts(@intCast(@min(n, @as(u64, std.math.maxInt(u32)))));
    // `access-tokens` from nix.conf (incl. `--option access-tokens ...`):
    // authenticate fetches to private GitHub/GitLab/… hosts.
    if (settings.get("access-tokens")) |tokens| try ev.setAccessTokens(tokens);
    try applyNetrc(ev, init, &settings);
    try applyDaemonSettings(ev, options, &settings);
    try ev.setBasePathFromCurrentPath(init.io);
    try applyNixPath(ev, init, options);

    const use_color = cli.shouldColor(options.color, init.io, init.environ_map);
    const show_progress = cli.shouldProgress(options.progress, init.io, init.environ_map);
    if (use_color) std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch {};
    return .{ .use_color = use_color, .show_progress = show_progress };
}

/// Send per-connection daemon settings via `set_options` when the store
/// connects. Like Nix, this is always sent: the client's resolved config is
/// authoritative for the connection. The fixed fields come from the merged
/// `nix.conf` (system + user + `$NIX_CONFIG` + `--option`/build-setting flags),
/// and the whole merged map is forwarded as the overrides map (so any set key —
/// `timeout`, `substituters`, … — reaches the daemon). `fix` reads the same
/// `/etc/nix/nix.conf` the daemon does, so unchanged values are no-ops; only
/// user/CLI overrides differ. `set_options` is only emitted when the store
/// actually connects (build/instantiate/run/shell), never for plain `eval`.
fn applyDaemonSettings(ev: *Evaluator, options: args.Options, settings: *nix_conf.Settings) !void {
    var overrides: std.ArrayListUnmanaged(rstore.Setting) = .empty;
    defer overrides.deinit(ev.allocator);
    var it = settings.map.iterator();
    while (it.next()) |e|
        try overrides.append(ev.allocator, .{ .name = e.key_ptr.*, .value = e.value_ptr.* });

    // setDaemonBuildSettings dupes the overrides into owned storage, so this
    // borrowed slice need only live across the call.
    try ev.setDaemonBuildSettings(.{
        .keep_failed = boolSetting(settings, "keep-failed", false),
        .keep_going = boolSetting(settings, "keep-going", false),
        .fallback = boolSetting(settings, "fallback", false),
        .verbosity = @min(7, options.verbose),
        .max_build_jobs = jobsSetting(settings, "max-jobs", 1),
        .max_silent_time = settings.getUint("max-silent-time") orelse 0,
        .build_cores = settings.getUint("cores") orelse 0,
        .use_substitutes = boolSetting(settings, "substitute", true),
        .overrides = overrides.items,
    });
}

/// Load the `netrc-file` (default `$NIX_CONF_DIR/netrc`, matching Nix) and hand
/// its credentials to the fetcher for HTTP basic-auth on plain downloads.
/// Best-effort: a missing/unreadable file just means no netrc auth.
fn applyNetrc(ev: *Evaluator, init: std.process.Init, settings: *nix_conf.Settings) !void {
    const path: []u8 = if (settings.get("netrc-file")) |p|
        try ev.allocator.dupe(u8, p)
    else blk: {
        const dir = init.environ_map.get("NIX_CONF_DIR") orelse "/etc/nix";
        break :blk try std.fs.path.join(ev.allocator, &.{ dir, "netrc" });
    };
    defer ev.allocator.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, ev.allocator, .limited(1 << 20)) catch return;
    defer ev.allocator.free(data);
    try ev.setNetrc(data);
}

/// Read a boolean `nix.conf` setting (`true`/`1` = true, any other value =
/// false), falling back to `default` when unset.
fn boolSetting(settings: *nix_conf.Settings, key: []const u8, default: bool) bool {
    const v = settings.get(key) orelse return default;
    const t = std.mem.trim(u8, v, " \t");
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1");
}

/// Read `max-jobs`, resolving `auto` to the CPU count (as in Nix).
fn jobsSetting(settings: *nix_conf.Settings, key: []const u8, default: u64) u64 {
    const v = settings.get(key) orelse return default;
    const t = std.mem.trim(u8, v, " \t");
    if (std.mem.eql(u8, t, "auto")) return @intCast(std.Thread.getCpuCount() catch 1);
    return std.fmt.parseInt(u64, t, 10) catch default;
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
