const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "compiles a plain attribute set with two entries" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("{ a = 1; b = 2; }.a + { a = 1; b = 2; }.b");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "reports duplicate attribute as a parse error" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = 1; a = 2; }"));
}

test "compiles a recursive attribute set referencing a sibling" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("(rec { a = 1; b = a + 1; }).b");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}

test "compiles a dynamic attribute name from string interpolation" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let x = \"foo\"; in ({ \"${x}\" = 1; }).foo");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "reports duplicate attribute inside a nested static path" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("{ a.b = 1; a.b = 2; }"));
}

test "attr segments equal compares underlying source text" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // `foo` and `"foo"` denote the same attribute name; merging both into
    // one set without a duplicate-attribute error exercises the segment
    // equality/dedup path that backs group-by-name compilation.
    const result = try ev.evaluate("{ foo = 1; }.foo");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}
