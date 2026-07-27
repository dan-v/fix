const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "a let-bound name resolves to a local slot" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let x = 41; in x + 1");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "an unbound name is a compile error" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("thisNameIsNotBoundAnywhere"));
}

test "shadowing an outer let binding resolves to the inner one" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let x = 1; in let x = 2; in x");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}

test "a lambda parameter shadows a captured outer binding" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let x = 1; f = x: x + 1; in f 41");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}
