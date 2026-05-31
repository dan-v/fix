//! fix — A blazing fast Nix evaluator.
//!
//! Public API surface. Re-exports the evaluator and types for consumers.

pub const types = @import("types.zig");
pub const value = @import("value.zig");
pub const token = @import("token.zig");
pub const scanner = @import("scanner.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const opcode = @import("opcode.zig");
pub const chunk = @import("chunk.zig");
pub const heap = @import("heap.zig");
pub const compiler = @import("compiler.zig");
pub const env = @import("env.zig");
pub const intern = @import("intern.zig");
pub const thunk = @import("thunk.zig");
pub const cache = @import("cache.zig");
pub const scheduler = @import("scheduler.zig");
pub const vm = @import("vm.zig");
pub const eval = @import("eval.zig");

pub const Evaluator = eval.Evaluator;
pub const Value = value.Value;

test "end-to-end: simple arithmetic" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("10 + 32");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "end-to-end: float arithmetic" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const add = try ev.evaluate("1.5 + 2.25");
    try std.testing.expectEqual(@as(f64, 3.75), add.asFloat());

    const mixed = try ev.evaluate("1 + 2.5");
    try std.testing.expectEqual(@as(f64, 3.5), mixed.asFloat());

    const nested = try ev.evaluate("(1.5 + 2) * 2");
    try std.testing.expectEqual(@as(f64, 7.0), nested.asFloat());

    const mixed_eq = try ev.evaluate("1 == 1.0");
    try std.testing.expect(mixed_eq.asBool());

    const mixed_neq = try ev.evaluate("1 != 1.5");
    try std.testing.expect(mixed_neq.asBool());
}

test "end-to-end: let binding" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = 10; y = 32; in x + y");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
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

test "end-to-end: function arguments are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const unused_arg = try ev.evaluate("let f = x: 1; a = f b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), unused_arg.asInt());

    const guarded_arg = try ev.evaluate("let f = x: if true then 1 else x; a = f b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), guarded_arg.asInt());

    const used_arg = try ev.evaluate("let f = x: x + 1; a = f b; b = 3; in a");
    try std.testing.expectEqual(@as(i64, 4), used_arg.asInt());

    try std.testing.expectError(
        error.RecursiveThunk,
        ev.evaluate("let f = x: x + 1; a = f b; b = a + 1; in a"),
    );
}

test "end-to-end: attribute set" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("{ a = 1; b = 2; }");
    try std.testing.expectEqual(value.ValueType.attrs, result.discriminant);
}

test "end-to-end: list elements are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("[ 1 (1 / 0) ]");
    try std.testing.expectEqual(value.ValueType.list, result.discriminant);
}

test "end-to-end: attribute access" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ a = 42; }).a");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "end-to-end: unused attribute values are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ a = 42; b = 1 / 0; }).a");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());

    try std.testing.expectError(error.DivisionByZero, ev.evaluate("({ a = 1 / 0; }).a"));
}

test "end-to-end: recursive attribute sets" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const forward = try ev.evaluate("(rec { a = b + 1; b = 3; }).a");
    try std.testing.expectEqual(@as(i64, 4), forward.asInt());

    const guarded = try ev.evaluate("(rec { a = if true then 1 else b; b = a + 1; }).b");
    try std.testing.expectEqual(@as(i64, 2), guarded.asInt());

    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("(rec { a = a; }).a"));
}

test "end-to-end: nested attribute declarations" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const nested = try ev.evaluate("({ a.b = 1; a.c = 2; }).a.c");
    try std.testing.expectEqual(@as(i64, 2), nested.asInt());

    const quoted = try ev.evaluate("({ a.\"b\" = 3; }).a.b");
    try std.testing.expectEqual(@as(i64, 3), quoted.asInt());

    const lazy = try ev.evaluate("({ a.b = 1; a.c = 1 / 0; }).a.b");
    try std.testing.expectEqual(@as(i64, 1), lazy.asInt());

    const rec_nested = try ev.evaluate("(rec { a.b = x + 1; x = 3; }).a.b");
    try std.testing.expectEqual(@as(i64, 4), rec_nested.asInt());

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a.b = 2; }"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a.b = 1; a.b = 2; }"));
}

test "end-to-end: duplicate attributes are rejected" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a = 2; }"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1 / 0; a = 2; }"));
}

test "end-to-end: quoted attribute access" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ foo = 42; }).\"foo\"");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "end-to-end: if else false branch" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("if false then 1 else 2");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}

test "end-to-end: boolean operators short-circuit" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const and_result = try ev.evaluate("true && false");
    try std.testing.expect(!and_result.asBool());

    const or_result = try ev.evaluate("false || true");
    try std.testing.expect(or_result.asBool());

    const short_and = try ev.evaluate("false && (1 / 0)");
    try std.testing.expect(!short_and.asBool());

    const short_or = try ev.evaluate("true || (1 / 0)");
    try std.testing.expect(short_or.asBool());
}

test "end-to-end: boolean contexts require booleans" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("if 1 then 2 else 3"));
    try std.testing.expectError(error.TypeError, ev.evaluate("!1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("1 && true"));
    try std.testing.expectError(error.TypeError, ev.evaluate("0 || false"));
}

test "end-to-end: comparisons reject incompatible types" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("1 < true"));
    try std.testing.expectError(error.TypeError, ev.evaluate("\"a\" < 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("true < false"));

    const mixed_lt = try ev.evaluate("1 < 1.5");
    try std.testing.expect(mixed_lt.asBool());

    const mixed_gt = try ev.evaluate("2 > 1.5");
    try std.testing.expect(mixed_gt.asBool());
}

test "end-to-end: lists and attrs compare structurally" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const lists_equal = try ev.evaluate("[ 1 2 ] == [ 1 2 ]");
    try std.testing.expect(lists_equal.asBool());

    const lists_not_equal = try ev.evaluate("[ 1 2 ] == [ 1 3 ]");
    try std.testing.expect(!lists_not_equal.asBool());

    const attrs_equal = try ev.evaluate("{ b = 2; a = 1; } == { a = 1; b = 2; }");
    try std.testing.expect(attrs_equal.asBool());

    const attrs_not_equal = try ev.evaluate("{ a = 1; } == { a = 2; }");
    try std.testing.expect(!attrs_not_equal.asBool());

    try std.testing.expectError(error.DivisionByZero, ev.evaluate("[ 1 (1 / 0) ] == [ 1 2 ]"));
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("{ a = 1 / 0; } == { a = 1; }"));
}

test "end-to-end: single argument lambdas" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const direct = try ev.evaluate("(x: x + 1) 41");
    try std.testing.expectEqual(@as(i64, 42), direct.asInt());

    const bound = try ev.evaluate("let inc = x: x + 1; in inc 41");
    try std.testing.expectEqual(@as(i64, 42), bound.asInt());

    const shadowed = try ev.evaluate("(x: (x: x + 1) 41) 0");
    try std.testing.expectEqual(@as(i64, 42), shadowed.asInt());

    const precedence = try ev.evaluate("(x: x) 1 + 2");
    try std.testing.expectEqual(@as(i64, 3), precedence.asInt());

    const repeated_calls = try ev.evaluate("let f = x: x; in (f 1) + (f 2)");
    try std.testing.expectEqual(@as(i64, 3), repeated_calls.asInt());

    const captured = try ev.evaluate("let y = 1; in (x: x + y) 41");
    try std.testing.expectEqual(@as(i64, 42), captured.asInt());
}

const std = @import("std");
const ValueType = value.ValueType;
