const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;

test "baseNameOf and dirOf reject non-path non-string arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.baseNameOf 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.dirOf 1"));
}

test "baseNameOf and dirOf preserve the string-ness of their argument" {
    const base_of_path_type = try renderForTest("builtins.typeOf (builtins.baseNameOf /foo/bar)");
    defer std_testing.allocator.free(base_of_path_type);
    try std_testing.expectEqualStrings("\"string\"", base_of_path_type);

    const dir_of_path_type = try renderForTest("builtins.typeOf (builtins.dirOf /foo/bar)");
    defer std_testing.allocator.free(dir_of_path_type);
    try std_testing.expectEqualStrings("\"path\"", dir_of_path_type);

    const dir_of_string_type = try renderForTest("builtins.typeOf (builtins.dirOf \"foo/bar\")");
    defer std_testing.allocator.free(dir_of_string_type);
    try std_testing.expectEqualStrings("\"string\"", dir_of_string_type);
}

test "storePath rejects relative paths" {
    try std_testing.expectError(error.RelativePath, renderForTest("builtins.storePath \"relative/path\""));
}

test "path builtin rejects a relative path attribute" {
    try std_testing.expectError(error.RelativePath, renderForTest("builtins.path { path = \"relative/path\"; }"));
}

test "path builtin rejects a non-string name attribute" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.path { path = /.; name = 1; }"));
}

test "placeholder hashes distinct output names to distinct values" {
    const out = try renderForTest("builtins.placeholder \"out\"");
    defer std_testing.allocator.free(out);
    const dev = try renderForTest("builtins.placeholder \"dev\"");
    defer std_testing.allocator.free(dev);
    try std_testing.expect(!std.mem.eql(u8, out, dev));

    // Deterministic given the same input.
    const out_again = try renderForTest("builtins.placeholder \"out\"");
    defer std_testing.allocator.free(out_again);
    try std_testing.expectEqualStrings(out, out_again);
}
