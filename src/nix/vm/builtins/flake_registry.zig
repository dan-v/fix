//! Flake registry resolution — a Nix semantic (part of flake-ref resolution),
//! not a CLI concern, so it lives here next to the flake builtins.
//!
//! Maps an indirect flakeref id (`nixpkgs`, `nixpkgs/nixos-24.05`) to a concrete
//! ref via `registry.json`. Precedence: user (`$XDG_CONFIG_HOME/nix`), system
//! (`/etc/nix`), then the pinned global registry (`$XDG_CACHE_HOME/nix/
//! flake-registry.json`). Missing/unparseable registries are skipped.
//!
//! Uses the VM's own primitives (`self.files`, `self.import_host.get_env`) so it
//! works wherever a flake builtin runs, independent of the CLI.

const std = @import("std");

/// Resolve indirect `ref` (`id` or `id/refOrRev`) to a concrete flakeref string
/// owned by `self.allocator`, or null when it isn't a known indirect id.
pub fn resolve(self: anytype, ref: []const u8) !?[]u8 {
    const slash = std.mem.indexOfScalar(u8, ref, '/');
    const id = if (slash) |i| ref[0..i] else ref;
    if (id.len == 0) return null;

    const base = (try lookupId(self, id)) orelse return null;
    if (slash == null) return base;
    // A trailing `/branch-or-rev` refines the resolved forge ref
    // (`github:o/r` -> `github:o/r/<suffix>`).
    defer self.allocator.free(base);
    return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, ref[slash.? + 1 ..] });
}

fn envVar(self: anytype, name: []const u8) !?[]const u8 {
    const host = self.import_host orelse return null;
    const v = try host.get_env(host.context, name);
    return if (v.len == 0) null else v;
}

/// `$<xdg>/<tail>`, else `$HOME/<home_prefix>/<tail>`. Owned; null if neither.
fn xdgPath(self: anytype, xdg: []const u8, home_prefix: []const u8, tail: []const u8) !?[]u8 {
    if (try envVar(self, xdg)) |dir| {
        return try std.fs.path.join(self.allocator, &.{ dir, tail });
    }
    const home = (try envVar(self, "HOME")) orelse return null;
    return try std.fs.path.join(self.allocator, &.{ home, home_prefix, tail });
}

fn lookupId(self: anytype, id: []const u8) !?[]u8 {
    if (try xdgPath(self, "XDG_CONFIG_HOME", ".config", "nix/registry.json")) |path| {
        defer self.allocator.free(path);
        if (try lookupIn(self, path, id)) |r| return r;
    }
    if (try lookupIn(self, "/etc/nix/registry.json", id)) |r| return r;
    if (try xdgPath(self, "XDG_CACHE_HOME", ".cache", "nix/flake-registry.json")) |path| {
        defer self.allocator.free(path);
        if (try lookupIn(self, path, id)) |r| return r;
    }
    return null;
}

fn lookupIn(self: anytype, path: []const u8, id: []const u8) !?[]u8 {
    const data = self.files.readFile(path) catch return null;
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return null;
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
        if (to != .object) continue;
        return try renderRef(self.allocator, to.object);
    }
    return null;
}

/// Render a registry `to` node as a concrete flakeref string.
fn renderRef(allocator: std.mem.Allocator, to: std.json.ObjectMap) !?[]u8 {
    const ty = strField(to, "type") orelse return null;
    if (std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab") or std.mem.eql(u8, ty, "sourcehut")) {
        const owner = strField(to, "owner") orelse return null;
        const repo = strField(to, "repo") orelse return null;
        if (strField(to, "rev") orelse strField(to, "ref")) |r| {
            return try std.fmt.allocPrint(allocator, "{s}:{s}/{s}/{s}", .{ ty, owner, repo, r });
        }
        return try std.fmt.allocPrint(allocator, "{s}:{s}/{s}", .{ ty, owner, repo });
    }
    if (std.mem.eql(u8, ty, "path")) {
        const p = strField(to, "path") orelse return null;
        return try std.fmt.allocPrint(allocator, "path:{s}", .{p});
    }
    if (strField(to, "url")) |url| return try allocator.dupe(u8, url);
    return null;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
