const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "a lambda body returning a bare local evaluates correctly" {
    // Exercises the loc_get/loc_get_ret fusion in emitRet.
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("(x: x) 42");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "a lambda body returning a captured upvalue evaluates correctly" {
    // Exercises the up_get/up_get_ret fusion in emitRet.
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let y = 7; in (x: y) 0");
    try std.testing.expectEqual(@as(i64, 7), result.asInt());
}

test "chained attribute access through an upvalue evaluates correctly" {
    // Exercises the up_get/up_get_attr fusion in emitGetAttr.
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let pkg = { name = \"foo\"; }; in (x: pkg.name) 0");
    try std.testing.expectEqualStrings("foo", ev.intern.get(result.asInternId()));
}

test "an if-else whose branches join at the tail evaluates both arms correctly" {
    // Exercises patchJump's tail-join detection (dropping the fusion hint
    // when a jump target lands at the current write position).
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const then_arm = try ev.evaluate("if true then 1 else 2");
    try std.testing.expectEqual(@as(i64, 1), then_arm.asInt());

    const else_arm = try ev.evaluate("if false then 1 else 2");
    try std.testing.expectEqual(@as(i64, 2), else_arm.asInt());
}
