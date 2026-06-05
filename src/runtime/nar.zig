//! Minimal NAR serialization for hashing source paths.

const std = @import("std");
const FileCache = @import("../file_cache.zig").FileCache;

pub const Filter = struct {
    context: *anyopaque,
    accept: *const fn (context: *anyopaque, path: []const u8, kind: FileCache.FileKind) anyerror!bool,
};

pub fn hashPath(allocator: std.mem.Allocator, files: *FileCache, path: []const u8) ![]u8 {
    return hashPathFiltered(allocator, files, path, null);
}

pub fn hashPathFiltered(allocator: std.mem.Allocator, files: *FileCache, path: []const u8, filter: ?Filter) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendString(allocator, &out, "nix-archive-1");
    try appendNode(allocator, files, &out, path, filter);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.items, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn appendNode(allocator: std.mem.Allocator, files: *FileCache, out: *std.ArrayListUnmanaged(u8), path: []const u8, filter: ?Filter) !void {
    try appendString(allocator, out, "(");
    switch (try files.fileType(path)) {
        .regular => {
            try appendString(allocator, out, "type");
            try appendString(allocator, out, "regular");
            if (try files.isExecutable(path)) {
                try appendString(allocator, out, "executable");
                try appendString(allocator, out, "");
            }
            try appendString(allocator, out, "contents");
            try appendString(allocator, out, try files.readFile(path));
        },
        .directory => {
            try appendString(allocator, out, "type");
            try appendString(allocator, out, "directory");
            const entries = try sortedDirEntries(allocator, try files.readDir(path));
            defer allocator.free(entries);
            for (entries) |entry| {
                const child = try std.fs.path.join(allocator, &.{ path, entry.name });
                defer allocator.free(child);
                if (filter) |f| {
                    if (!try f.accept(f.context, child, entry.kind)) continue;
                }
                try appendString(allocator, out, "entry");
                try appendString(allocator, out, "(");
                try appendString(allocator, out, "name");
                try appendString(allocator, out, entry.name);
                try appendString(allocator, out, "node");
                try appendNode(allocator, files, out, child, filter);
                try appendString(allocator, out, ")");
            }
        },
        .symlink => {
            const target = try files.readLink(path);
            defer allocator.free(target);
            try appendString(allocator, out, "type");
            try appendString(allocator, out, "symlink");
            try appendString(allocator, out, "target");
            try appendString(allocator, out, target);
        },
        .unknown => return error.UnsupportedPathType,
    }
    try appendString(allocator, out, ")");
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, text.len, .little);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, text);
    const padding = (8 - text.len % 8) % 8;
    try out.appendNTimes(allocator, 0, padding);
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
