//! Nix type-inspection builtins: typeOf and the is* predicates (isString,
//! isBool, isFunction, and the generic isInt/isFloat/isList/... family).

const Value = @import("runtime").value.Value;
const ValueType = @import("runtime").value.ValueType;
const vm_force = @import("../force.zig");

pub fn builtinTypePredicate(self: anytype, arg: Value, expected: ValueType) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal(value.kind() == expected);
}

pub fn builtinIsString(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal(value.isString() or value.isContextString());
}

pub fn builtinIsBool(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal(value.isBool());
}

pub fn builtinIsFunction(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal(value.isClosure() or value.isBuiltin() or value.isBuiltinClosure() or value.isPartialApp());
}

pub fn builtinTypeOf(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    const name: []const u8 = switch (value.kind()) {
        .null => "null",
        .bool_false, .bool_true => "bool",
        .int, .boxed_int => "int",
        .float => "float",
        .string, .string_context => "string",
        .path => "path",
        .list => "list",
        .attrs => "set",
        .closure, .builtin, .builtin_closure, .partial_app => "lambda",
        .thunk => unreachable,
    };
    return Value.string(try self.intern.intern(name));
}

const std = @import("std");
const renderForTest = @import("../../eval/test_helpers.zig").renderForTest;

test "typeOf reports every observable value kind" {
    const cases = .{
        .{ "builtins.typeOf null", "\"null\"" },
        .{ "builtins.typeOf true", "\"bool\"" },
        .{ "builtins.typeOf false", "\"bool\"" },
        .{ "builtins.typeOf 1", "\"int\"" },
        .{ "builtins.typeOf 1.5", "\"float\"" },
        .{ "builtins.typeOf \"x\"", "\"string\"" },
        .{ "builtins.typeOf /foo", "\"path\"" },
        .{ "builtins.typeOf [ ]", "\"list\"" },
        .{ "builtins.typeOf { }", "\"set\"" },
        .{ "builtins.typeOf (x: x)", "\"lambda\"" },
        .{ "builtins.typeOf builtins.head", "\"lambda\"" },
        .{ "builtins.typeOf (builtins.elemAt [ 1 ])", "\"lambda\"" },
    };
    inline for (cases) |case| {
        const result = try renderForTest(case[0]);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case[1], result);
    }
}

test "isString recognizes both plain and context-carrying strings" {
    const plain = try renderForTest("builtins.isString \"x\"");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("true", plain);

    const with_context = try renderForTest(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.isString "${d}"
    );
    defer std.testing.allocator.free(with_context);
    try std.testing.expectEqualStrings("true", with_context);

    const not_string = try renderForTest("builtins.isString 1");
    defer std.testing.allocator.free(not_string);
    try std.testing.expectEqualStrings("false", not_string);
}

test "isBool is true only for booleans" {
    const is_true = try renderForTest("builtins.isBool true");
    defer std.testing.allocator.free(is_true);
    try std.testing.expectEqualStrings("true", is_true);

    const not_bool = try renderForTest("builtins.isBool 1");
    defer std.testing.allocator.free(not_bool);
    try std.testing.expectEqualStrings("false", not_bool);
}

test "isFunction recognizes closures builtins and partial applications" {
    const closure = try renderForTest("builtins.isFunction (x: x)");
    defer std.testing.allocator.free(closure);
    try std.testing.expectEqualStrings("true", closure);

    const builtin = try renderForTest("builtins.isFunction builtins.head");
    defer std.testing.allocator.free(builtin);
    try std.testing.expectEqualStrings("true", builtin);

    const partial = try renderForTest("builtins.isFunction (builtins.elemAt [ 1 ])");
    defer std.testing.allocator.free(partial);
    try std.testing.expectEqualStrings("true", partial);

    const not_function = try renderForTest("builtins.isFunction 1");
    defer std.testing.allocator.free(not_function);
    try std.testing.expectEqualStrings("false", not_function);
}
