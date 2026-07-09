//! Resolve indirect flake references (bare ids like `nixpkgs`) to concrete
//! flakerefs (`github:NixOS/nixpkgs/...`) by reusing Nix's `registry.json`
//! files. Precedence: user (`$XDG_CONFIG_HOME/nix`), system (`/etc/nix`), then
//! the pinned global registry (`$XDG_CACHE_HOME/nix/flake-registry.json`).

const std = @import("std");
const Evaluator = @import("fix").eval.Evaluator;

/// Resolve `id` to a concrete flakeref string (owned by `allocator`), or null
/// if not found. Best-effort: missing/unparseable registry files are skipped.
pub fn resolve(allocator: std.mem.Allocator, ev: *Evaluator, id: []const u8) !?[]u8 {
    const env = ev.environment();

    // User registry.
    if (try dirFile(allocator, env, "XDG_CONFIG_HOME", &.{".config"}, &.{ "nix", "registry.json" })) |path| {
        defer allocator.free(path);
        if (try lookup(allocator, ev, path, id)) |ref| return ref;
    }
    // System registry.
    if (try lookup(allocator, ev, "/etc/nix/registry.json", id)) |ref| return ref;
    // Pinned global registry (has nixpkgs, home-manager, ...).
    if (try dirFile(allocator, env, "XDG_CACHE_HOME", &.{".cache"}, &.{ "nix", "flake-registry.json" })) |path| {
        defer allocator.free(path);
        if (try lookup(allocator, ev, path, id)) |ref| return ref;
    }
    return null;
}

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

fn lookup(allocator: std.mem.Allocator, ev: *Evaluator, path: []const u8, id: []const u8) !?[]u8 {
    const data = ev.readSourceFile(path) catch return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const flakes = parsed.value.object.get("flakes") orelse return null;
    if (flakes != .array) return null;

    for (flakes.array.items) |entry| {
        if (entry != .object) continue;
        const from = entry.object.get("from") orelse continue;
        if (from != .object) continue;
        const from_id = from.object.get("id") orelse continue;
        if (from_id != .string or !std.mem.eql(u8, from_id.string, id)) continue;
        const to = entry.object.get("to") orelse continue;
        return flakeRef(allocator, to);
    }
    return null;
}

/// Render a registry `to` node as a flakeref string.
fn flakeRef(allocator: std.mem.Allocator, to: std.json.Value) !?[]u8 {
    if (to != .object) return null;
    const ty = strField(to, "type") orelse return null;

    if (std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab") or std.mem.eql(u8, ty, "sourcehut")) {
        const owner = strField(to, "owner") orelse return null;
        const repo = strField(to, "repo") orelse return null;
        const rev_or_ref = strField(to, "rev") orelse strField(to, "ref");
        if (rev_or_ref) |r| return try std.fmt.allocPrint(allocator, "{s}:{s}/{s}/{s}", .{ ty, owner, repo, r });
        return try std.fmt.allocPrint(allocator, "{s}:{s}/{s}", .{ ty, owner, repo });
    }
    if (std.mem.eql(u8, ty, "path")) {
        const p = strField(to, "path") orelse return null;
        return try std.fmt.allocPrint(allocator, "path:{s}", .{p});
    }
    if (strField(to, "url")) |url| return try allocator.dupe(u8, url);
    return null;
}

fn strField(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
