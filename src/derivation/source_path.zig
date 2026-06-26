//! Source path realization helpers.

const std = @import("std");
const drv_paths = @import("paths.zig");
const FileCache = @import("../file_cache.zig").FileCache;
const nar = @import("../runtime/nar.zig");
const path_ops = @import("../runtime/paths.zig");

pub fn storePathForSource(
    allocator: std.mem.Allocator,
    files: *FileCache,
    store_dir: []const u8,
    path: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (isStoreRootPath(path, store_dir)) return allocator.dupe(u8, path);

    return storePathForSourceName(allocator, files, store_dir, path, path_ops.baseName(path));
}

pub fn storePathForSourceName(
    allocator: std.mem.Allocator,
    files: *FileCache,
    store_dir: []const u8,
    path: []const u8,
    name: []const u8,
) ![]u8 {
    const hash = try nar.hashPath(allocator, files, path);
    defer allocator.free(hash);
    return drv_paths.sourcePath(allocator, store_dir, name, hash);
}

pub fn isStoreRootPath(path: []const u8, store_dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, store_dir)) return false;
    if (path.len <= store_dir.len or path[store_dir.len] != '/') return false;
    return std.mem.indexOfScalar(u8, path[store_dir.len + 1 ..], '/') == null;
}
