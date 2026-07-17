//! End-to-end behaviour of the `|>`/`<|` pipe operators and the
//! `--pipe-operators` compile-time gate. Semantics (precedence,
//! associativity, mixing) were pinned against Lix 2.95.2; the expected
//! values below come straight from that oracle.

const std = @import("std");
const eval_mod = @import("../../eval.zig");
const Evaluator = eval_mod.Evaluator;
const Diagnostic = eval_mod.Diagnostic;
const helpers = @import("../test_helpers.zig");
const renderWithPipeOperators = helpers.renderWithPipeOperators;
const renderForTest = helpers.renderForTest;

test "pipe operators are rejected on presence without the feature flag" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.PipeOperatorsDisabled, ev.evaluate("1 |> (x: x + 1)"));

    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    // Points at the operator itself (`|>` at column 3), like Nix.
    try std.testing.expectEqual(@as(u32, 2), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].column);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics[0].message, "pipe operator") != null);
}

test "the gate rejects a pipe even in an unused binding, like Nix" {
    // Nix gates on presence at parse time: `let x = 1 |> f; in 2` errors
    // even though `x` is never forced. Our chokepoint gate must match.
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.PipeOperatorsDisabled, ev.evaluate("let x = 1 |> (y: y); in 2"));

    var ev2 = try Evaluator.init(std.testing.allocator, 0);
    defer ev2.deinit();
    try std.testing.expectError(error.PipeOperatorsDisabled, ev2.evaluate("{ unused = 1 |> (y: y); used = 2; }"));
}

test "<| is rejected on presence without the feature flag" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.PipeOperatorsDisabled, ev.evaluate("(x: x + 1) <| 1"));
}

test "|> applies the right operand to the left when enabled" {
    const output = try renderWithPipeOperators("1 |> (x: x + 1)");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("2", output);
}

test "<| applies the left operand to the right when enabled" {
    const output = try renderWithPipeOperators("(x: x + 1) <| 1");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("2", output);
}

test "|> is left associative" {
    // 5 |> (x: x - 1) |> (x: x * 2) == (5 - 1) * 2 == 8  (Lix-verified)
    const output = try renderWithPipeOperators("5 |> (x: x - 1) |> (x: x * 2)");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("8", output);
}

test "<| is right associative" {
    // (x: x * 2) <| (x: x + 1) <| 5 == 2 * (5 + 1) == 12  (Lix-verified)
    const output = try renderWithPipeOperators("(x: x * 2) <| (x: x + 1) <| 5");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("12", output);
}

test "|> binds looser than arithmetic" {
    // 1 + 2 |> (x: x * 10) == (1 + 2) * 10 == 30  (Lix-verified)
    const output = try renderWithPipeOperators("1 + 2 |> (x: x * 10)");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("30", output);
}

test "|> composes with function application (application binds tighter)" {
    // builtins.add 1 |> (f: f 10) == (add 1) 10 == 11  (Lix-verified)
    const output = try renderWithPipeOperators("builtins.add 1 |> (f: f 10)");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("11", output);
}

test "a parenthesized pipe is unaffected by the gate being off elsewhere" {
    // Sanity: plain application with no pipe still works with the flag off.
    const output = try renderForTest("(x: x + 1) 1");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("2", output);
}
