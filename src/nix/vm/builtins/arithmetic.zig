//! Nix arithmetic and numeric-comparison builtins: add/sub/mul/div, the
//! bitwise ops, floor/ceil, and lessThan.

const std = @import("std");
const Value = @import("runtime").value.Value;
const numeric = @import("runtime").numeric;
const int_mod = @import("runtime").int;
const vm_force = @import("../force.zig");
const vm_equality = @import("../equality.zig");
const vm_trace = @import("../trace.zig");

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
    const v = try vm_force.forceValue(self, arg);
    return numeric.floor(self.heap, v) catch |err| return floorCeilResult(self, err, v, "floor");
}

pub fn builtinCeil(self: anytype, arg: Value) !Value {
    const v = try vm_force.forceValue(self, arg);
    return numeric.ceil(self.heap, v) catch |err| return floorCeilResult(self, err, v, "ceil");
}

/// On the integer-corruption error: with the `floor-ceil-corrupt-integers`
/// deprecated feature enabled, return the (corrupted) f64-round-tripped value
/// as Nix historically did; otherwise raise the diagnostic error.
fn floorCeilResult(self: anytype, err: anyerror, v: Value, name: []const u8) anyerror!Value {
    if (err == error.FloorCeilCorruptsInteger and self.policy.allow_floor_ceil_corrupt) {
        const i: i64 = switch (v.kind()) {
            .int => v.asInt(),
            .boxed_int => try self.heap.getBoxedInt(v.asObjectId()),
            else => return err,
        };
        if (numeric.intRoundTripCorruption(i)) |became| return int_mod.make(self.heap, became);
    }
    return floorCeilError(self, err, v, name);
}

/// Attach Nix's diagnostic for the `floor`/`ceil` integer-corruption error
/// (`https://github.com/NixOS/nix/issues/12899`); pass any other error
/// through untouched.
fn floorCeilError(self: anytype, err: anyerror, v: Value, name: []const u8) anyerror {
    if (err != error.FloorCeilCorruptsInteger) return err;
    const was: ?i64 = switch (v.kind()) {
        .int => v.asInt(),
        .boxed_int => self.heap.getBoxedInt(v.asObjectId()) catch null,
        else => null,
    };
    if (was) |i| {
        if (numeric.intRoundTripCorruption(i)) |became| {
            const msg = std.fmt.allocPrint(self.allocator, "builtins.{s} was corrupting your integer (was {d}, became {d}) in previous versions due to a historical Nix bug (https://github.com/NixOS/nix/issues/12899).\nThis may be changed in the future to pass through integers as-is, which will change the semantics of this code.\nTo suppress this error, use --extra-deprecated-features floor-ceil-corrupt-integers", .{ name, i, became }) catch return err;
            defer self.allocator.free(msg);
            vm_trace.setErrorMessage(self, msg) catch {};
        }
    }
    return err;
}
