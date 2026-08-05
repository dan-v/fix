const std = @import("std");

// ---- tests ----
//
// closures.zig, like force.zig, has no VM-only constructor lighter than a
// full compiled evaluation — `makeClosure`/`makeClosureFromCaptures` only
// run from bytecode emitted for real lambda expressions, and `doCall`/
// `doCallN` only make sense against a real callee value. These drive the
// module through `Engine.evaluate`, observing Nix-visible results only.

const Engine = @import("../../evaluator.zig").Engine;

test "makeClosure with zero upvalues ignores the enclosing scope" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // `x: x + 1` captures nothing from `y` even though `y` is in scope;
    // a zero-upvalue closure must still work as a plain callable value.
    const result = try ev.evaluate("let y = 100; f = x: x + 1; in f 41");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "makeClosure with one upvalue captures the binding, not a slot to re-read later" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let y = 10; f = x: x + y; in f 5");
    try std.testing.expectEqual(@as(i64, 15), result.asInt());
}

test "makeClosureFromCaptures with multiple upvalues (mixed local and outer-upvalue descriptors)" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // The innermost lambda's captures mix a descriptor resolved against the
    // enclosing frame's locals (`b`) and one resolved against the enclosing
    // closure's own upvalues (`a`, captured one level further out) —
    // exercising both descriptor kinds `stageCaptureDescriptors` handles.
    const result = try ev.evaluate(
        \\let
        \\  a = 1;
        \\in
        \\  (b: c: (x: a + b + c + x)) 2 3 4
    );
    try std.testing.expectEqual(@as(i64, 10), result.asInt());
}

test "a closure captures its upvalue's value at creation time, unaffected by a later shadow" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // `f` is created while `x = 1` is the visible binding for `x`; the
    // inner `let x = 2; in f null` rebinds `x` in a *nested* scope after
    // `f` already exists. Nix has no mutation, so "rebind after creation"
    // is expressed as scope shadowing — if `makeClosureFromCaptures`
    // captured a re-readable reference (e.g. a stack slot) instead of the
    // value/thunk visible at creation time, `f null` would incorrectly
    // observe `2`.
    const result = try ev.evaluate("let x = 1; f = (_: x); in let x = 2; in f null");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "capture-free lambdas are immediate functions while captured lambdas use heap closures" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const plain = try ev.evaluate("x: x");
    try std.testing.expect(plain.isFunction());
    try std.testing.expect(!plain.isClosure());

    const attrs = try ev.evaluate("{ x }: x");
    try std.testing.expect(attrs.isFunction());

    // The capture must not be a literal-shaped binding: let-float inlines a
    // literal `let y = 1;` into the body, making the lambda capture-free. A
    // computed RHS used under a lambda (a many-region) never moves, so the
    // binding keeps its slot and the lambda genuinely captures it.
    const captured = try ev.evaluate("let y = 1 + 0; in x: x + y");
    try std.testing.expect(captured.isClosure());
    try std.testing.expect(!captured.isFunction());

    const applied = try ev.evaluate("(x: x + 1) 4");
    try std.testing.expectEqual(@as(i64, 5), applied.asInt());
}

test "doCall/doCallN: a curried multi-arg lambda is callable after a partial application" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // `f 1` under-applies a 3-arg uncurried chunk, producing a partial
    // application value that must still be callable (doCall's
    // `applyToPartial` / doCallN's PAP-extension path) rather than a
    // final result.
    const g = try ev.evaluate("let f = a: b: c: a + b + c; in builtins.isFunction (f 1)");
    try std.testing.expectEqual(true, g.asBool());

    // Applying the remaining two args (as a single call_n site — `g 2 3`)
    // must saturate and actually run the body, not produce a further PAP.
    const still_partial = try ev.evaluate("let f = a: b: c: a + b + c; g = f 1; in builtins.isFunction (g 2)");
    try std.testing.expectEqual(true, still_partial.asBool());

    const result = try ev.evaluate("let f = a: b: c: a + b + c; g = f 1; in g 2 3");
    try std.testing.expectEqual(@as(i64, 6), result.asInt());

    // Fully saturating in one call expression exercises the `doCallN`
    // saturated fast path directly (arity == n, no intermediate PAP at all).
    const direct = try ev.evaluate("(a: b: c: a + b + c) 1 2 3");
    try std.testing.expectEqual(@as(i64, 6), direct.asInt());
}
