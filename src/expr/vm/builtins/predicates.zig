//! Nix type-inspection builtins: typeOf and the is* predicates (isString,
//! isBool, isFunction, and the generic isInt/isFloat/isList/... family).

const Value = @import("runtime").value.Value;
const VM = @import("../context.zig").VM;
const ValueType = @import("runtime").value.ValueType;
const vm_force = @import("../force.zig");

pub fn builtinTypePredicate(self: *VM, arg: Value, expected: ValueType) !Value {
    const value = try vm_force.forceValue(self, arg);
    const k = value.kind();
    // Boxed ints (outside the i48 inline range) are ints to the language.
    return Value.boolVal(k == expected or (expected == .int and k == .boxed_int));
}

pub fn builtinIsString(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal(value.isString() or value.isContextString() or value.isHeapString());
}

pub fn builtinIsBool(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal(value.isBool());
}

pub fn builtinIsFunction(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal(value.isNixClosure() or value.isBuiltin() or value.isBuiltinClosure() or value.isPartialApp());
}

pub fn builtinTypeOf(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    const name: []const u8 = switch (value.kind()) {
        .null => "null",
        .bool_false, .bool_true => "bool",
        .int, .boxed_int => "int",
        .float => "float",
        .string, .string_context, .heap_string => "string",
        .path => "path",
        .list => "list",
        .attrs => "set",
        .closure, .builtin, .builtin_closure, .partial_app => "lambda",
        .thunk => unreachable,
    };
    return Value.string(try self.intern.intern(name));
}
