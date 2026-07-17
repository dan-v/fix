const std = @import("std");
const fix = @import("../../nix.zig");
const Evaluator = fix.Evaluator;
const value = fix.tooling.runtime.value;
const ValueType = value.ValueType;

test "end-to-end: eager let-elision preserves error order under tryEval (§G)" {
    // Must-force eager elision must not hoist a binding's evaluation ahead of
    // the body's first demand — doing so reorders which error surfaces, which
    // is observable under `builtins.tryEval` (caught `throw` vs uncaught
    // `div 1 0`). Only the first-demanded binding may be elided. Verified
    // against the Lix oracle. See strictness.firstForcedName / compileLetIn.
    const alloc = std.testing.allocator;
    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    // Body forces `b` (uncaught div-by-zero) FIRST → the error propagates,
    // tryEval does NOT catch it → the whole eval errors.
    try std.testing.expectError(
        error.DivisionByZero,
        ev.evaluate("builtins.tryEval (let a = throw \"A\"; b = builtins.div 1 0; in b + a)"),
    );

    // Body forces `a` (caught throw) FIRST → tryEval catches it →
    // `{ success = false; value = false; }` (a resolved value, not an error).
    const caught = try ev.evaluate("builtins.tryEval (let a = throw \"A\"; b = builtins.div 1 0; in a + b)");
    try std.testing.expect(caught.isAttrs());

    // Three bindings, uncaught demanded first among them → propagates.
    try std.testing.expectError(
        error.DivisionByZero,
        ev.evaluate("builtins.tryEval (let a = throw \"A\"; b = throw \"B\"; c = builtins.div 1 0; in c + b + a)"),
    );
}

test "end-to-end: let binding" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = 10; y = 32; in x + y");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());

    const right_operand = try ev.evaluate("1 + (let x = 2; in x)");
    try std.testing.expectEqual(@as(i64, 3), right_operand.asInt());

    const left_operand = try ev.evaluate("(let x = 2; in x) + 1");
    try std.testing.expectEqual(@as(i64, 3), left_operand.asInt());

    const attr_path = try ev.evaluate("let a.b = 1; in a.b");
    try std.testing.expectEqual(@as(i64, 1), attr_path.asInt());

    const nested_attr_path = try ev.evaluate("let a.b.c = 2; in a.b.c");
    try std.testing.expectEqual(@as(i64, 2), nested_attr_path.asInt());

    const recursive_attr_path = try ev.evaluate("let a.b = a.c; a.c = 3; in a.b");
    try std.testing.expectEqual(@as(i64, 3), recursive_attr_path.asInt());

    const extended_attr_path = try ev.evaluate("let a.b = { c = 1; }; a.b.d = 2; in a.b.d");
    try std.testing.expectEqual(@as(i64, 2), extended_attr_path.asInt());
}

test "end-to-end: duplicate let bindings are rejected" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("let x = 1; x = 2; in x"));
    try std.testing.expectError(error.ParseError, ev.evaluate("let x = 1; inherit x; in x"));
    try std.testing.expectError(error.ParseError, ev.evaluate("let inherit ({ x = 1; }) x; x = 2; in x"));
    try std.testing.expectError(error.ParseError, ev.evaluate("let or = 1; inherit ({ or = 2; }) or; in ({ inherit or; }).or"));
    try std.testing.expectError(error.ParseError, ev.evaluate("let a = 1; a.b = 2; in a"));
    try std.testing.expectError(error.ParseError, ev.evaluate("let a.b = 1; a.b.c = 2; in a.b"));
}

test "end-to-end: undefined variables are rejected with source diagnostics" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("x"));
    try std.testing.expectEqual(@as(usize, 1), ev.getDiagnostics().len);
    try std.testing.expectEqualStrings("undefined variable 'x'", ev.getDiagnostics()[0].message);
    try std.testing.expectEqual(@as(u32, 0), ev.getDiagnostics()[0].offset);

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("{ inherit x; }"));
    try std.testing.expectEqual(@as(usize, 1), ev.getDiagnostics().len);
    try std.testing.expectEqualStrings("undefined variable 'x'", ev.getDiagnostics()[0].message);
    try std.testing.expectEqual(@as(u32, 10), ev.getDiagnostics()[0].offset);
}

test "end-to-end: let forward references" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let a = b + 1; b = 3; in a + b");
    try std.testing.expectEqual(@as(i64, 7), result.asInt());
}

test "end-to-end: unused let binding is not evaluated" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = 1 / 0; in 42");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "end-to-end: recursive let binding errors" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let a = a; in a"));
    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let a = b; b = a; in a"));
}

test "end-to-end: guarded recursive let bindings can terminate" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const true_guard = try ev.evaluate("let a = if true then 1 else b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), true_guard.asInt());

    const false_guard = try ev.evaluate("let a = if false then b else 1; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), false_guard.asInt());
}

test "end-to-end: inherit quoted attribute from source" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = { \"or\" = 1; }; in { inherit (x) \"or\"; }.\"or\"");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "end-to-end: inherit from source expression" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const inherited = try ev.evaluate("let src = { x = 7; y = 8; }; in ({ inherit (src) x y; }).x");
    try std.testing.expectEqual(@as(i64, 7), inherited.asInt());

    const literal_source = try ev.evaluate("({ inherit ({ x = 1; }) x; }).x");
    try std.testing.expectEqual(@as(i64, 1), literal_source.asInt());

    const lazy = try ev.evaluate("let src = 1 / 0; in { inherit (src) x; }");
    try std.testing.expectEqual(value.ValueType.attrs, lazy.kind());
}

test "end-to-end: inherit in let bindings" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const outer = try ev.evaluate("let x = 1; in let inherit x; in x");
    try std.testing.expectEqual(@as(i64, 1), outer.asInt());

    const sourced = try ev.evaluate("let inherit ({ x = 2; }) x; in x");
    try std.testing.expectEqual(@as(i64, 2), sourced.asInt());

    const contextual_or = try ev.evaluate("let inherit ({ or = 4; }) or; in ({ inherit or; }).or");
    try std.testing.expectEqual(@as(i64, 4), contextual_or.asInt());

    const lazy_source = try ev.evaluate("let src = 1 / 0; inherit (src) x; in { inherit x; }");
    try std.testing.expectEqual(value.ValueType.attrs, lazy_source.kind());
}

test "end-to-end: with expressions" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const simple = try ev.evaluate("with { x = 40; y = 2; }; x + y");
    try std.testing.expectEqual(@as(i64, 42), simple.asInt());

    const lexical_shadow = try ev.evaluate("let x = 1; in with { x = 2; }; x");
    try std.testing.expectEqual(@as(i64, 1), lexical_shadow.asInt());

    const nested_shadow = try ev.evaluate("with { x = 1; }; with { x = 2; }; x");
    try std.testing.expectEqual(@as(i64, 2), nested_shadow.asInt());

    const outer_fallback = try ev.evaluate("with { x = 1; }; with { y = 2; }; x + y");
    try std.testing.expectEqual(@as(i64, 3), outer_fallback.asInt());

    const escaped_lambda = try ev.evaluate("let f = with { x = 41; }; y: x + y; in f 1");
    try std.testing.expectEqual(@as(i64, 42), escaped_lambda.asInt());

    const escaped_attr_thunk = try ev.evaluate("let a = with { x = 42; }; { y = x; }; in a.y");
    try std.testing.expectEqual(@as(i64, 42), escaped_attr_thunk.asInt());

    const lazy_unused_scope = try ev.evaluate("with (1 / 0); 42");
    try std.testing.expectEqual(@as(i64, 42), lazy_unused_scope.asInt());

    const lazy_unused_attr = try ev.evaluate("with { x = 42; y = 1 / 0; }; x");
    try std.testing.expectEqual(@as(i64, 42), lazy_unused_attr.asInt());

    const operand_position = try ev.evaluate("1 + (with { x = 2; }; x)");
    try std.testing.expectEqual(@as(i64, 3), operand_position.asInt());

    try std.testing.expectError(error.TypeError, ev.evaluate("with 1; x"));
}
