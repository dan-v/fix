//! Source path realization: compute the `/nix/store` path for a filesystem
//! source (by NAR hash) and, when a daemon store is attached to the
//! `DerivationStore`, add the source content there. This is the single
//! ingestion chokepoint for `builtins.path`, `filterSource`, and path
//! coercion (`src = ./.`).

const std = @import("std");
const drv_paths = @import("paths.zig");
const DerivationStore = @import("store.zig").DerivationStore;
const FileCache = @import("runtime").file_cache.FileCache;
const nar = @import("runtime").nar;
const path_ops = @import("runtime").paths;

pub fn storePathForSource(
    allocator: std.mem.Allocator,
    derivations: *DerivationStore,
    files: *FileCache,
    path: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (isStoreRootPath(path, derivations.store_dir)) return allocator.dupe(u8, path);

    return storePathForSourceName(allocator, derivations, files, path, path_ops.baseName(path));
}

pub fn storePathForSourceName(
    allocator: std.mem.Allocator,
    derivations: *DerivationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
) ![]u8 {
    return storePathForFilteredSource(allocator, derivations, files, path, name, null);
}

/// Compute the store path for `path` (NAR-serialized under `filter`) and, when
/// a daemon is attached, add the content to the store. Serializing to hash is
/// what the hasher already did, so the add costs only the socket write.
pub fn storePathForFilteredSource(
    allocator: std.mem.Allocator,
    derivations: *DerivationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
) ![]u8 {
    const nar_bytes = try nar.serialize(allocator, files, path, filter);
    defer allocator.free(nar_bytes);
    const hash = try nar.hashSerialized(allocator, nar_bytes);
    defer allocator.free(hash);

    const store_path = try drv_paths.sourcePath(allocator, derivations.store_dir, name, hash);
    errdefer allocator.free(store_path);
    try derivations.instantiatePath(store_path, nar_bytes);
    return store_path;
}

pub fn isStoreRootPath(path: []const u8, store_dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, store_dir)) return false;
    if (path.len <= store_dir.len or path[store_dir.len] != '/') return false;
    return std.mem.indexOfScalar(u8, path[store_dir.len + 1 ..], '/') == null;
}
