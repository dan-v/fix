const std = @import("std");
const sort = @import("sort.zig");
const codec = @import("hash_codec.zig");

// Store-path fingerprints hash through the shared codec (`hash_codec.zig`).
const sha256Hex = codec.sha256Hex;
const storeDigest = codec.storeDigest;

pub fn inputAddressedOutputPath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    name: []const u8,
    output: []const u8,
    hash_modulo: []const u8,
) ![]u8 {
    const output_name = try outputPathName(allocator, name, output);
    defer allocator.free(output_name);
    const ty = try std.fmt.allocPrint(allocator, "output:{s}", .{output});
    defer allocator.free(ty);
    return storePathFromInnerDigest(allocator, store_dir, ty, hash_modulo, output_name);
}

pub fn fixedOutputPath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    drv_name: []const u8,
    output: []const u8,
    hash_algo: []const u8,
    hash: []const u8,
) ![]u8 {
    const output_name = try outputPathName(allocator, drv_name, output);
    defer allocator.free(output_name);
    if (std.mem.startsWith(u8, hash_algo, "r:")) {
        return storePathFromInnerDigest(allocator, store_dir, "source", hash, output_name);
    }
    const inner = try std.fmt.allocPrint(allocator, "fixed:out:{s}:{s}:", .{ hash_algo, hash });
    defer allocator.free(inner);
    const digest = try sha256Hex(allocator, inner);
    defer allocator.free(digest);
    return storePathFromInnerDigest(allocator, store_dir, "output:out", digest, output_name);
}

pub fn sourcePath(allocator: std.mem.Allocator, store_dir: []const u8, name: []const u8, nar_hash_hex: []const u8) ![]u8 {
    return storePathFromInnerDigest(allocator, store_dir, "source", nar_hash_hex, name);
}

fn textStorePath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    name: []const u8,
    text: []const u8,
    refs: anytype,
) ![]u8 {
    const digest = try sha256Hex(allocator, text);
    defer allocator.free(digest);
    var ty: std.ArrayListUnmanaged(u8) = .empty;
    defer ty.deinit(allocator);
    try ty.appendSlice(allocator, "text");
    const sorted_refs = try sort.sortedStrings(allocator, refs);
    defer allocator.free(sorted_refs);
    for (sorted_refs) |ref| {
        try ty.append(allocator, ':');
        try ty.appendSlice(allocator, ref);
    }
    return storePathFromInnerDigest(allocator, store_dir, ty.items, digest, name);
}

pub fn textPath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    name: []const u8,
    text: []const u8,
    refs: []const []const u8,
) ![]u8 {
    return textStorePath(allocator, store_dir, name, text, refs);
}

fn storePathFromInnerDigest(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    ty: []const u8,
    inner_digest: []const u8,
    name: []const u8,
) ![]u8 {
    const fingerprint = try std.fmt.allocPrint(allocator, "{s}:sha256:{s}:{s}:{s}", .{ ty, inner_digest, store_dir, name });
    defer allocator.free(fingerprint);
    const hash = storeDigest(fingerprint);
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}", .{ store_dir, hash, name });
}

pub fn outputPathName(allocator: std.mem.Allocator, drv_name: []const u8, output: []const u8) ![]u8 {
    if (std.mem.eql(u8, output, "out")) return allocator.dupe(u8, drv_name);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ drv_name, output });
}

pub fn drvPathName(allocator: std.mem.Allocator, drv_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.drv", .{drv_name});
}
