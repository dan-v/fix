//! Minimal `nix.conf` reader — enough to honor the settings `fix` acts on:
//! `http-connections`, `experimental-features`, `access-tokens`, and the
//! daemon build settings forwarded via `set_options` (`max-jobs`, `cores`,
//! `fallback`, `keep-failed`, `max-silent-time`, `substitute`, plus the whole
//! map as `set_options` overrides). Precedence, lowest to highest:
//!   1. `/etc/nix/nix.conf`                                   (system)
//!   2. `$XDG_CONFIG_HOME/nix/nix.conf` (or `~/.config/nix/nix.conf`)  (user)
//!   3. `$NIX_CONFIG`                             (inline, newline-separated)
//! Later sources override earlier for scalar keys (last-wins), as in Nix.
//!
//! Format handled: `key = value` lines; `#` comments; blank lines ignored.
//! `include`/`!include` directives and list-append (`extra-*`) semantics are
//! deliberately NOT handled yet — add them when a setting first needs them
//! (scalar last-wins covers `http-connections`, `max-jobs`, `cores`, ...).

const std = @import("std");
const Evaluator = @import("fix").eval.Evaluator;

/// Build `$<xdg_var>/<tail...>`, or `$HOME/<home_prefix...>/<tail...>` when the
/// XDG var is unset. Null if neither is available.
fn dirFile(allocator: std.mem.Allocator, env: ?*const std.process.Environ.Map, xdg_var: []const u8, home_prefix: []const []const u8, tail: []const []const u8) !?[]u8 {
    const e = env orelse return null;
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(allocator);
    if (e.get(xdg_var)) |xdg| {
        if (xdg.len != 0) try parts.append(allocator, xdg);
    }
    if (parts.items.len == 0) {
        const home = e.get("HOME") orelse return null;
        if (home.len == 0) return null;
        try parts.append(allocator, home);
        try parts.appendSlice(allocator, home_prefix);
    }
    try parts.appendSlice(allocator, tail);
    return try std.fs.path.join(allocator, parts.items);
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

    // System.
    if (ev.readSourceFile("/etc/nix/nix.conf")) |data| {
        try settings.mergeLines(data);
    } else |_| {}

    // User.
    if (try dirFile(allocator, env, "XDG_CONFIG_HOME", &.{".config"}, &.{ "nix", "nix.conf" })) |path| {
        defer allocator.free(path);
        if (ev.readSourceFile(path)) |data| {
            try settings.mergeLines(data);
        } else |_| {}
    }

    // Inline override.
    if (env) |e| {
        if (e.get("NIX_CONFIG")) |inline_conf| try settings.mergeLines(inline_conf);
    }

    return settings;
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
