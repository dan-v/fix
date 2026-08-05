//! Minimal `nix.conf` reader — enough to honor the settings `fix` acts on:
//! `http-connections`, `experimental-features`, `access-tokens`, and the
//! daemon build settings forwarded via `set_options` (`max-jobs`, `cores`,
//! `fallback`, `keep-failed`, `max-silent-time`, and `substitute`, plus
//! user-level overrides). Sources, lowest to highest priority, match
//! Nix's env-var-driven resolution (see `mergeUserConfig`):
//!   1. `$NIX_CONF_DIR/nix.conf` (default `/etc/nix/nix.conf`)         (system)
//!   2. `$NIX_USER_CONF_FILES` (colon list) or, by default, `nix/nix.conf`
//!      under `$XDG_CONFIG_HOME` (or `~/.config`) then `$XDG_CONFIG_DIRS`  (user)
//!   3. `$NIX_CONFIG`                             (inline, newline-separated)
//! Later sources override earlier for scalar keys (last-wins), as in Nix.
//!
//! Format handled: `key = value` lines; `#` comments; blank lines ignored;
//! `include`/`!include <path>` directives; and the `extra-<name>` append form
//! (`extra-foo = x` appends to `foo`, as in Nix — see `setOrAppend`).

const std = @import("std");
const presentation = @import("presentation.zig");
const render = @import("render.zig");

/// Config files are tiny; cap the read so a pathological path can't blow up.
const max_conf_bytes = 1 << 20;

/// A non-empty environment variable, or null (treating empty as unset, like Nix).
fn envGet(env: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const e = env orelse return null;
    const v = e.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// Read `path` directly (NOT via the evaluator's source cache — this is CLI
/// config, not a Nix source file) and merge its lines into `settings`, following
/// any `include` directives. Returns whether the file was read: a missing or
/// unreadable file yields `false` (best-effort, as in Nix); OOM and parse errors
/// propagate.
/// The errors the (mutually-recursive) config-merge functions can produce; an
/// explicit set breaks the inferred-error-set cycle. Missing top-level files are
/// tolerated in `mergeFile` (skip); `ConfigError` is a fatal config problem (a
/// missing required `include`) whose message is already printed — the caller
/// aborts without re-reporting it.
pub const MergeError = error{ OutOfMemory, ConfigError };

fn mergeFile(settings: *Settings, io: std.Io, env: ?*const std.process.Environ.Map, path: []const u8, depth: u8, forward: bool) MergeError!bool {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, settings.allocator, .limited(max_conf_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer settings.allocator.free(data);
    const dir = std.fs.path.dirname(path) orelse ".";
    try mergeConfigText(settings, .{ .io = io, .env = env, .dir = dir, .depth = depth, .parent = path }, data, forward);
    return true;
}

pub const Settings = struct {
    allocator: std.mem.Allocator,
    /// Owned keys and values. Last-wins across sources.
    map: std.StringHashMapUnmanaged([]u8) = .empty,
    /// User/inline/CLI settings to forward through the daemon worker protocol.
    /// System nix.conf values deliberately stay out: the daemon loads its own
    /// system configuration, matching Nix's client behavior.
    daemon: std.StringHashMapUnmanaged([]u8) = .empty,
    pub fn deinit(self: *Settings) void {
        self.deinitMap(&self.map);
        self.deinitMap(&self.daemon);
    }

    fn deinitMap(self: *Settings, map: *std.StringHashMapUnmanaged([]u8)) void {
        var it = map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        map.deinit(self.allocator);
    }

    pub fn get(self: *const Settings, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    /// Parse a setting as an unsigned integer, or null if unset/unparseable.
    pub fn getUint(self: *const Settings, key: []const u8) ?u64 {
        const v = self.map.get(key) orelse return null;
        return std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch null;
    }

    /// Insert or replace `key`, duping both strings. Used both by config-file
    /// parsing and by `--option` overrides (which layer over the config).
    pub fn put(self: *Settings, key: []const u8, value: []const u8) !void {
        try self.putMap(&self.map, key, value);
    }

    fn putMap(self: *Settings, map: *std.StringHashMapUnmanaged([]u8), key: []const u8, value: []const u8) !void {
        const gop = try map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    /// Apply `name = value`, honoring Nix's `extra-<name>` append convention:
    /// `extra-foo = x` appends (space-separated) to `foo` instead of replacing.
    pub fn setOrAppend(self: *Settings, name: []const u8, value: []const u8) !void {
        try self.applySetting(name, value, true);
    }

    fn applySetting(self: *Settings, name: []const u8, value: []const u8, forward: bool) !void {
        if (std.mem.startsWith(u8, name, "extra-")) {
            try self.append(name["extra-".len..], value);
        } else {
            try self.put(name, value);
        }
        if (forward) try self.applyDaemonSetting(name, value);
    }

    /// Preserve the raw base-vs-extra shape for forwarding. An extra setting
    /// with no user-level base remains `extra-foo`, so it appends to the
    /// daemon's system default rather than replacing it with fix's merged view.
    fn applyDaemonSetting(self: *Settings, name: []const u8, value: []const u8) !void {
        if (std.mem.startsWith(u8, name, "extra-")) {
            const base = name["extra-".len..];
            if (self.daemon.contains(base)) {
                try self.appendMap(&self.daemon, base, value);
            } else {
                try self.appendMap(&self.daemon, name, value);
            }
            return;
        }

        const extra = try std.fmt.allocPrint(self.allocator, "extra-{s}", .{name});
        defer self.allocator.free(extra);
        if (self.daemon.fetchRemove(extra)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
        try self.putMap(&self.daemon, name, value);
    }

    /// Space-append `value` to `key`'s current value (set it if unset). Matches
    /// Nix's append semantics for the list-like settings (experimental-features,
    /// access-tokens, substituters, …).
    fn append(self: *Settings, key: []const u8, value: []const u8) !void {
        try self.appendMap(&self.map, key, value);
    }

    fn appendMap(self: *Settings, map: *std.StringHashMapUnmanaged([]u8), key: []const u8, value: []const u8) !void {
        const existing = map.get(key) orelse return self.putMap(map, key, value);
        if (existing.len == 0) return self.putMap(map, key, value);
        const joined = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ existing, value });
        defer self.allocator.free(joined);
        try self.putMap(map, key, joined);
    }

    /// Apply one `key = value` config line (blank/keyless lines are ignored).
    fn applyLine(self: *Settings, line: []const u8, forward: bool) !void {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = line[eq + 1 ..];
        const comment = std.mem.indexOfScalar(u8, raw_value, '#') orelse raw_value.len;
        const value = std.mem.trim(u8, raw_value[0..comment], " \t");
        if (key.len == 0) return;
        try self.applySetting(key, value, forward);
    }

    /// Merge `key = value` lines from inline content (`$NIX_CONFIG`). `include`
    /// directives are ignored here — a bare string has no base directory.
    fn mergeLines(self: *Settings, content: []const u8) !void {
        try mergeConfigText(self, null, content, true);
    }
};

const max_include_depth = 100; // guards against include cycles

const IncludeCtx = struct { io: std.Io, env: ?*const std.process.Environ.Map, dir: []const u8, depth: u8, parent: []const u8 };
const IncludeSpec = struct { path: []const u8, required: bool };

/// Parse config `content` line by line into `settings`. With an `IncludeCtx`,
/// `include`/`!include` directives pull in other files (relative paths resolved
/// against `ctx.dir`); without one (inline `$NIX_CONFIG`) they are skipped.
fn mergeConfigText(settings: *Settings, ctx: ?IncludeCtx, content: []const u8, forward: bool) MergeError!void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (includeSpec(line)) |spec| {
            if (ctx) |c| try includeFile(settings, c, spec, forward);
            continue;
        }
        try settings.applyLine(line, forward);
    }
}

/// Parse an `include <path>` (required) / `!include <path>` (optional) line.
fn includeSpec(line: []const u8) ?IncludeSpec {
    if (std.mem.startsWith(u8, line, "include "))
        return .{ .path = std.mem.trim(u8, line["include ".len..], " \t"), .required = true };
    if (std.mem.startsWith(u8, line, "!include "))
        return .{ .path = std.mem.trim(u8, line["!include ".len..], " \t"), .required = false };
    return null;
}

/// Resolve and merge an included config file (relative to `ctx.dir`). A missing
/// required `include` is a fatal `ConfigError` (as in Nix); a missing `!include`
/// is silently skipped.
fn includeFile(settings: *Settings, ctx: IncludeCtx, spec: IncludeSpec, forward: bool) MergeError!void {
    if (spec.path.len == 0 or ctx.depth >= max_include_depth) return;
    const alloc = settings.allocator;
    const path = if (std.fs.path.isAbsolute(spec.path))
        try alloc.dupe(u8, spec.path)
    else
        try std.fs.path.join(alloc, &.{ ctx.dir, spec.path });
    defer alloc.free(path);
    const found = try mergeFile(settings, ctx.io, ctx.env, path, ctx.depth + 1, forward);
    if (!found and spec.required) {
        // Match Nix: abort with the file that couldn't be included and its
        // source. The message is printed here, so the caller must not re-report.
        const use_color = if (ctx.env) |env| presentation.colorDepth(.auto, ctx.io, env).enabled() else false;
        render.messageError(ctx.io, use_color, "file '{s}' included from '{s}' not found", .{ path, ctx.parent });
        return error.ConfigError;
    }
}

/// Load and merge the standard `nix.conf` sources. Missing/unreadable files are
/// skipped (best-effort, like Nix). The returned `Settings` owns its storage;
/// the caller must `deinit` it.
pub fn load(allocator: std.mem.Allocator, env: ?*const std.process.Environ.Map, io: std.Io) !Settings {
    var settings: Settings = .{ .allocator = allocator };
    errdefer settings.deinit();

    // 1. System: `$NIX_CONF_DIR/nix.conf` (default `/etc/nix`).
    {
        const dir = envGet(env, "NIX_CONF_DIR") orelse "/etc/nix";
        const path = try std.fs.path.join(allocator, &.{ dir, "nix.conf" });
        defer allocator.free(path);
        _ = try mergeFile(&settings, io, env, path, 0, false);
    }

    // 2. User config files (lowest priority first, so the highest wins last).
    try mergeUserConfig(allocator, &settings, io, env);

    // 3. Inline `$NIX_CONFIG`, highest priority.
    if (envGet(env, "NIX_CONFIG")) |inline_conf| try settings.mergeLines(inline_conf);

    return settings;
}

/// Merge the user `nix.conf` files, resolved as Nix does:
///   - `$NIX_USER_CONF_FILES` (colon-separated, first entry highest priority)
///     if set, replacing the default lookup entirely; else
///   - `<dir>/nix/nix.conf` for each of `$XDG_CONFIG_HOME` (or `~/.config`)
///     then the `$XDG_CONFIG_DIRS` list (default `/etc/xdg`).
/// Nix applies its file list in reverse, so we merge lowest→highest priority
/// (later `put`s win) to match.
fn mergeUserConfig(allocator: std.mem.Allocator, settings: *Settings, io: std.Io, env: ?*const std.process.Environ.Map) !void {
    if (envGet(env, "NIX_USER_CONF_FILES")) |list| {
        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        defer files.deinit(allocator);
        var it = std.mem.splitScalar(u8, list, ':');
        while (it.next()) |f| if (f.len != 0) try files.append(allocator, f);
        var i = files.items.len;
        while (i > 0) {
            i -= 1;
            _ = try mergeFile(settings, io, env, files.items[i], 0, true);
        }
        return;
    }

    // Config dirs, highest priority first: [config-home, ...XDG_CONFIG_DIRS].
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer dirs.deinit(allocator);
    var home_config: ?[]u8 = null;
    defer if (home_config) |h| allocator.free(h);
    if (envGet(env, "XDG_CONFIG_HOME")) |xdg| {
        try dirs.append(allocator, xdg);
    } else if (envGet(env, "HOME")) |home| {
        home_config = try std.fs.path.join(allocator, &.{ home, ".config" });
        try dirs.append(allocator, home_config.?);
    }
    var it = std.mem.splitScalar(u8, envGet(env, "XDG_CONFIG_DIRS") orelse "/etc/xdg", ':');
    while (it.next()) |d| if (d.len != 0) try dirs.append(allocator, d);

    // Merge lowest priority first (reverse of the priority-ordered list).
    var i = dirs.items.len;
    while (i > 0) {
        i -= 1;
        const path = try std.fs.path.join(allocator, &.{ dirs.items[i], "nix", "nix.conf" });
        defer allocator.free(path);
        _ = try mergeFile(settings, io, env, path, 0, true);
    }
}

test "nix.conf scalar parse + last-wins" {
    const testing = std.testing;
    var s: Settings = .{ .allocator = testing.allocator };
    defer s.deinit();
    try s.mergeLines(
        \\# a comment
        \\http-connections = 25
        \\experimental-features = nix-command flakes
        \\
        \\  cores=4
    );
    try s.mergeLines("http-connections = 0\n"); // later source wins
    try testing.expectEqual(@as(?u64, 0), s.getUint("http-connections"));
    try testing.expectEqual(@as(?u64, 4), s.getUint("cores"));
    try testing.expectEqualStrings("nix-command flakes", s.get("experimental-features").?);
    try testing.expectEqual(@as(?[]const u8, null), s.get("missing"));
}

test "nix.conf strips inline comments from values" {
    const testing = std.testing;
    var s: Settings = .{ .allocator = testing.allocator };
    defer s.deinit();
    try s.mergeLines(
        \\store = daemon # use the local daemon
        \\max-jobs = 7 # bounded builders
    );
    try testing.expectEqualStrings("daemon", s.get("store").?);
    try testing.expectEqual(@as(?u64, 7), s.getUint("max-jobs"));
}

test "nix.conf extra-<name> appends (as in Nix)" {
    const testing = std.testing;
    var s: Settings = .{ .allocator = testing.allocator };
    defer s.deinit();
    try s.mergeLines(
        \\access-tokens = github.com=a
        \\extra-access-tokens = gitlab.com=b
        \\extra-access-tokens = sr.ht=c
    );
    // `extra-` appends space-separated; a bare `extra-` on an unset key sets it.
    try testing.expectEqualStrings("github.com=a gitlab.com=b sr.ht=c", s.get("access-tokens").?);
    try s.setOrAppend("extra-experimental-features", "flakes");
    try testing.expectEqualStrings("flakes", s.get("experimental-features").?);
    try s.setOrAppend("access-tokens", "only=x"); // non-extra replaces
    try testing.expectEqualStrings("only=x", s.get("access-tokens").?);
}

test "nix.conf preserves base vs extra shape for daemon forwarding" {
    const testing = std.testing;
    var s: Settings = .{ .allocator = testing.allocator };
    defer s.deinit();
    try s.mergeLines(
        \\sandbox = true
        \\extra-sandbox-paths = /run/binfmt
    );
    try testing.expectEqualStrings("true", s.daemon.get("sandbox").?);
    // `sandbox-paths` only ever came from `extra-sandbox-paths`, so it appends
    // onto the daemon's own default rather than replacing it.
    try testing.expect(!s.daemon.contains("sandbox-paths"));
    try testing.expectEqualStrings("/run/binfmt", s.daemon.get("extra-sandbox-paths").?);
    try testing.expectEqualStrings("/run/binfmt", s.get("sandbox-paths").?);
    // A later direct assignment replaces the extra-only forwarding shape.
    try s.setOrAppend("sandbox-paths", "/only");
    try testing.expect(!s.daemon.contains("extra-sandbox-paths"));
    try testing.expectEqualStrings("/only", s.daemon.get("sandbox-paths").?);
}

test "nix.conf forwards user settings but not system settings" {
    const testing = std.testing;
    var s: Settings = .{ .allocator = testing.allocator };
    defer s.deinit();

    try mergeConfigText(&s, null,
        \\sandbox = true
        \\substituters = https://system.example
    , false);
    try mergeConfigText(&s, null,
        \\extra-substituters = https://user.example
        \\max-jobs = 4
    , true);

    try testing.expectEqualStrings("https://system.example https://user.example", s.get("substituters").?);
    try testing.expect(!s.daemon.contains("sandbox"));
    try testing.expect(!s.daemon.contains("substituters"));
    try testing.expectEqualStrings("https://user.example", s.daemon.get("extra-substituters").?);
    try testing.expectEqualStrings("4", s.daemon.get("max-jobs").?);

    // A later direct user assignment replaces its earlier extra-only shape.
    try s.setOrAppend("substituters", "https://override.example");
    try testing.expect(!s.daemon.contains("extra-substituters"));
    try testing.expectEqualStrings("https://override.example", s.daemon.get("substituters").?);
}
