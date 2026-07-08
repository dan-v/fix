//! Nix arithmetic and numeric-comparison builtins: add/sub/mul/div, the
//! bitwise ops, floor/ceil, and lessThan.

const Value = @import("runtime").value.Value;
const numeric = @import("runtime").numeric;
const vm_force = @import("../force.zig");
const vm_equality = @import("../equality.zig");

pub fn builtinAdd(self: anytype, left: Value, right: Value) !Value {
    return numeric.add(self.heap, try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinSub(self: anytype, left: Value, right: Value) !Value {
    return numeric.sub(self.heap, try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinMul(self: anytype, left: Value, right: Value) !Value {
    return numeric.mul(self.heap, try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinDiv(self: anytype, left: Value, right: Value) !Value {
    return numeric.div(self.heap, try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinLessThan(self: anytype, left: Value, right: Value) !Value {
    return Value.boolVal(try vm_equality.compareValues(self, left, right) == .lt);
}

pub fn builtinBitAnd(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitAnd(self.heap, try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinBitOr(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitOr(self.heap, try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinBitXor(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitXor(self.heap, try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinFloor(self: anytype, arg: Value) !Value {
    return numeric.floor(self.heap, try vm_force.forceValue(self, arg));
}

pub fn builtinCeil(self: anytype, arg: Value) !Value {
    return numeric.ceil(self.heap, try vm_force.forceValue(self, arg));
}

const std = @import("std");
const Evaluator = @import("../../eval.zig").Evaluator;
const renderForTest = @import("../../eval/test_helpers.zig").renderForTest;

test "add evaluates simple integer arithmetic" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    const result = try ev.evaluate("1 + 2");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "add raises on integer overflow rather than wrapping" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(
        error.IntegerOverflow,
        ev.evaluate("9223372036854775807 + 1"),
    );
}

test "mul raises on integer overflow" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(
        error.IntegerOverflow,
        ev.evaluate("4294967296 * 4294967296"),
    );
}

test "float division by zero raises rather than producing inf or nan" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("1.0 / 0.0"));
}

test "integer division by zero raises" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("1 / 0"));
}

test "floor and ceil saturate to i64 min near the boundary instead of wrapping" {
    // The saturated result doesn't fit the inline-int encoding, so it
    // surfaces as a boxed int; render it to check the observable value
    // without reaching into the encoding directly.
    const floored = try renderForTest("builtins.floor 1.0e100");
    defer std.testing.allocator.free(floored);
    try std.testing.expectEqualStrings("-9223372036854775808", floored);

    const ceiled = try renderForTest("builtins.ceil (0.0 - 1.0e100)");
    defer std.testing.allocator.free(ceiled);
    try std.testing.expectEqualStrings("-9223372036854775808", ceiled);
}

test "floor and ceil pass integers through unchanged" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const floored = try ev.evaluate("builtins.floor 42");
    try std.testing.expectEqual(@as(i64, 42), floored.asInt());

    const ceiled = try ev.evaluate("builtins.ceil (0 - 42)");
    try std.testing.expectEqual(@as(i64, -42), ceiled.asInt());
}

test "bitwise ops on ints" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const anded = try ev.evaluate("builtins.bitAnd 6 3");
    try std.testing.expectEqual(@as(i64, 2), anded.asInt());

    const ored = try ev.evaluate("builtins.bitOr 4 1");
    try std.testing.expectEqual(@as(i64, 5), ored.asInt());

    const xored = try ev.evaluate("builtins.bitXor 6 3");
    try std.testing.expectEqual(@as(i64, 5), xored.asInt());
}

test "bitwise ops reject non-integer operands" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.bitAnd 1.0 2"));
}

test "lessThan compares numbers and strings" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const numeric_lt = try ev.evaluate("builtins.lessThan 1 2");
    try std.testing.expect(numeric_lt.asBool());

    const string_lt = try ev.evaluate("builtins.lessThan \"a\" \"b\"");
    try std.testing.expect(string_lt.asBool());
}
