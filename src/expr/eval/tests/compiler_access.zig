const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "compiles a nested attribute path access" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("{ a.b.c = 42; }.a.b.c");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "attribute path access reports missing key" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.MissingAttribute, ev.evaluate("{ a.b = 1; }.a.c"));
}

test "attribute or-default returns the default when the path is missing" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const missing = try ev.evaluate("{ a.b = 1; }.a.c or 42");
    try std.testing.expectEqual(@as(i64, 42), missing.asInt());

    const present = try ev.evaluate("{ a.b = 1; }.a.b or 42");
    try std.testing.expectEqual(@as(i64, 1), present.asInt());
}

test "attribute or-default works with a dynamic attribute name" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let x = \"missing\"; in { a = 1; }.${x} or 99");
    try std.testing.expectEqual(@as(i64, 99), result.asInt());
}

test "or-default covers a miss anywhere in a path with a dynamic segment" {
    // Regression: the `or` default must catch a missing attr at ANY position,
    // even when a dynamic `${...}` sits earlier in the select path (the whole
    // path is compiled as one fallback, not just the outer static tail).
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // Missing attr with the dynamic segment in the middle / first / last.
    const mid = try ev.evaluate("{ x = 1; }.a.${\"b\"}.c or 7");
    try std.testing.expectEqual(@as(i64, 7), mid.asInt());
    const first = try ev.evaluate("{ x = 1; }.${\"a\"}.b or 7");
    try std.testing.expectEqual(@as(i64, 7), first.asInt());
    const last = try ev.evaluate("{ x = 1; }.missing.${\"b\"} or 7");
    try std.testing.expectEqual(@as(i64, 7), last.asInt());

    // Present paths with a dynamic segment must still select the value.
    const present_mid = try ev.evaluate("{ a.b.c = 5; }.a.${\"b\"}.c or 7");
    try std.testing.expectEqual(@as(i64, 5), present_mid.asInt());
    const present_first = try ev.evaluate("{ a.b = 8; }.${\"a\"}.b or 7");
    try std.testing.expectEqual(@as(i64, 8), present_first.asInt());
    const present_dynamic = try ev.evaluate("{ k = 9; }.${\"k\"} or 7");
    try std.testing.expectEqual(@as(i64, 9), present_dynamic.asInt());
}
