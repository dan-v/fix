//! Nix hash builtins over byte slices.

const std = @import("std");

pub fn hashBytes(allocator: std.mem.Allocator, algorithm: []const u8, bytes: []const u8) ![]u8 {
    if (std.mem.eql(u8, algorithm, "md5")) return hexDigest(allocator, std.crypto.hash.Md5, bytes);
    if (std.mem.eql(u8, algorithm, "sha1")) return hexDigest(allocator, std.crypto.hash.Sha1, bytes);
    if (std.mem.eql(u8, algorithm, "sha256")) return hexDigest(allocator, std.crypto.hash.sha2.Sha256, bytes);
    if (std.mem.eql(u8, algorithm, "sha512")) return hexDigest(allocator, std.crypto.hash.sha2.Sha512, bytes);
    return error.UnsupportedHashAlgorithm;
}

pub fn hashBytesNixBase32(allocator: std.mem.Allocator, algorithm: []const u8, bytes: []const u8) ![]u8 {
    if (std.mem.eql(u8, algorithm, "md5")) return nixBase32Digest(allocator, std.crypto.hash.Md5, bytes);
    if (std.mem.eql(u8, algorithm, "sha1")) return nixBase32Digest(allocator, std.crypto.hash.Sha1, bytes);
    if (std.mem.eql(u8, algorithm, "sha256")) return nixBase32Digest(allocator, std.crypto.hash.sha2.Sha256, bytes);
    if (std.mem.eql(u8, algorithm, "sha512")) return nixBase32Digest(allocator, std.crypto.hash.sha2.Sha512, bytes);
    return error.UnsupportedHashAlgorithm;
}

fn hexDigest(allocator: std.mem.Allocator, comptime Hash: type, bytes: []const u8) ![]u8 {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn nixBase32Digest(allocator: std.mem.Allocator, comptime Hash: type, bytes: []const u8) ![]u8 {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(bytes, &digest, .{});
    return nixBase32(allocator, &digest);
}

fn nixBase32(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
    const encoded_len = (bytes.len * 8 + 4) / 5;
    const encoded = try allocator.alloc(u8, encoded_len);
    for (0..encoded.len) |n| {
        const bit = n * 5;
        const byte_index = bit / 8;
        const bit_index: u3 = @intCast(bit % 8);
        var value: u16 = bytes[byte_index] >> bit_index;
        if (byte_index + 1 < bytes.len) {
            const next_shift: u4 = 8 - @as(u4, bit_index);
            value |= @as(u16, bytes[byte_index + 1]) << next_shift;
        }
        encoded[encoded.len - n - 1] = alphabet[@as(usize, value & 0x1f)];
    }
    return encoded;
}

test "hashBytes matches Nix's flat hex encoding" {
    const sha256 = try hashBytes(std.testing.allocator, "sha256", "abc");
    defer std.testing.allocator.free(sha256);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256);
}

test "hashBytesNixBase32 matches Nix's base32 encoding" {
    const sha256 = try hashBytesNixBase32(std.testing.allocator, "sha256", "nix-output:out");
    defer std.testing.allocator.free(sha256);
    try std.testing.expectEqualStrings("1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9", sha256);
}
