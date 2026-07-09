//! NIX_PATH resolution: the prefix=path entries that drive
//! `<channel>`-style imports and `builtins.findFile`.

const std = @import("std");
const builtins = @import("runtime").builtins;
const path_ops = @import("runtime").paths;
const FileCache = @import("runtime").file_cache.FileCache;
const InternTable = @import("runtime").intern.InternTable;
const Value = @import("runtime").value.Value;

pub const Entry = struct {
    prefix: []u8,
    path: []u8,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.path);
    }
};

/// Result of resolving a possibly-relative path against a base path.
/// `owned` says whether `text` was freshly allocated and the caller
/// owns it (true) or whether `text` is borrowed from the input (false).
pub const ResolvedPath = struct {
    text: []const u8,
    owned: bool,
};

/// Parsed NIX_PATH entries. `set` rebuilds from a `:`-separated string;
/// resolution against base_path is the caller's responsibility (we
/// don't carry base_path so this struct stays decoupled from the
/// Evaluator's lifecycle).
pub const Paths = struct {
    entries: []Entry = &.{},

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.entries = &.{};
    }

    /// Replace entries from a colon-separated NIX_PATH string. The
    /// optional `resolve` is called on each entry's path; if it
    /// returns `error.RelativePath` the entry is dropped silently
    /// (matches Nix's behaviour for a relative search-path entry
    /// without a known base).
    pub fn set(
        self: *Paths,
        allocator: std.mem.Allocator,
        nix_path: []const u8,
        ctx: anytype,
        comptime resolve: fn (@TypeOf(ctx), []const u8) anyerror!ResolvedPath,
    ) !void {
        self.deinit(allocator);

        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        var parts = std.mem.splitScalar(u8, nix_path, ':');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=');
            const prefix = if (eq) |i| part[0..i] else "";
            const raw_path = if (eq) |i| part[i + 1 ..] else part;
            if (raw_path.len == 0) continue;

            const resolved = resolve(ctx, raw_path) catch |err| switch (err) {
                error.RelativePath => continue,
                else => return err,
            };
            defer if (resolved.owned) allocator.free(resolved.text);

            try entries.append(allocator, .{
                .prefix = try allocator.dupe(u8, prefix),
                .path = try allocator.dupe(u8, resolved.text),
            });
        }

        self.entries = try entries.toOwnedSlice(allocator);
    }

    /// Walk entries looking for one whose `prefix` matches `name`. On
    /// match, returns the absolute path as a Nix `Value.path` interned
    /// in `intern`. Returns `error.FileNotFound` if nothing matches.
    /// `nix/fetchurl.nix` short-circuits to the corepkgs synthetic
    /// path used by `builtins.fetchurl`.
    pub fn findFile(
        self: *const Paths,
        allocator: std.mem.Allocator,
        files: *FileCache,
        intern: *InternTable,
        name: []const u8,
    ) !Value {
        if (std.mem.eql(u8, name, "nix/fetchurl.nix")) {
            return Value.path(try intern.intern("/__corepkgs__/fetchurl.nix"));
        }

        for (self.entries) |entry| {
            if (try candidate(allocator, files, entry.path, entry.prefix, name)) |c| {
                defer allocator.free(c);
                return Value.path(try intern.intern(c));
            }
        }
        return error.FileNotFound;
    }

    /// Copy entries into a borrowed `NixPathEntry` slice the caller
    /// owns. Used to populate `builtins.nixPath` at Evaluator init.
    pub fn toNixPath(self: *const Paths, allocator: std.mem.Allocator) ![]builtins.NixPathEntry {
        const out = try allocator.alloc(builtins.NixPathEntry, self.entries.len);
        for (self.entries, out) |entry, *slot| {
            slot.* = .{ .prefix = entry.prefix, .path = entry.path };
        }
        return out;
    }
};

fn candidate(
    allocator: std.mem.Allocator,
    files: *FileCache,
    base: []const u8,
    prefix: []const u8,
    name: []const u8,
) !?[]u8 {
    const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
    const result = try std.fs.path.resolve(allocator, &.{ base, suffix });
    errdefer allocator.free(result);
    if (try files.pathExists(result)) return result;
    allocator.free(result);
    return null;
}
