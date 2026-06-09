//! Numeric operations shared by bytecode opcodes and builtins.
//!
//! All int-returning ops take the heap so they can transparently box
//! results that overflow the inline int range (only meaningful under
//! Value8; Value16 always inlines).

const std = @import("std");
const Value = @import("value.zig").Value;
const int_mod = @import("int.zig");
const ObjectHeap = @import("heap.zig").ObjectHeap;

pub fn isNumeric(value: Value) bool {
    return int_mod.isAnyInt(value) or value.isFloat();
}

pub fn toFloat(value: Value, heap: *const ObjectHeap) !f64 {
    return switch (value.kind()) {
        .int => @floatFromInt(value.asInt()),
        .boxed_int => @floatFromInt(try heap.getBoxedInt(value.asObjectId())),
        .float => value.asFloat(),
        else => error.TypeError,
    };
}

// ---- Nix-parity integer arithmetic ----
//
// Nix's C++ evaluator raises on integer overflow rather than wrapping.
// We match that: each binary op uses Zig's checked overflow builtin and
// returns `error.IntegerOverflow` when the result wouldn't fit i64.
// Float arithmetic, by contrast, uses ordinary IEEE 754 (Inf/NaN-producing)
// EXCEPT for division by zero, which Nix raises rather than producing Inf.

inline fn checkedAdd(a: i64, b: i64) !i64 {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return error.IntegerOverflow;
    return r[0];
}

inline fn checkedSub(a: i64, b: i64) !i64 {
    const r = @subWithOverflow(a, b);
    if (r[1] != 0) return error.IntegerOverflow;
    return r[0];
}

inline fn checkedMul(a: i64, b: i64) !i64 {
    const r = @mulWithOverflow(a, b);
    if (r[1] != 0) return error.IntegerOverflow;
    return r[0];
}

pub fn add(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        return int_mod.make(heap, try checkedAdd(int_mod.get(a, heap), int_mod.get(b, heap)));
    }
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a, heap) + try toFloat(b, heap));
    return error.TypeError;
}

pub fn sub(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        return int_mod.make(heap, try checkedSub(int_mod.get(a, heap), int_mod.get(b, heap)));
    }
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a, heap) - try toFloat(b, heap));
    return error.TypeError;
}

pub fn mul(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        return int_mod.make(heap, try checkedMul(int_mod.get(a, heap), int_mod.get(b, heap)));
    }
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a, heap) * try toFloat(b, heap));
    return error.TypeError;
}

pub fn div(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        const bi = int_mod.get(b, heap);
        if (bi == 0) return error.DivisionByZero;
        const ai = int_mod.get(a, heap);
        // `@divTrunc(i64_min, -1)` overflows i64 (the mathematical result
        // is 2^63, one past the max). Zig treats this as illegal
        // behaviour; raise instead of leaving it to LLVM.
        if (ai == std.math.minInt(i64) and bi == -1) return error.IntegerOverflow;
        return int_mod.make(heap, @divTrunc(ai, bi));
    }
    if (isNumeric(a) and isNumeric(b)) {
        const bf = try toFloat(b, heap);
        // Parity with Nix: float division by zero raises rather than
        // producing IEEE Inf/NaN.
        if (bf == 0.0) return error.DivisionByZero;
        return Value.float(try toFloat(a, heap) / bf);
    }
    return error.TypeError;
}

pub fn negate(heap: *ObjectHeap, value: Value) !Value {
    return switch (value.kind()) {
        // Negating i64_min overflows; defer to checkedSub for parity with
        // Nix's `0 - i64_min` behaviour.
        .int => int_mod.make(heap, try checkedSub(0, value.asInt())),
        .boxed_int => int_mod.make(heap, try checkedSub(0, try heap.getBoxedInt(value.asObjectId()))),
        .float => Value.float(-value.asFloat()),
        else => error.TypeError,
    };
}

pub fn floor(heap: *ObjectHeap, value: Value) !Value {
    return switch (value.kind()) {
        .int, .boxed_int => value,
        .float => int_mod.make(heap, try floatToI64Safely(@floor(value.asFloat()))),
        else => error.TypeError,
    };
}

pub fn ceil(heap: *ObjectHeap, value: Value) !Value {
    return switch (value.kind()) {
        .int, .boxed_int => value,
        .float => int_mod.make(heap, try floatToI64Safely(@ceil(value.asFloat()))),
        else => error.TypeError,
    };
}

/// Convert a finite, in-range f64 to i64 with Nix-parity semantics:
///
///   - NaN and ±Infinity raise `error.NumericConversion` (Nix throws
///     `"failed to convert to integer"`).
///   - Finite floats whose magnitude is `>= 2^63` saturate to `i64_min`,
///     mirroring the x86 `cvttsd2si` "indefinite integer" result that
///     Nix's C++ cast exhibits. We replicate that exact behaviour rather
///     than triggering Zig's `@intFromFloat` UB.
///   - In-range finite floats truncate via `@intFromFloat`.
///
/// Hex float literals are exact: `0x1.0p63 == 2^63`. f64 represents 2^63
/// and -2^63 exactly but not (2^63 - 1), so the upper bound is strictly
/// less-than 2^63 and the lower bound is greater-equal -2^63.
fn floatToI64Safely(f: f64) !i64 {
    if (std.math.isNan(f) or std.math.isInf(f)) return error.NumericConversion;
    const upper_exclusive: f64 = 0x1.0p63;
    const lower_inclusive: f64 = -0x1.0p63;
    if (f < lower_inclusive or f >= upper_exclusive) return std.math.minInt(i64);
    return @intFromFloat(f);
}

pub fn bitAnd(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (!int_mod.isAnyInt(a) or !int_mod.isAnyInt(b)) return error.TypeError;
    return int_mod.make(heap, int_mod.get(a, heap) & int_mod.get(b, heap));
}

pub fn bitOr(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (!int_mod.isAnyInt(a) or !int_mod.isAnyInt(b)) return error.TypeError;
    return int_mod.make(heap, int_mod.get(a, heap) | int_mod.get(b, heap));
}

pub fn bitXor(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (!int_mod.isAnyInt(a) or !int_mod.isAnyInt(b)) return error.TypeError;
    return int_mod.make(heap, int_mod.get(a, heap) ^ int_mod.get(b, heap));
}

test "numeric builtins preserve int results when both inputs are ints" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectEqual(@as(i64, 3), (try add(&heap, Value.int(1), Value.int(2))).asInt());
    try std.testing.expectEqual(@as(i64, 3), (try div(&heap, Value.int(7), Value.int(2))).asInt());
    try std.testing.expectEqual(@as(i64, -3), (try div(&heap, Value.int(-7), Value.int(2))).asInt());
}

test "numeric builtins promote mixed numeric inputs to floats" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectEqual(@as(f64, 3.5), (try add(&heap, Value.int(1), Value.float(2.5))).asFloat());
    try std.testing.expectEqual(@as(f64, 3.5), (try div(&heap, Value.int(7), Value.float(2.0))).asFloat());
}

test "div rejects i64.min / -1 overflow rather than invoking @divTrunc UB" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    // Build i64.min via a boxed int so we exercise the cross-encoding
    // unbox path used by the safety check.
    const boxed_min = Value.boxedInt(try heap.addBoxedInt(std.math.minInt(i64)));
    try std.testing.expectError(error.IntegerOverflow, div(&heap, boxed_min, Value.int(-1)));
    // Sanity: i64.min / 1 still works (inline result on Value16, boxed on Value8).
    _ = try div(&heap, boxed_min, Value.int(1));
}

test "int arithmetic raises on overflow rather than wrapping (Nix parity)" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    const max = Value.boxedInt(try heap.addBoxedInt(std.math.maxInt(i64)));
    const min = Value.boxedInt(try heap.addBoxedInt(std.math.minInt(i64)));
    try std.testing.expectError(error.IntegerOverflow, add(&heap, max, Value.int(1)));
    try std.testing.expectError(error.IntegerOverflow, sub(&heap, min, Value.int(1)));
    const half = Value.boxedInt(try heap.addBoxedInt(@as(i64, 1) << 32));
    try std.testing.expectError(error.IntegerOverflow, mul(&heap, half, half));
    try std.testing.expectError(error.IntegerOverflow, negate(&heap, min));
}

test "float division by zero raises (Nix parity)" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectError(error.DivisionByZero, div(&heap, Value.float(1.0), Value.float(0.0)));
    try std.testing.expectError(error.DivisionByZero, div(&heap, Value.float(0.0), Value.float(0.0)));
    try std.testing.expectError(error.DivisionByZero, div(&heap, Value.int(1), Value.float(0.0)));
}

test "floor/ceil reject NaN and infinities, saturate huge finite floats to i64_min (Nix parity)" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectError(error.NumericConversion, floor(&heap, Value.float(std.math.nan(f64))));
    try std.testing.expectError(error.NumericConversion, ceil(&heap, Value.float(std.math.nan(f64))));
    try std.testing.expectError(error.NumericConversion, floor(&heap, Value.float(std.math.inf(f64))));
    try std.testing.expectError(error.NumericConversion, ceil(&heap, Value.float(-std.math.inf(f64))));
    // Out-of-range finite floats saturate to i64_min (Nix C++ inherits the
    // x86 cvttsd2si "indefinite integer" behaviour on overflow).
    const huge_pos = try floor(&heap, Value.float(1.0e100));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(huge_pos, &heap));
    const huge_neg = try ceil(&heap, Value.float(-1.0e100));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(huge_neg, &heap));
    // The boundary: exactly 2^63 saturates; -2^63 (== i64_min) succeeds.
    const boundary_pos = try floor(&heap, Value.float(0x1.0p63));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(boundary_pos, &heap));
    const boundary_neg = try floor(&heap, Value.float(-0x1.0p63));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(boundary_neg, &heap));
}
