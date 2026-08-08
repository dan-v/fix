//! Minimal NAR serialization for hashing and adding source paths.

const std = @import("std");
const FileCache = @import("file_cache.zig").FileCache;

pub const Filter = struct {
    context: *anyopaque,
    accept: *const fn (context: *anyopaque, path: []const u8, kind: FileCache.FileKind) anyerror!bool,
};

/// Out-parameter for `serialize`: when serialization aborts on a file whose
/// type NAR cannot represent (fifo/socket/device — anything reported as
/// `.unknown`), the offending path is recorded here so callers can build the
/// Nix-style `file '<path>' has an unsupported type` diagnostic. `path` is
/// allocated with the serializer's allocator; the caller owns and frees it.
pub const Unsupported = struct {
    path: ?[]u8 = null,

    pub fn deinit(self: *Unsupported, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        self.path = null;
    }
};

/// Serialize `path` to a NAR byte stream (`nix-archive-1` format), applying
/// `filter` to directory descent. Caller owns the returned buffer. This is the
/// dump the daemon's `AddToStore` (recursive/NAR ingestion) reads.
pub fn serialize(allocator: std.mem.Allocator, files: *FileCache, path: []const u8, filter: ?Filter) ![]u8 {
    return serializeReport(allocator, files, path, filter, null);
}

/// `serialize`, but records the offending path into `unsupported` (when
/// non-null) on `error.UnsupportedPathType`.
pub fn serializeReport(
    allocator: std.mem.Allocator,
    files: *FileCache,
    path: []const u8,
    filter: ?Filter,
    unsupported: ?*Unsupported,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeArchive(allocator, files, &out.writer, path, filter, unsupported);
    return out.toOwnedSlice();
}

fn writeArchive(
    allocator: std.mem.Allocator,
    files: *FileCache,
    writer: *std.Io.Writer,
    path: []const u8,
    filter: ?Filter,
    unsupported: ?*Unsupported,
) !void {
    try writeString(writer, "nix-archive-1");
    // Nix resolves the *root* source object before serializing: a top-level
    // symlink is followed to its target, which is then dumped as that target's
    // type (e.g. a directory). Only the root is resolved — symlinks encountered
    // as directory entries are still serialized as symlink nodes (below).
    const root = try resolveRootSymlink(allocator, files, path);
    defer allocator.free(root);
    try writeNode(allocator, files, writer, root, filter, unsupported);
}

/// Follow a chain of symlinks at the *root* of a source path, returning the
/// resolved path (caller owns it). Matches Nix: the top-level object of a
/// `filterSource`/`builtins.path`/path-coercion ingest is resolved before
/// serialization, while nested symlinks are left alone. A non-symlink root, a
/// broken/dangling chain, or a symlink cycle falls back to the original path
/// (so a dangling root still serializes as a symlink node, as before).
fn resolveRootSymlink(allocator: std.mem.Allocator, files: *FileCache, path: []const u8) ![]u8 {
    const kind = files.fileType(path) catch return allocator.dupe(u8, path);
    if (kind != .symlink) return allocator.dupe(u8, path);

    var current = try allocator.dupe(u8, path);
    errdefer allocator.free(current);
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        const cur_kind = files.fileType(current) catch {
            // Allocate the fallback before freeing `current`: if the dupe fails,
            // `errdefer allocator.free(current)` must be the only free of it.
            const fallback = try allocator.dupe(u8, path);
            allocator.free(current);
            return fallback;
        };
        if (cur_kind != .symlink) return current;
        const target = try files.readLink(current);
        defer allocator.free(target);
        const dir = std.fs.path.dirname(current) orelse "/";
        const next = try std.fs.path.resolve(allocator, &.{ dir, target });
        allocator.free(current);
        current = next;
    }
    // Symlink cycle: give up and serialize the original as a symlink node.
    // Allocate the fallback before freeing `current` so an allocation failure
    // leaves exactly one owner for `errdefer` to free.
    const fallback = try allocator.dupe(u8, path);
    allocator.free(current);
    return fallback;
}

pub fn hashPath(allocator: std.mem.Allocator, files: *FileCache, path: []const u8) ![]u8 {
    return hashPathFiltered(allocator, files, path, null);
}

pub fn hashPathFiltered(allocator: std.mem.Allocator, files: *FileCache, path: []const u8, filter: ?Filter) ![]u8 {
    const digest = try hashPathDigestFiltered(allocator, files, path, filter);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

/// SHA-256 of a canonical NAR stream, produced incrementally. Traversal still
/// allocates bounded path/sort scratch, but never retains the archive payload.
pub fn hashPathDigest(allocator: std.mem.Allocator, files: *FileCache, path: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    return hashPathDigestFiltered(allocator, files, path, null);
}

pub fn hashPathDigestFiltered(
    allocator: std.mem.Allocator,
    files: *FileCache,
    path: []const u8,
    filter: ?Filter,
) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    const Sha256 = @import("base").sha256.Sha256;
    var hashing: std.Io.Writer.Hashing(Sha256) = .init(&.{});
    try writeArchive(allocator, files, &hashing.writer, path, filter, null);
    try hashing.writer.flush();
    var digest: [Sha256.digest_length]u8 = undefined;
    hashing.hasher.final(&digest);
    return digest;
}

/// Hex sha256 of an already-serialized NAR byte stream (caller owns result).
pub fn hashSerialized(allocator: std.mem.Allocator, nar_bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    @import("base").sha256.Sha256.hash(nar_bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn writeNode(allocator: std.mem.Allocator, files: *FileCache, writer: *std.Io.Writer, path: []const u8, filter: ?Filter, unsupported: ?*Unsupported) !void {
    try writeString(writer, "(");
    switch (try files.fileType(path)) {
        .regular => {
            try writeString(writer, "type");
            try writeString(writer, "regular");
            if (try files.isExecutable(path)) {
                try writeString(writer, "executable");
                try writeString(writer, "");
            }
            try writeString(writer, "contents");
            try writeString(writer, try files.readFile(path));
        },
        .directory => {
            try writeString(writer, "type");
            try writeString(writer, "directory");
            const entries = try sortedDirEntries(allocator, try files.readDir(path));
            defer allocator.free(entries);
            for (entries) |entry| {
                const child = try std.fs.path.join(allocator, &.{ path, entry.name });
                defer allocator.free(child);
                if (filter) |f| {
                    // Use the stat-accurate type (like Nix's lstat), not the
                    // readdir d_type — they can disagree (DT_UNKNOWN on some
                    // filesystems, or a bind-mounted node), and the type handed
                    // to the filter must match what serialization sees below.
                    const kind = files.fileType(child) catch entry.kind;
                    if (!try f.accept(f.context, child, kind)) continue;
                }
                try writeString(writer, "entry");
                try writeString(writer, "(");
                try writeString(writer, "name");
                try writeString(writer, entry.name);
                try writeString(writer, "node");
                try writeNode(allocator, files, writer, child, filter, unsupported);
                try writeString(writer, ")");
            }
        },
        .symlink => {
            const target = try files.readLink(path);
            defer allocator.free(target);
            try writeString(writer, "type");
            try writeString(writer, "symlink");
            try writeString(writer, "target");
            try writeString(writer, target);
        },
        .unknown => {
            if (unsupported) |u| {
                if (u.path == null) u.path = try allocator.dupe(u8, path);
            }
            return error.UnsupportedPathType;
        },
    }
    try writeString(writer, ")");
}

fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, text.len, .little);
    try writer.writeAll(&len);
    try writer.writeAll(text);
    const padding = (8 - text.len % 8) % 8;
    try writer.splatByteAll(0, padding);
}

fn sortedDirEntries(allocator: std.mem.Allocator, entries: []const FileCache.DirEntry) ![]FileCache.DirEntry {
    const sorted = try allocator.dupe(FileCache.DirEntry, entries);
    std.mem.sort(FileCache.DirEntry, sorted, {}, struct {
        fn lessThan(_: void, left: FileCache.DirEntry, right: FileCache.DirEntry) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return sorted;
}

test "streaming path digest matches retained canonical NAR bytes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "payload",
        .data = "stream me without retaining a second archive",
    });
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const path = try std.fs.path.resolve(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload",
    });
    defer testing.allocator.free(path);

    var files = FileCache.init(testing.allocator);
    defer files.deinit();
    files.setIo(testing.io);

    const serialized = try serialize(testing.allocator, &files, path, null);
    defer testing.allocator.free(serialized);
    const retained_hash = try hashSerialized(testing.allocator, serialized);
    defer testing.allocator.free(retained_hash);

    const digest = try hashPathDigest(testing.allocator, &files, path);
    const streaming_hash = std.fmt.bytesToHex(digest, .lower);
    try testing.expectEqualStrings(retained_hash, &streaming_hash);
}
