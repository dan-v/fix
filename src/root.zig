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
pub const scheduler = @import("scheduler.zig");
pub const vm = @import("vm.zig");
pub const eval = @import("eval.zig");
pub const builtins = @import("builtins.zig");

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

test "end-to-end: string concatenation" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const literal = try ev.evaluate("\"ab\" + \"cd\"");
    try std.testing.expectEqualStrings("abcd", ev.intern.get(literal.asInternId()));

    const bound = try ev.evaluate("let a = \"ab\"; in a + \"cd\"");
    try std.testing.expectEqualStrings("abcd", ev.intern.get(bound.asInternId()));

    try std.testing.expectError(error.TypeError, ev.evaluate("\"ab\" + 1"));
}

test "end-to-end: string interpolation" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const literal = try ev.evaluate("\"a${\"b\"}c\"");
    try std.testing.expectEqualStrings("abc", ev.intern.get(literal.asInternId()));

    const bound = try ev.evaluate("let x = \"b\"; in \"a${x}c\"");
    try std.testing.expectEqualStrings("abc", ev.intern.get(bound.asInternId()));

    try std.testing.expectError(error.TypeError, ev.evaluate("\"a${1}c\""));
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

test "end-to-end: simple inherit in attrsets" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const inherited = try ev.evaluate("let x = 1; y = 2; in ({ inherit x y; }).y");
    try std.testing.expectEqual(@as(i64, 2), inherited.asInt());

    const recursive = try ev.evaluate("let a = { inherit a; }; in a");
    try std.testing.expectEqual(value.ValueType.attrs, recursive.discriminant);

    const nested = try ev.evaluate("(let a = { inherit a; }; in a).a.a");
    try std.testing.expectEqual(value.ValueType.attrs, nested.discriminant);
}

test "end-to-end: list elements are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("[ 1 (1 / 0) ]");
    try std.testing.expectEqual(value.ValueType.list, result.discriminant);
}

test "end-to-end: list concatenation" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const combined = try ev.evaluate("[ 1 ] ++ [ 2 3 ] == [ 1 2 3 ]");
    try std.testing.expect(combined.asBool());

    const lazy = try ev.evaluate("[ 1 / 0 ] ++ []");
    try std.testing.expectEqual(value.ValueType.list, lazy.discriminant);

    try std.testing.expectError(error.TypeError, ev.evaluate("[ 1 ] ++ 2"));
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

test "end-to-end: attrset update operator" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const added = try ev.evaluate("({ a = 1; } // { b = 2; }).b");
    try std.testing.expectEqual(@as(i64, 2), added.asInt());

    const overridden = try ev.evaluate("({ a = 1; b = 2; } // { b = 3; }).b");
    try std.testing.expectEqual(@as(i64, 3), overridden.asInt());

    const lazy = try ev.evaluate("({ a = 1 / 0; } // { a = 4; }).a");
    try std.testing.expectEqual(@as(i64, 4), lazy.asInt());

    try std.testing.expectError(error.TypeError, ev.evaluate("{ a = 1; } // 1"));
}

test "end-to-end: attr path or defaults" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const present = try ev.evaluate("({ a.b = 1; }).a.b or 2");
    try std.testing.expectEqual(@as(i64, 1), present.asInt());

    const missing_leaf = try ev.evaluate("({ a = {}; }).a.b or 2");
    try std.testing.expectEqual(@as(i64, 2), missing_leaf.asInt());

    const missing_mid = try ev.evaluate("({}).a.b or 2");
    try std.testing.expectEqual(@as(i64, 2), missing_mid.asInt());

    const lazy_default = try ev.evaluate("({ a.b = 1; }).a.b or (1 / 0)");
    try std.testing.expectEqual(@as(i64, 1), lazy_default.asInt());

    try std.testing.expectError(error.DivisionByZero, ev.evaluate("({}).a.b or (1 / 0)"));
    try std.testing.expectError(error.TypeError, ev.evaluate("1.a or 2"));
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

test "end-to-end: builtins.toString" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const int_string = try ev.evaluate("builtins.toString 42");
    try std.testing.expectEqualStrings("42", ev.intern.get(int_string.asInternId()));

    const bool_string = try ev.evaluate("builtins.toString true");
    try std.testing.expectEqualStrings("true", ev.intern.get(bool_string.asInternId()));

    const string_passthrough = try ev.evaluate("builtins.toString \"x\"");
    try std.testing.expectEqualStrings("x", ev.intern.get(string_passthrough.asInternId()));

    const shadowed = try ev.evaluate("let builtins = { toString = x: \"shadow\"; }; in builtins.toString 1");
    try std.testing.expectEqualStrings("shadow", ev.intern.get(shadowed.asInternId()));

    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.toString {}"));
}

test "end-to-end: builtin type predicates" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expect((try ev.evaluate("builtins.isAttrs {}")).asBool());
    try std.testing.expect(!(try ev.evaluate("builtins.isAttrs []")).asBool());

    try std.testing.expect((try ev.evaluate("builtins.isList [ 1 2 ]")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isString \"x\"")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isInt 1")).asBool());
    try std.testing.expect(!(try ev.evaluate("builtins.isInt 1.5")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isBool false")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isNull null")).asBool());
}

test "end-to-end: assert and implication" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const passed = try ev.evaluate("assert 1 < 2; 42");
    try std.testing.expectEqual(@as(i64, 42), passed.asInt());

    try std.testing.expectError(error.AssertionFailed, ev.evaluate("assert false; 42"));
    try std.testing.expectError(error.TypeError, ev.evaluate("assert 1; 42"));

    const vacuous = try ev.evaluate("false -> (1 / 0)");
    try std.testing.expect(vacuous.asBool());

    const true_case = try ev.evaluate("true -> 1 < 2");
    try std.testing.expect(true_case.asBool());

    const false_case = try ev.evaluate("true -> false");
    try std.testing.expect(!false_case.asBool());
}

const std = @import("std");
const ValueType = value.ValueType;
