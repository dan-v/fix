const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;

test "hasAttr and getAttr reject non-attrs and non-string names" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.hasAttr \"a\" 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.hasAttr 1 { a = 1; }"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.getAttr \"a\" 1"));
}

test "getAttr on a missing name raises rather than returning null" {
    try std_testing.expectError(error.MissingAttribute, renderForTest("builtins.getAttr \"missing\" { a = 1; }"));
}

test "zipAttrsWith unions keys across mismatched attribute sets" {
    const names = try renderForTest("builtins.attrNames (builtins.zipAttrsWith (name: values: values) [ { a = 1; } { b = 2; } { a = 3; c = 4; } ])");
    defer std_testing.allocator.free(names);
    try std_testing.expectEqualStrings("[ \"a\" \"b\" \"c\" ]", names);

    const a_values = try renderForTest("builtins.length ((builtins.zipAttrsWith (name: values: values) [ { a = 1; } { b = 2; } { a = 3; c = 4; } ]).a)");
    defer std_testing.allocator.free(a_values);
    try std_testing.expectEqualStrings("2", a_values);

    const c_values = try renderForTest("builtins.length ((builtins.zipAttrsWith (name: values: values) [ { a = 1; } { b = 2; } { a = 3; c = 4; } ]).c)");
    defer std_testing.allocator.free(c_values);
    try std_testing.expectEqualStrings("1", c_values);
}

test "zipAttrsWith and catAttrs reject non-attrs list elements" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.zipAttrsWith (name: values: values) [ 1 ]"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.catAttrs \"a\" [ 1 ]"));
}

test "attrNames and attrValues on an empty attrset" {
    const names = try renderForTest("builtins.attrNames { }");
    defer std_testing.allocator.free(names);
    try std_testing.expectEqualStrings("[ ]", names);

    const values = try renderForTest("builtins.attrValues { }");
    defer std_testing.allocator.free(values);
    try std_testing.expectEqualStrings("[ ]", values);
}

test "functionArgs rejects non-function values" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.functionArgs 1"));
}

test "functionArgs on builtins and partial applications reports no formal args" {
    const builtin_args = try renderForTest("builtins.functionArgs builtins.head");
    defer std_testing.allocator.free(builtin_args);
    try std_testing.expectEqualStrings("{ }", builtin_args);

    const partial_args = try renderForTest("builtins.functionArgs (builtins.elemAt [ 1 ])");
    defer std_testing.allocator.free(partial_args);
    try std_testing.expectEqualStrings("{ }", partial_args);
}

test "unsafeGetAttrPos returns null for a missing attribute" {
    const result = try renderForTest("builtins.unsafeGetAttrPos \"missing\" { a = 1; }");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("null", result);
}

test "removeAttrs and intersectAttrs reject non-attrs and non-list arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.removeAttrs 1 [ \"a\" ]"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.removeAttrs { a = 1; } 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.intersectAttrs 1 { a = 1; }"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.intersectAttrs { a = 1; } 1"));
}

test "removeAttrs and intersectAttrs on empty attrsets" {
    const removed = try renderForTest("builtins.removeAttrs { } [ \"a\" ]");
    defer std_testing.allocator.free(removed);
    try std_testing.expectEqualStrings("{ }", removed);

    const intersected = try renderForTest("builtins.intersectAttrs { } { a = 1; }");
    defer std_testing.allocator.free(intersected);
    try std_testing.expectEqualStrings("{ }", intersected);
}
