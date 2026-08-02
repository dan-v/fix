const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;
const renderForTest = @import("../test_helpers.zig").renderForTest;

test "add evaluates simple integer arithmetic" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("1 + 2");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "isInt recognizes boxed integers outside the inline range" {
    // Values past i48 are heap-boxed; the language predicate must still see
    // them as ints (sapling's SAPLING_VERSION_HASH env attr is one).
    const result = try renderForTest("builtins.isInt 140737488355328");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("true", result);
}

test "add raises on integer overflow rather than wrapping" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(
        error.IntegerOverflow,
        ev.evaluate("9223372036854775807 + 1"),
    );
}

test "mul raises on integer overflow" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(
        error.IntegerOverflow,
        ev.evaluate("4294967296 * 4294967296"),
    );
}

test "float division by zero raises rather than producing inf or nan" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("1.0 / 0.0"));
}

test "integer division by zero raises" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("1 / 0"));
}

test "floor and ceil saturate to i64 min near the boundary instead of wrapping" {
    // The saturated result doesn't fit the inline-int encoding, so it
    // surfaces as a boxed int; render it to check the observable value
    // without reaching into the encoding directly.
    const floored = try renderForTest("builtins.floor 1.0e100");
    defer std.testing.allocator.free(floored);
    try std.testing.expectEqualStrings("-9223372036854775808", floored);

    const ceiled = try renderForTest("builtins.ceil (0.0 - 1.0e100)");
    defer std.testing.allocator.free(ceiled);
    try std.testing.expectEqualStrings("-9223372036854775808", ceiled);
}

test "floor and ceil pass integers through unchanged" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const floored = try ev.evaluate("builtins.floor 42");
    try std.testing.expectEqual(@as(i64, 42), floored.asInt());

    const ceiled = try ev.evaluate("builtins.ceil (0 - 42)");
    try std.testing.expectEqual(@as(i64, -42), ceiled.asInt());
}

test "bitwise ops on ints" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const anded = try ev.evaluate("builtins.bitAnd 6 3");
    try std.testing.expectEqual(@as(i64, 2), anded.asInt());

    const ored = try ev.evaluate("builtins.bitOr 4 1");
    try std.testing.expectEqual(@as(i64, 5), ored.asInt());

    const xored = try ev.evaluate("builtins.bitXor 6 3");
    try std.testing.expectEqual(@as(i64, 5), xored.asInt());
}

test "bitwise ops reject non-integer operands" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.bitAnd 1.0 2"));
}

test "lessThan compares numbers and strings" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const numeric_lt = try ev.evaluate("builtins.lessThan 1 2");
    try std.testing.expect(numeric_lt.asBool());

    const string_lt = try ev.evaluate("builtins.lessThan \"a\" \"b\"");
    try std.testing.expect(string_lt.asBool());
}
