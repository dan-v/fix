const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;

test "tryEval catches thrown errors but not arbitrary Zig errors" {
    const caught_throw = try renderForTest("(builtins.tryEval (builtins.throw \"boom\")).success");
    defer std_testing.allocator.free(caught_throw);
    try std_testing.expectEqualStrings("false", caught_throw);

    const caught_abort = try renderForTest("(builtins.tryEval (builtins.abort \"boom\")).success");
    defer std_testing.allocator.free(caught_abort);
    try std_testing.expectEqualStrings("false", caught_abort);

    // Division by zero is not one of tryEval's caught kinds — it propagates.
    try std_testing.expectError(error.DivisionByZero, renderForTest("builtins.tryEval (1 / 0)"));
}

test "tryEval on success reports the forced value" {
    const success = try renderForTest("(builtins.tryEval 42).value");
    defer std_testing.allocator.free(success);
    try std_testing.expectEqualStrings("42", success);
}

test "addErrorContext returns the value on success and rethrows the original error on failure" {
    const success = try renderForTest("builtins.addErrorContext \"context\" 42");
    defer std_testing.allocator.free(success);
    try std_testing.expectEqualStrings("42", success);

    try std_testing.expectError(error.NixThrow, renderForTest("builtins.addErrorContext \"context\" (builtins.throw \"boom\")"));
}

test "trace forces the message and returns the value unchanged" {
    const traced = try renderForTest("builtins.trace \"msg\" 42");
    defer std_testing.allocator.free(traced);
    try std_testing.expectEqualStrings("42", traced);

    try std_testing.expectError(error.NixThrow, renderForTest("builtins.trace (builtins.throw \"boom\") 42"));
}
