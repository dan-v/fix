const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;

test "scopedImport rejects a non-attrs scope before touching the filesystem" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.scopedImport 1 /nonexistent-path-for-type-check.nix"));
}

test "findFile raises when no search path entry matches" {
    try std_testing.expectError(error.FileNotFound, renderForTest("builtins.findFile [ { prefix = \"pkg\"; path = /nonexistent-search-root; } ] \"other/target.nix\""));
}

test "findFile rejects a non-list search path" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.findFile 1 \"pkg/target.nix\""));
}
