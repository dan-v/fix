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

/// A source added to (or computed for) the store.
pub const Ingested = struct {
    /// The `/nix/store/...` path (recursive, `fixed:r:sha256`).
    store_path: []u8,
    /// The NAR hash in Nix SRI form (`sha256-<base64>`), for `narHash` attrs.
    nar_hash: []u8,

    pub fn deinit(self: Ingested, allocator: std.mem.Allocator) void {
        allocator.free(self.store_path);
        allocator.free(self.nar_hash);
    }
};

/// Compute the store path + NAR hash for `path` (serialized under `filter`)
/// and, when a daemon is attached, add the content to the store. Serializing to
/// hash is what the hasher already did, so the add costs only the socket write.
pub fn ingest(
    allocator: std.mem.Allocator,
    derivations: *DerivationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
) !Ingested {
    const nar_bytes = try nar.serialize(allocator, files, path, filter);
    defer allocator.free(nar_bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(nar_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    const store_path = try drv_paths.sourcePath(allocator, derivations.store_dir, name, hex[0..]);
    errdefer allocator.free(store_path);
    try derivations.instantiatePath(store_path, nar_bytes);

    return .{ .store_path = store_path, .nar_hash = try sriHash(allocator, &digest) };
}

/// Encode a sha256 digest as a Nix SRI hash: `sha256-<standard base64>`.
fn sriHash(allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, "sha256-".len + enc.calcSize(digest.len));
    errdefer allocator.free(out);
    @memcpy(out[0.."sha256-".len], "sha256-");
    _ = enc.encode(out["sha256-".len..], digest);
    return out;
}

/// Compute the store path for `path` (NAR-serialized under `filter`) and, when
/// a daemon is attached, add the content to the store.
pub fn storePathForFilteredSource(
    allocator: std.mem.Allocator,
    derivations: *DerivationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
) ![]u8 {
    const ingested = try ingest(allocator, derivations, files, path, name, filter);
    allocator.free(ingested.nar_hash);
    return ingested.store_path;
}

pub fn isStoreRootPath(path: []const u8, store_dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, store_dir)) return false;
    if (path.len <= store_dir.len or path[store_dir.len] != '/') return false;
    return std.mem.indexOfScalar(u8, path[store_dir.len + 1 ..], '/') == null;
}
