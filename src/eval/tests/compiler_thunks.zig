const std = @import("std");
const Evaluator = @import("../../eval.zig").Evaluator;

test "an unforced let binding thunk never evaluates its erroring body" {
    // `compileThunk` defers the body; if `b` were compiled/run eagerly,
    // the division by zero would raise before `a` is even returned.
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let a = 1; b = 1 / 0; in a");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "a strict let binding is still forced exactly to its value" {
    // Exercises the eager-thunk path (`compileThunkEager`) taken when
    // strictness analysis shows the binding is used unconditionally.
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let a = 1 + 1; in a + a");
    try std.testing.expectEqual(@as(i64, 4), result.asInt());
}

test "function call arguments are compiled as adaptive apply-arg thunks" {
    // Exercises `compileApplyArgThunk`: the callee decides thunk-vs-eager
    // at runtime, but either way an unused argument must stay lazy...
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const unused = try ev.evaluate("(x: 1) (1 / 0)");
    try std.testing.expectEqual(@as(i64, 1), unused.asInt());

    // ...and a used argument must still evaluate to the right value.
    const used = try ev.evaluate("(x: x + 1) 41");
    try std.testing.expectEqual(@as(i64, 42), used.asInt());
}
