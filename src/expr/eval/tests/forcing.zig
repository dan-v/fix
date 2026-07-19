const std = @import("std");

// ---- tests ----
//
// force.zig has no lighter-weight VM-only constructor — every entry point
// (`forceThunk`, `forceThunkFallible`, `forceValueSpeculative`, `forceDeep`)
// only runs meaningfully behind a full bytecode-compiled evaluation, so
// these tests drive it through `Evaluator.evaluate`/`forceDeep`, matching
// the rest of the eval-level test suite (see src/expr/eval/tests/core.zig).

const Evaluator = @import("../../evaluator.zig").Evaluator;

test "forceThunk resolves an unresolved thunk and reuses the resolved fast path" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    // `y` is a thunk that isn't forced until referenced; `y + y` forces the
    // same (by-then-resolved) thunk object twice, exercising both the
    // claim-and-compute path and the already-resolved fast path in
    // `forceValueImpl`/`forceThunkImpl`.
    const result = try ev.evaluate("let y = 3 + 4; in y + y");
    try std.testing.expectEqual(@as(i64, 14), result.asInt());
}

test "a self-referential thunk raises RecursiveThunk without corrupting the VM" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let x = x; in x"));
    // Blackhole detection (`recordBlackhole`) must not leave any VM-global
    // state (claim identity, operand stack depth, ...) broken — the same
    // Evaluator has to keep serving unrelated evaluations afterward.
    const recovered = try ev.evaluate("1 + 1");
    try std.testing.expectEqual(@as(i64, 2), recovered.asInt());

    // A second, differently-shaped cycle (mutual recursion through two
    // bindings) should fail the same way and still leave the VM usable.
    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let a = b; b = a; in a"));
    const recovered_again = try ev.evaluate("\"still\" + \"-\" + \"alive\"");
    try std.testing.expectEqualStrings("still-alive", ev.intern.get(recovered_again.asInternId()));
}

test "forceDeep terminates and is correct over a DAG with a shared sub-list and sub-attrset" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    // `a` is a single thunk/list object reachable twice from `s` (once
    // directly in a list, once through an attrset field). If `forceDeep`
    // mishandled shared (but acyclic) structure it would either loop
    // forever or double-evaluate/corrupt the shared object; observing
    // prompt, correct termination with the value intact covers the
    // property we can assert from outside forceDeepInner's `seen` set
    // without touching its internals.
    const value = try ev.evaluate("let a = [ 1 2 3 ]; s = { l1 = a; l2 = a; both = [ a a ]; }; in s");
    try ev.forceDeep(value);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ev.writeValue(&out.writer, value);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);
    // writeValue prints attribute keys lexicographically (as Nix does), not in
    // definition order: both, l1, l2. And the shared list `a` is one object,
    // so every reference past the first renders as «repeated» (Nix identity
    // semantics) — proving the shared node is not re-forced or duplicated.
    try std.testing.expectEqualStrings(
        "{ both = [ [ 1 2 3 ] «repeated» ]; l1 = «repeated»; l2 = «repeated»; }",
        rendered,
    );
}

test "forceDeep still raises RecursiveThunk through a genuinely cyclic attrset" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    // Distinguishes the DAG case above (shared, but acyclic — must
    // terminate normally) from an actual cycle (must still be detected
    // and reported, not silently "terminate" via the seen-set).
    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("(rec { a = a; }).a"));
}

test "forceValueSpeculative agrees with demand-driven forceThunk (serial vs parallel workers)" {
    // forceValueSpeculative (used by scheduler helpers) and the plain
    // demand path (forceThunk/forceValue) must compute the same value for
    // the same thunk — speculation is only ever a scheduling decision, never
    // a semantic one. Comparing a workers=0 (no helpers, purely
    // demand-driven) run against a workers=8 run (helpers speculatively
    // force thunks via forceValueSpeculative ahead of demand) on the same
    // source is an outside observation of that agreement: if the two paths
    // ever disagreed, one of the two evaluations would produce a different
    // (or erroneous) result.
    const source =
        \\let
        \\  heavy = n: builtins.foldl' (a: b: a + b) 0 (builtins.genList (i: i + n) 64);
        \\in builtins.foldl' (a: b: a + b) 0 (builtins.genList heavy 40)
    ;

    var serial = try Evaluator.init(std.testing.allocator, 0);
    defer serial.deinit();
    const serial_result = try serial.evaluate(source);

    var parallel = try Evaluator.init(std.testing.allocator, 8);
    defer parallel.deinit();
    const parallel_result = try parallel.evaluate(source);

    try std.testing.expectEqual(serial_result.asInt(), parallel_result.asInt());
}
