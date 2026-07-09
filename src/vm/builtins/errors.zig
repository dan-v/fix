//! Nix error and tracing builtins: throw, abort, tryEval, addErrorContext,
//! and trace/traceVerbose.

const std = @import("std");
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");

pub fn builtinThrow(self: anytype, message_arg: Value) !Value {
    try vm_trace.setErrorMessage(self, try strings.stringArg(self, message_arg));
    return error.NixThrow;
}

pub fn builtinAbort(self: anytype, message_arg: Value) !Value {
    try vm_trace.setErrorMessage(self, try strings.stringArg(self, message_arg));
    return error.NixAbort;
}

pub fn builtinTryEval(self: anytype, arg: Value) !Value {
    const value = vm_force.forceValue(self, arg) catch |err| switch (err) {
        error.NixThrow,
        error.NixAbort,
        error.AssertionFailed,
        error.FileNotFound,
        => {
            vm_trace.clearErrorTrace(self);
            return tryEvalResult(self, false, Value.boolVal(false));
        },
        else => return err,
    };
    return tryEvalResult(self, true, value);
}

pub fn builtinAddErrorContext(self: anytype, message_arg: Value, value_arg: Value) !Value {
    return vm_force.forceValue(self, value_arg) catch |err| {
        const message = strings.stringArg(self, message_arg) catch return err;
        vm_trace.pushErrorContext(self, message) catch return err;
        return err;
    };
}

pub fn builtinTrace(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try vm_force.forceValue(self, message_arg);
    return vm_force.forceValue(self, value_arg);
}

pub fn builtinTraceVerbose(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try vm_force.forceValue(self, message_arg);
    return vm_force.forceValue(self, value_arg);
}

pub fn tryEvalResult(self: anytype, success: bool, value: Value) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("success"),
            .value = Value.boolVal(success),
        },
        .{
            .name = try self.intern.intern("value"),
            .value = value,
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}
