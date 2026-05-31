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
pub const builtins = @import("builtins.zig");
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

test "end-to-end: attribute access" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ a = 42; }).a");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
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
