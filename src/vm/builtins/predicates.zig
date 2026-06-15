const Value = @import("../../runtime/value.zig").Value;
const ValueType = @import("../../runtime/value.zig").ValueType;
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
