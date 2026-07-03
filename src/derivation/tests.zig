const std = @import("std");
const derivation = @import("../derivation.zig");
const sort = @import("sort.zig");
const paths_mod = @import("paths.zig");
const types = @import("types.zig");

const DerivationStore = derivation.DerivationStore;
const Drv = derivation.Drv;
const DrvOutput = derivation.DrvOutput;
const DrvInput = derivation.DrvInput;
const EnvVar = derivation.EnvVar;
const hashToBase16 = derivation.hashToBase16;
const storeDigest = derivation.storeDigest;
const outputPathName = derivation.outputPathName;
const drvPathName = derivation.drvPathName;
const hashAlgorithmSeparator = derivation.hashAlgorithmSeparator;
const sha256Hex = paths_mod.sha256Hex;

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

test "sortedOutputs leaves an already-sorted list intact" {
    const outputs = [_]DrvOutput{
        .{ .name = "bin" },
        .{ .name = "dev" },
        .{ .name = "out" },
    };
    const sorted = try sort.sortedOutputs(std.testing.allocator, &outputs);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("bin", sorted[0].name);
    try std.testing.expectEqualStrings("dev", sorted[1].name);
    try std.testing.expectEqualStrings("out", sorted[2].name);
}

test "sortedOutputs fully reorders a reverse-sorted list" {
    const outputs = [_]DrvOutput{
        .{ .name = "out" },
        .{ .name = "dev" },
        .{ .name = "bin" },
    };
    const sorted = try sort.sortedOutputs(std.testing.allocator, &outputs);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("bin", sorted[0].name);
    try std.testing.expectEqualStrings("dev", sorted[1].name);
    try std.testing.expectEqualStrings("out", sorted[2].name);
}

test "sortedInputs orders duplicate paths stably by original relative order" {
    // std.mem.sort documents a stable algorithm (preserves relative order
    // of equal elements), so the two "a-dep.drv" entries must keep their
    // original relative order (dev before out) after sorting.
    const inputs = [_]DrvInput{
        .{ .path = "/nix/store/b-dep.drv", .outputs = &.{"out"} },
        .{ .path = "/nix/store/a-dep.drv", .outputs = &.{"dev"} },
        .{ .path = "/nix/store/a-dep.drv", .outputs = &.{"out"} },
    };
    const sorted = try sort.sortedInputs(std.testing.allocator, &inputs);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("/nix/store/a-dep.drv", sorted[0].path);
    try std.testing.expectEqualStrings("/nix/store/a-dep.drv", sorted[1].path);
    try std.testing.expectEqualStrings("/nix/store/b-dep.drv", sorted[2].path);
    try std.testing.expectEqualStrings("dev", sorted[0].outputs[0]);
    try std.testing.expectEqualStrings("out", sorted[1].outputs[0]);
}

test "sortedEnv fully reorders a reverse-sorted list" {
    const env = [_]EnvVar{
        .{ .name = "system", .value = "x86_64-linux" },
        .{ .name = "out", .value = "" },
        .{ .name = "builder", .value = "/bin/sh" },
    };
    const sorted = try sort.sortedEnv(std.testing.allocator, &env);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("builder", sorted[0].name);
    try std.testing.expectEqualStrings("out", sorted[1].name);
    try std.testing.expectEqualStrings("system", sorted[2].name);
}

test "sortedStrings on an already-sorted list is a no-op" {
    const strings = [_][]const u8{ "a", "b", "c" };
    const sorted = try sort.sortedStrings(std.testing.allocator, &strings);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("a", sorted[0]);
    try std.testing.expectEqualStrings("b", sorted[1]);
    try std.testing.expectEqualStrings("c", sorted[2]);
}

test "sortedStrings fully reorders a reverse-sorted list" {
    const strings = [_][]const u8{ "c", "b", "a" };
    const sorted = try sort.sortedStrings(std.testing.allocator, &strings);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("a", sorted[0]);
    try std.testing.expectEqualStrings("b", sorted[1]);
    try std.testing.expectEqualStrings("c", sorted[2]);
}

test "sortedStrings preserves all entries when duplicates are present" {
    const strings = [_][]const u8{ "dup", "a", "dup" };
    const sorted = try sort.sortedStrings(std.testing.allocator, &strings);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("a", sorted[0]);
    try std.testing.expectEqualStrings("dup", sorted[1]);
    try std.testing.expectEqualStrings("dup", sorted[2]);
}

test "sha256Hex matches an independently-computed digest" {
    // Verified via: printf 'hello' | sha256sum
    const digest = try sha256Hex(std.testing.allocator, "hello");
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", digest);
}

test "sha256Hex of the empty string matches the well-known empty digest" {
    // Verified via: printf '' | sha256sum
    const digest = try sha256Hex(std.testing.allocator, "");
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", digest);
}

test "hashToBase16 accepts a plain hex digest unchanged" {
    const hex = try hashToBase16(std.testing.allocator, "sha256", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    defer std.testing.allocator.free(hex);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hex);
}

test "hashToBase16 rejects a mismatched algorithm prefix" {
    try std.testing.expectError(
        error.InvalidHashAlgorithm,
        hashToBase16(std.testing.allocator, "sha256", "sha1:s8l8ca4j8fb6d94205514xd6wf9b57ng"),
    );
}

test "outputPathName uses the bare derivation name for the default output" {
    const name = try outputPathName(std.testing.allocator, "pkg", "out");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("pkg", name);
}

test "outputPathName suffixes non-default outputs with the output name" {
    const name = try outputPathName(std.testing.allocator, "pkg", "dev");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("pkg-dev", name);
}

test "drvPathName appends the .drv extension" {
    const name = try drvPathName(std.testing.allocator, "pkg");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("pkg.drv", name);
}

test "hashAlgorithmSeparator finds a colon separator" {
    try std.testing.expectEqual(@as(?usize, 4), hashAlgorithmSeparator("sha1:s8l8ca4j8fb6d94205514xd6wf9b57ng"));
}

test "hashAlgorithmSeparator finds a dash separator" {
    try std.testing.expectEqual(@as(?usize, 6), hashAlgorithmSeparator("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

test "hashAlgorithmSeparator picks whichever separator occurs first" {
    // A dash appears before the colon here, so it wins.
    try std.testing.expectEqual(@as(?usize, 4), hashAlgorithmSeparator("sha1-abc:def"));
}

test "hashAlgorithmSeparator returns null when neither separator is present" {
    try std.testing.expectEqual(@as(?usize, null), hashAlgorithmSeparator("s8l8ca4j8fb6d94205514xd6wf9b57ng"));
}

test "toATerm produces valid ATerm syntax with fields in Derive() order" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "/nix/store/xxx-pkg", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{
        .{ .name = "builder", .value = "/bin/sh" },
        .{ .name = "out", .value = "/nix/store/xxx-pkg" },
    };
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{ "-c", "true" },
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, false, null);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "Derive("));
    try std.testing.expect(std.mem.endsWith(u8, text, ")"));

    // Field order per the ATerm grammar: outputs, input drvs, input srcs,
    // system, builder, args, env.
    const outputs_pos = std.mem.indexOf(u8, text, "[(\"out\",\"/nix/store/xxx-pkg\",\"\",\"\")]").?;
    const srcs_and_system_pos = std.mem.indexOf(u8, text, "],[],\"x86_64-linux\",\"/bin/sh\"").?;
    const args_pos = std.mem.indexOf(u8, text, "[\"-c\",\"true\"]").?;
    const env_pos = std.mem.indexOf(u8, text, "[(\"builder\",\"/bin/sh\"),(\"out\",\"/nix/store/xxx-pkg\")]").?;

    try std.testing.expect(outputs_pos < srcs_and_system_pos);
    try std.testing.expect(srcs_and_system_pos < args_pos);
    try std.testing.expect(args_pos < env_pos);
}

test "toATerm masks output paths and their matching env values when requested" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "/nix/store/xxx-pkg", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{.{ .name = "out", .value = "/nix/store/xxx-pkg" }};
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, true, null);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "Derive("));
    try std.testing.expect(std.mem.indexOf(u8, text, "/nix/store/xxx-pkg") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(\"out\",\"\",\"\",\"\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(\"out\",\"\")") != null);
}

test "toATerm escapes special characters in quoted string values" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{.{ .name = "script", .value = "echo \"hi\"\n\tnext\\line" }};
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, false, null);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "echo \\\"hi\\\"\\n\\tnext\\\\line") != null);
}

test "toATerm uses actual_inputs override instead of drv.input_drvs when supplied" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{};
    const original_inputs = [_]DrvInput{.{ .path = "/nix/store/original.drv", .outputs = &.{"out"} }};
    const override_inputs = [_]DrvInput{.{ .path = "/nix/store/override.drv", .outputs = &.{"out"} }};
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &original_inputs,
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, false, &override_inputs);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "override.drv") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "original.drv") == null);
}
