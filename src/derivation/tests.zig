const std = @import("std");
const derivation = @import("../derivation.zig");

const DerivationStore = derivation.DerivationStore;
const Drv = derivation.Drv;
const DrvOutput = derivation.DrvOutput;
const EnvVar = derivation.EnvVar;
const hashToBase16 = derivation.hashToBase16;
const storeDigest = derivation.storeDigest;

test "store digest uses Nix base32 alphabet" {
    const hash = storeDigest("text:sha256:fe9b6355b349291bfdd1c43e9972a3f2c8da199edcf10ee1504797e4da267032:/nix/store:pkg.drv");
    try std.testing.expectEqualStrings("s8l8ca4j8fb6d94205514xd6wf9b57ng", &hash);
    for (hash) |char| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "0123456789abcdfghijklmnpqrsvwxyz", char) != null);
    }
}

test "derivation IR computes minimal Nix paths" {
    var store = DerivationStore.init(std.testing.allocator);
    defer store.deinit();

    var outputs = [_]DrvOutput{.{ .name = "out" }};
    defer if (outputs[0].path.len != 0) std.testing.allocator.free(outputs[0].path);
    var env = [_]EnvVar{
        .{ .name = "builder", .value = "/bin/sh" },
        .{ .name = "name", .value = "pkg" },
        .{ .name = "out", .value = "" },
        .{ .name = "system", .value = "x86_64-linux" },
    };
    var drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const paths = try drv.computePaths(std.testing.allocator, store.resolver());
    defer std.testing.allocator.free(paths.drv_path);
    defer paths.hash_modulo.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/nix/store/s8l8ca4j8fb6d94205514xd6wf9b57ng-pkg.drv", paths.drv_path);
    try std.testing.expectEqualStrings("/nix/store/8w6a3g1mvf8qkz788dysw8k4hmq91cc8-pkg", outputs[0].path);
}

test "output hash parser accepts SRI base64 and Nix base32" {
    const sri = try hashToBase16(std.testing.allocator, "sha256", "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
    defer std.testing.allocator.free(sri);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000000", sri);

    const unpadded_sri = try hashToBase16(std.testing.allocator, "sha256", "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    defer std.testing.allocator.free(unpadded_sri);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000000", unpadded_sri);

    const nix32 = try hashToBase16(std.testing.allocator, "sha1", "s8l8ca4j8fb6d94205514xd6wf9b57ng");
    defer std.testing.allocator.free(nix32);
    try std.testing.expectEqualStrings("cf9eb292e3a675124a0182a466964392288628d2", nix32);

    const colon_prefixed_nix32 = try hashToBase16(std.testing.allocator, "sha1", "sha1:s8l8ca4j8fb6d94205514xd6wf9b57ng");
    defer std.testing.allocator.free(colon_prefixed_nix32);
    try std.testing.expectEqualStrings("cf9eb292e3a675124a0182a466964392288628d2", colon_prefixed_nix32);
}
