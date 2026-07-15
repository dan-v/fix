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
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const sink = BufSink{ .allocator = allocator, .out = &out };
    try appendString(sink, "nix-archive-1");
    // Nix resolves the *root* source object before serializing: a top-level
    // symlink is followed to its target, which is then dumped as that target's
    // type (e.g. a directory). Only the root is resolved — symlinks encountered
    // as directory entries are still serialized as symlink nodes (below).
    const root = try resolveRootSymlink(allocator, files, path);
    defer allocator.free(root);
    try appendNode(allocator, files, sink, root, filter, unsupported);

    return out.toOwnedSlice(allocator);
}

/// Compute the sha256 digest of the NAR of `path` (under `filter`) by streaming
/// the serialization straight into the hash, never materializing the full NAR
/// buffer. Byte-for-byte identical to `hashSerialized(serializeReport(...))`,
/// but with no whole-tree allocation — used on the plain-eval source path where
/// only the digest (store path) is needed, not the bytes. Per-file contents are
/// still read (FileCache-cached), just not accumulated into one buffer.
pub fn hashStreamingReport(
    allocator: std.mem.Allocator,
    files: *FileCache,
    path: []const u8,
    filter: ?Filter,
    unsupported: ?*Unsupported,
) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const sink = HashSink{ .hasher = &hasher };
    try appendString(sink, "nix-archive-1");
    const root = try resolveRootSymlink(allocator, files, path);
    defer allocator.free(root);
    try appendNode(allocator, files, sink, root, filter, unsupported);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
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
    const nar_bytes = try serialize(allocator, files, path, filter);
    defer allocator.free(nar_bytes);
    return hashSerialized(allocator, nar_bytes);
}

/// Hex sha256 of an already-serialized NAR byte stream (caller owns result).
pub fn hashSerialized(allocator: std.mem.Allocator, nar_bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(nar_bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn appendNode(allocator: std.mem.Allocator, files: *FileCache, sink: anytype, path: []const u8, filter: ?Filter, unsupported: ?*Unsupported) !void {
    try appendString(sink, "(");
    switch (try files.fileType(path)) {
        .regular => {
            try appendString(sink, "type");
            try appendString(sink, "regular");
            if (try files.isExecutable(path)) {
                try appendString(sink, "executable");
                try appendString(sink, "");
            }
            try appendString(sink, "contents");
            try appendString(sink, try files.readFile(path));
        },
        .directory => {
            try appendString(sink, "type");
            try appendString(sink, "directory");
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
                try appendString(sink, "entry");
                try appendString(sink, "(");
                try appendString(sink, "name");
                try appendString(sink, entry.name);
                try appendString(sink, "node");
                try appendNode(allocator, files, sink, child, filter, unsupported);
                try appendString(sink, ")");
            }
        },
        .symlink => {
            const target = try files.readLink(path);
            defer allocator.free(target);
            try appendString(sink, "type");
            try appendString(sink, "symlink");
            try appendString(sink, "target");
            try appendString(sink, target);
        },
        .unknown => {
            if (unsupported) |u| {
                if (u.path == null) u.path = try allocator.dupe(u8, path);
            }
            return error.UnsupportedPathType;
        },
    }
    try appendString(sink, ")");
}

/// A NAR byte sink. `appendNode`/`appendString` are generic over it so the same
/// tree walk drives either materialization (`BufSink`, retaining the NAR bytes)
/// or streaming hash (`HashSink`, feeding a running Sha256 with no buffer) —
/// guaranteeing both produce a byte-identical stream and thus the same hash.
const BufSink = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    fn writeAll(self: BufSink, bytes: []const u8) !void {
        try self.out.appendSlice(self.allocator, bytes);
    }
};

const HashSink = struct {
    hasher: *std.crypto.hash.sha2.Sha256,
    fn writeAll(self: HashSink, bytes: []const u8) !void {
        self.hasher.update(bytes);
    }
};

fn appendString(sink: anytype, text: []const u8) !void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, text.len, .little);
    try sink.writeAll(&len);
    try sink.writeAll(text);
    const padding = (8 - text.len % 8) % 8;
    if (padding != 0) {
        const zeros = [_]u8{0} ** 8;
        try sink.writeAll(zeros[0..padding]);
    }
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
