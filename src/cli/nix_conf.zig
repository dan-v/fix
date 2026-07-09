//! Minimal `nix.conf` reader — enough to honor the settings `fix` acts on:
//! `http-connections`, `experimental-features`, `access-tokens`, and the
//! daemon build settings forwarded via `set_options` (`max-jobs`, `cores`,
//! `fallback`, `keep-failed`, `max-silent-time`, `substitute`, plus the whole
//! map as `set_options` overrides). Sources, lowest to highest priority, match
//! Nix's env-var-driven resolution (see `mergeUserConfig`):
//!   1. `$NIX_CONF_DIR/nix.conf` (default `/etc/nix/nix.conf`)         (system)
//!   2. `$NIX_USER_CONF_FILES` (colon list) or, by default, `nix/nix.conf`
//!      under `$XDG_CONFIG_HOME` (or `~/.config`) then `$XDG_CONFIG_DIRS`  (user)
//!   3. `$NIX_CONFIG`                             (inline, newline-separated)
//! Later sources override earlier for scalar keys (last-wins), as in Nix.
//!
//! Format handled: `key = value` lines; `#` comments; blank lines ignored.
//! `include`/`!include` directives and list-append (`extra-*`) semantics are
//! deliberately NOT handled yet — add them when a setting first needs them
//! (scalar last-wins covers `http-connections`, `max-jobs`, `cores`, ...).

const std = @import("std");
const Evaluator = @import("fix").eval.Evaluator;

/// A non-empty environment variable, or null (treating empty as unset, like Nix).
fn envGet(env: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const e = env orelse return null;
    const v = e.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// Read `path` (best-effort — missing/unreadable is skipped, as in Nix) and
/// merge its `key = value` lines into `settings`.
fn mergeFile(settings: *Settings, ev: *Evaluator, path: []const u8) !void {
    if (ev.readSourceFile(path)) |data| {
        try settings.mergeLines(data);
    } else |_| {}
}

pub const Settings = struct {
    allocator: std.mem.Allocator,
    /// Owned keys and values. Last-wins across sources.
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Settings) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
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
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    /// Merge `key = value` lines from `content` (a whole file or `$NIX_CONFIG`).
    fn mergeLines(self: *Settings, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            // include / !include are not supported yet; skip rather than choke.
            if (std.mem.startsWith(u8, line, "include ") or std.mem.startsWith(u8, line, "!include ")) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (key.len == 0) continue;
            try self.put(key, value);
        }
    }
};

/// Load and merge the standard `nix.conf` sources. Missing/unreadable files are
/// skipped (best-effort, like Nix). The returned `Settings` owns its storage;
/// the caller must `deinit` it.
pub fn load(allocator: std.mem.Allocator, ev: *Evaluator) !Settings {
    var settings: Settings = .{ .allocator = allocator };
    errdefer settings.deinit();
    const env = ev.environment();

    // 1. System: `$NIX_CONF_DIR/nix.conf` (default `/etc/nix`).
    {
        const dir = envGet(env, "NIX_CONF_DIR") orelse "/etc/nix";
        const path = try std.fs.path.join(allocator, &.{ dir, "nix.conf" });
        defer allocator.free(path);
        try mergeFile(&settings, ev, path);
    }

    // 2. User config files (lowest priority first, so the highest wins last).
    try mergeUserConfig(allocator, &settings, ev, env);

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
fn mergeUserConfig(allocator: std.mem.Allocator, settings: *Settings, ev: *Evaluator, env: ?*const std.process.Environ.Map) !void {
    if (envGet(env, "NIX_USER_CONF_FILES")) |list| {
        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        defer files.deinit(allocator);
        var it = std.mem.splitScalar(u8, list, ':');
        while (it.next()) |f| if (f.len != 0) try files.append(allocator, f);
        var i = files.items.len;
        while (i > 0) {
            i -= 1;
            try mergeFile(settings, ev, files.items[i]);
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
        try mergeFile(settings, ev, path);
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
