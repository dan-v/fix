const std = @import("std");
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");

pub fn builtinThrow(self: anytype, message_arg: Value) !Value {
    try vm_trace.setErrorMessage(self, try strings.stringArg(self, message_arg));
    return error.NixThrow;
}

pub fn builtinAbort(self: anytype, message_arg: Value) !Value {
    try vm_trace.setErrorMessage(self, try strings.stringArg(self, message_arg));
    return error.NixAbort;
}

pub fn builtinTryEval(self: anytype, arg: Value) !Value {
    const value = vm_force.forceValue(self, arg) catch |err| switch (err) {
        error.NixThrow,
        error.NixAbort,
        error.AssertionFailed,
        error.FileNotFound,
        => {
            vm_trace.clearErrorTrace(self);
            return tryEvalResult(self, false, Value.boolVal(false));
        },
        else => return err,
    };
    return tryEvalResult(self, true, value);
}

pub fn builtinAddErrorContext(self: anytype, message_arg: Value, value_arg: Value) !Value {
    return vm_force.forceValue(self, value_arg) catch |err| {
        const message = strings.stringArg(self, message_arg) catch return err;
        vm_trace.pushErrorContext(self, message) catch return err;
        return err;
    };
}

pub fn builtinTrace(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try vm_force.forceValue(self, message_arg);
    return vm_force.forceValue(self, value_arg);
}

pub fn builtinTraceVerbose(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try vm_force.forceValue(self, message_arg);
    return vm_force.forceValue(self, value_arg);
}

pub fn tryEvalResult(self: anytype, success: bool, value: Value) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("success"),
            .value = Value.boolVal(success),
        },
        .{
            .name = try self.intern.intern("value"),
            .value = value,
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

const std_testing = std.testing;
const renderForTest = @import("../../eval/test_helpers.zig").renderForTest;

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
