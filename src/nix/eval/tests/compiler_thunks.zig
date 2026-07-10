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

test "fused thunk+store let bindings publish through their cells correctly" {
    // Non-lambda let bindings with forward references compile as a
    // thunk-family op immediately followed by a cell store, which
    // `emit.fuseStoreToSlot` rewrites into the fused `thunk(_eag)_st_cell`
    // forms (the trailing-slot-byte encoding). The values must round-trip
    // through the cells exactly as if unfused.
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let a = b + 1; b = c + 1; c = 40; in a");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "a fused-store thunk that is never forced stays lazy" {
    // Fusion must not change laziness: the thunk is published into its
    // slot unevaluated, so an erroring unused binding never detonates.
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let used = 2; unused = (1 / 0) + used; in used");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
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
