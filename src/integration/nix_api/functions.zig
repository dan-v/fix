const std = @import("std");
const fix = @import("../../nix.zig");
const Evaluator = fix.Evaluator;
const value = fix.tooling.runtime.value;
const ValueType = value.ValueType;

test "end-to-end: function arguments are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const unused_arg = try ev.evaluate("let f = x: 1; a = f b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), unused_arg.asInt());

    const guarded_arg = try ev.evaluate("let f = x: if true then 1 else x; a = f b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), guarded_arg.asInt());

    const used_arg = try ev.evaluate("let f = x: x + 1; a = f b; b = 3; in a");
    try std.testing.expectEqual(@as(i64, 4), used_arg.asInt());

    try std.testing.expectError(
        error.RecursiveThunk,
        ev.evaluate("let f = x: x + 1; a = f b; b = a + 1; in a"),
    );
}

test "end-to-end: single argument lambdas" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const direct = try ev.evaluate("(x: x + 1) 41");
    try std.testing.expectEqual(@as(i64, 42), direct.asInt());

    const bound = try ev.evaluate("let inc = x: x + 1; in inc 41");
    try std.testing.expectEqual(@as(i64, 42), bound.asInt());

    const shadowed = try ev.evaluate("(x: (x: x + 1) 41) 0");
    try std.testing.expectEqual(@as(i64, 42), shadowed.asInt());

    const precedence = try ev.evaluate("(x: x) 1 + 2");
    try std.testing.expectEqual(@as(i64, 3), precedence.asInt());

    const repeated_calls = try ev.evaluate("let f = x: x; in (f 1) + (f 2)");
    try std.testing.expectEqual(@as(i64, 3), repeated_calls.asInt());

    const captured = try ev.evaluate("let y = 1; in (x: x + y) 41");
    try std.testing.expectEqual(@as(i64, 42), captured.asInt());

    const functor = try ev.evaluate("let f = { base = 40; __functor = self: x: self.base + x; }; in f 2");
    try std.testing.expectEqual(@as(i64, 42), functor.asInt());

    const returned_functor = try ev.evaluate("let f = { __functor = self: x: x; }; g = { __functor = self: x: f; }; in g 0 42");
    try std.testing.expectEqual(@as(i64, 42), returned_functor.asInt());
}

test "end-to-end: tail calls reuse lambda frames" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const countdown = try ev.evaluate("let f = n: if n == 0 then 42 else f (n - 1); in f 1500");
    try std.testing.expectEqual(@as(i64, 42), countdown.asInt());
}
