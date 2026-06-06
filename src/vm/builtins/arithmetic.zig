const Value = @import("../../value.zig").Value;
const numeric = @import("../../runtime/numeric.zig");
const vm_force = @import("../force.zig");
const vm_equality = @import("../equality.zig");

pub fn builtinAdd(self: anytype, left: Value, right: Value) !Value {
    return numeric.add(try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinSub(self: anytype, left: Value, right: Value) !Value {
    return numeric.sub(try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinMul(self: anytype, left: Value, right: Value) !Value {
    return numeric.mul(try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinDiv(self: anytype, left: Value, right: Value) !Value {
    return numeric.div(try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinLessThan(self: anytype, left: Value, right: Value) !Value {
    return Value.boolVal(try vm_equality.compareValues(self, left, right) == .lt);
}

pub fn builtinBitAnd(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitAnd(try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinBitOr(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitOr(try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinBitXor(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitXor(try vm_force.forceValue(self, left), try vm_force.forceValue(self, right));
}

pub fn builtinFloor(self: anytype, arg: Value) !Value {
    return numeric.floor(try vm_force.forceValue(self, arg));
}

pub fn builtinCeil(self: anytype, arg: Value) !Value {
    return numeric.ceil(try vm_force.forceValue(self, arg));
}
