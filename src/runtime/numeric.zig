//! Numeric operations shared by bytecode opcodes and builtins.

const std = @import("std");
const Value = @import("value.zig").Value;

pub fn isNumeric(value: Value) bool {
    return value.discriminant == .int or value.discriminant == .float;
}

pub fn toFloat(value: Value) !f64 {
    return switch (value.discriminant) {
        .int => @floatFromInt(value.asInt()),
        .float => value.asFloat(),
        else => error.TypeError,
    };
}

pub fn add(a: Value, b: Value) !Value {
    if (a.discriminant == .int and b.discriminant == .int) return Value.int(a.asInt() + b.asInt());
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a) + try toFloat(b));
    return error.TypeError;
}

pub fn sub(a: Value, b: Value) !Value {
    if (a.discriminant == .int and b.discriminant == .int) return Value.int(a.asInt() - b.asInt());
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a) - try toFloat(b));
    return error.TypeError;
}

pub fn mul(a: Value, b: Value) !Value {
    if (a.discriminant == .int and b.discriminant == .int) return Value.int(a.asInt() * b.asInt());
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a) * try toFloat(b));
    return error.TypeError;
}

pub fn div(a: Value, b: Value) !Value {
    if (a.discriminant == .int and b.discriminant == .int) {
        if (b.asInt() == 0) return error.DivisionByZero;
        return Value.int(@divTrunc(a.asInt(), b.asInt()));
    }
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a) / try toFloat(b));
    return error.TypeError;
}

pub fn negate(value: Value) !Value {
    return switch (value.discriminant) {
        .int => Value.int(-value.asInt()),
        .float => Value.float(-value.asFloat()),
        else => error.TypeError,
    };
}

pub fn floor(value: Value) !Value {
    return switch (value.discriminant) {
        .int => value,
        .float => Value.int(@intFromFloat(@floor(value.asFloat()))),
        else => error.TypeError,
    };
}

pub fn ceil(value: Value) !Value {
    return switch (value.discriminant) {
        .int => value,
        .float => Value.int(@intFromFloat(@ceil(value.asFloat()))),
        else => error.TypeError,
    };
}

pub fn bitAnd(a: Value, b: Value) !Value {
    if (a.discriminant != .int or b.discriminant != .int) return error.TypeError;
    return Value.int(a.asInt() & b.asInt());
}

pub fn bitOr(a: Value, b: Value) !Value {
    if (a.discriminant != .int or b.discriminant != .int) return error.TypeError;
    return Value.int(a.asInt() | b.asInt());
}

pub fn bitXor(a: Value, b: Value) !Value {
    if (a.discriminant != .int or b.discriminant != .int) return error.TypeError;
    return Value.int(a.asInt() ^ b.asInt());
}

test "numeric builtins preserve int results when both inputs are ints" {
    try std.testing.expectEqual(@as(i64, 3), (try add(Value.int(1), Value.int(2))).asInt());
    try std.testing.expectEqual(@as(i64, 3), (try div(Value.int(7), Value.int(2))).asInt());
    try std.testing.expectEqual(@as(i64, -3), (try div(Value.int(-7), Value.int(2))).asInt());
}

test "numeric builtins promote mixed numeric inputs to floats" {
    try std.testing.expectEqual(@as(f64, 3.5), (try add(Value.int(1), Value.float(2.5))).asFloat());
    try std.testing.expectEqual(@as(f64, 3.5), (try div(Value.int(7), Value.float(2.0))).asFloat());
}
