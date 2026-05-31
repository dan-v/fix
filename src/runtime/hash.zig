//! Nix hash builtins over byte slices.

const std = @import("std");

pub fn hashBytes(allocator: std.mem.Allocator, algorithm: []const u8, bytes: []const u8) ![]u8 {
    if (std.mem.eql(u8, algorithm, "md5")) return hexDigest(allocator, std.crypto.hash.Md5, bytes);
    if (std.mem.eql(u8, algorithm, "sha1")) return hexDigest(allocator, std.crypto.hash.Sha1, bytes);
    if (std.mem.eql(u8, algorithm, "sha256")) return hexDigest(allocator, std.crypto.hash.sha2.Sha256, bytes);
    if (std.mem.eql(u8, algorithm, "sha512")) return hexDigest(allocator, std.crypto.hash.sha2.Sha512, bytes);
    return error.UnsupportedHashAlgorithm;
}

fn hexDigest(allocator: std.mem.Allocator, comptime Hash: type, bytes: []const u8) ![]u8 {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

test "hashBytes matches Nix's flat hex encoding" {
    const sha256 = try hashBytes(std.testing.allocator, "sha256", "abc");
    defer std.testing.allocator.free(sha256);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256);
}
