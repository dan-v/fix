const std = @import("std");
const Evaluator = @import("../../eval.zig").Evaluator;

test "if-else selects the matching branch" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const then_arm = try ev.evaluate("if 1 == 1 then \"yes\" else \"no\"");
    try std.testing.expectEqualStrings("yes", ev.intern.get(then_arm.asInternId()));

    const else_arm = try ev.evaluate("if 1 == 2 then \"yes\" else \"no\"");
    try std.testing.expectEqualStrings("no", ev.intern.get(else_arm.asInternId()));
}

test "assert passes through the body when the condition holds" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("assert 1 + 1 == 2; 42");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "assert raises an error when the condition fails" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.AssertionFailed, ev.evaluate("assert 1 == 2; 42"));
}

test "with brings an attribute set's names into scope" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("with { a = 1; b = 2; }; a + b");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "an inner with shadows an outer with for the same name" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("with { a = 1; }; with { a = 2; }; a");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}
