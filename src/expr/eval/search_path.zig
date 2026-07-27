//! NIX_PATH resolution: the prefix=path entries that drive
//! `<channel>`-style imports and `builtins.findFile`.

const std = @import("std");
const builtins = @import("runtime").builtins;
const path_ops = @import("runtime").paths;
const FileCache = @import("store").FileCache;
const InternTable = @import("runtime").intern.InternTable;
const Value = @import("runtime").value.Value;
const TextRef = @import("base").TextRef;

pub const Entry = struct {
    prefix: []u8,
    path: []u8,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.path);
    }
};

/// Result of resolving a possibly-relative path against a base path.
pub const ResolvedPath = TextRef;

/// Parsed NIX_PATH entries. `set` rebuilds from a `:`-separated string;
/// resolution against base_path is the caller's responsibility (we
/// don't carry base_path so this struct stays decoupled from the
/// Engine's lifecycle).
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
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        var offset: usize = 0;
        while (offset < nix_path.len) {
            const end = searchPathSeparator(nix_path, offset) orelse nix_path.len;
            const part = nix_path[offset..end];
            offset = if (end < nix_path.len) end + 1 else nix_path.len;
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=');
            const prefix = if (eq) |i| part[0..i] else "";
            const raw_path = if (eq) |i| part[i + 1 ..] else part;
            if (raw_path.len == 0) continue;

            var resolved = resolve(ctx, raw_path) catch |err| switch (err) {
                error.RelativePath => continue,
                else => return err,
            };
            defer resolved.deinit(allocator);

            // Reserve the list slot before cloning either field, then keep
            // each clone in a local until the complete Entry can be published.
            // This makes every OOM boundary transactional: no half-entry is
            // reachable and the previous Paths value remains unchanged.
            try entries.ensureUnusedCapacity(allocator, 1);
            const owned_prefix = try allocator.dupe(u8, prefix);
            errdefer allocator.free(owned_prefix);
            const owned_path = try allocator.dupe(u8, resolved.slice());
            errdefer allocator.free(owned_path);
            entries.appendAssumeCapacity(.{
                .prefix = owned_prefix,
                .path = owned_path,
            });
        }

        const replacement = try entries.toOwnedSlice(allocator);
        self.deinit(allocator);
        self.entries = replacement;
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
        const resolved = try self.resolveName(allocator, files, name);
        defer allocator.free(resolved);
        return Value.path(try intern.intern(resolved));
    }

    /// Resolve a lookup-path name to an owned host path. This is the same
    /// search used by `<name>` in the language, exposed separately for legacy
    /// CLI fileish arguments which must load and parse the resolved file.
    pub fn resolveName(self: *const Paths, allocator: std.mem.Allocator, files: *FileCache, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, "nix/fetchurl.nix"))
            return allocator.dupe(u8, "/__corepkgs__/fetchurl.nix");

        for (self.entries) |entry| {
            if (try candidate(allocator, files, entry.path, entry.prefix, name)) |c| return c;
        }
        return error.FileNotFound;
    }

    /// Copy entries into a borrowed `NixPathEntry` slice the caller
    /// owns. Used to populate `builtins.nixPath` at Engine init.
    pub fn toNixPath(self: *const Paths, allocator: std.mem.Allocator) ![]builtins.NixPathEntry {
        const out = try allocator.alloc(builtins.NixPathEntry, self.entries.len);
        for (self.entries, out) |entry, *slot| {
            slot.* = .{ .prefix = entry.prefix, .path = entry.path };
        }
        return out;
    }
};

/// Find the next NIX_PATH separator without mistaking the colon in an HTTP(S)
/// URI (or its port) for an entry boundary. A following `prefix=` or absolute
/// path is an unambiguous new entry; raw colons inside a URL remain part of it.
fn searchPathSeparator(text: []const u8, start: usize) ?usize {
    const first_colon = std.mem.indexOfScalarPos(u8, text, start, ':') orelse return null;
    const eq = std.mem.indexOfScalarPos(u8, text, start, '=');
    const raw_start = if (eq != null and eq.? < first_colon) eq.? + 1 else start;
    const remote = std.mem.startsWith(u8, text[raw_start..], "http://") or std.mem.startsWith(u8, text[raw_start..], "https://") or std.mem.startsWith(u8, text[raw_start..], "file://");
    if (!remote) return first_colon;

    const scheme_colon = std.mem.indexOfScalarPos(u8, text, raw_start, ':').?;
    var in_brackets = false;
    var i = scheme_colon + 3;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '[' => in_brackets = true,
        ']' => in_brackets = false,
        ':' => if (!in_brackets) {
            const rest = text[i + 1 ..];
            if (rest.len == 0) return null;
            if (rest[0] == '/') return i;
            const next_slash = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
            if (std.mem.indexOfScalar(u8, rest[0..next_slash], '=') != null) return i;
        },
        else => {},
    };
    return null;
}

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

fn borrowedTestPath(_: u8, path: []const u8) anyerror!ResolvedPath {
    return .{ .borrowed = path };
}

fn checkPathAllocationFailures(allocator: std.mem.Allocator) !void {
    var paths: Paths = .{};
    defer paths.deinit(allocator);
    try paths.set(
        allocator,
        "nixpkgs=/sources/nixpkgs:local=/sources/local",
        @as(u8, 0),
        borrowedTestPath,
    );
    try std.testing.expectEqual(@as(usize, 2), paths.entries.len);
}

test "search paths handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPathAllocationFailures,
        .{},
    );
}

test "NIX_PATH separators preserve HTTP schemes and ports" {
    try std.testing.expect(searchPathSeparator("nixpkgs=https://example.org/archive.tar.gz", 0) == null);
    const combined = "nixpkgs=http://127.0.0.1:8080/archive.tar.gz:local=/src";
    const separator = searchPathSeparator(combined, 0).?;
    try std.testing.expectEqualStrings("nixpkgs=http://127.0.0.1:8080/archive.tar.gz", combined[0..separator]);
}
