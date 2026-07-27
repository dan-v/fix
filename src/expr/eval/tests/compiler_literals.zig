const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "compiles an integer literal to its constant value" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("42");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "compiles a float literal to its constant value" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("3.5");
    try std.testing.expectEqual(@as(f64, 3.5), result.asFloat());
}

test "compiles a string literal to an interned constant" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("\"hello\"");
    try std.testing.expectEqualStrings("hello", ev.intern.get(result.asInternId()));
}

test "compiles a path literal to an interned absolute path" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("/nix/store/example");
    try std.testing.expect(result.isPath());
    try std.testing.expectEqualStrings("/nix/store/example", ev.intern.get(result.asInternId()));
}

test "invalid integer literal is a compile error" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // A literal with digits overflowing i64 fails to parse.
    try std.testing.expectError(error.InvalidNumber, ev.evaluate("99999999999999999999999999999999"));
}
