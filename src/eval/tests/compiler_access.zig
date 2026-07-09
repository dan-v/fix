const std = @import("std");
const Evaluator = @import("../../eval.zig").Evaluator;

test "compiles a nested attribute path access" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("{ a.b.c = 42; }.a.b.c");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "attribute path access reports missing key" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.MissingAttribute, ev.evaluate("{ a.b = 1; }.a.c"));
}

test "attribute or-default returns the default when the path is missing" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const missing = try ev.evaluate("{ a.b = 1; }.a.c or 42");
    try std.testing.expectEqual(@as(i64, 42), missing.asInt());

    const present = try ev.evaluate("{ a.b = 1; }.a.b or 42");
    try std.testing.expectEqual(@as(i64, 1), present.asInt());
}

test "attribute or-default works with a dynamic attribute name" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = \"missing\"; in { a = 1; }.${x} or 99");
    try std.testing.expectEqual(@as(i64, 99), result.asInt());
}
