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

test "a merged dotted let group can reference itself" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // The group's members compile together at the first member's index, so
    // the reference to `a` from the second member must see a's cell.
    const result = try ev.evaluate("let a.x = 41; a.y = a.x + 1; in a.y");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "a dotted let group referencing a later sibling gives it a cell" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // `g` compiles at index 0 and captures `c` before c's slot is filled;
    // c must be cell-bound even though its first textual reference is later.
    const result = try ev.evaluate("let g.a = 1; c = 5; d = c; g.b = c + d; in g.b");
    try std.testing.expectEqual(@as(i64, 10), result.asInt());
}
