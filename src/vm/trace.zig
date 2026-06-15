const std = @import("std");
const vm_mod = @import("../vm.zig");
const Value = @import("../runtime/value.zig").Value;

const VM = vm_mod.VM;

pub fn setErrorMessage(self: *VM, message: []const u8) !void {
    if (self.trace) |trace| try trace.setMessage(message);
}

pub fn pushErrorContext(self: *VM, message: []const u8) !void {
    if (self.trace) |trace| try trace.pushFrame(message);
}

pub fn clearErrorTrace(self: *VM) void {
    if (self.trace) |trace| trace.clear();
}

pub fn typeErrorExpected(self: *VM, expected: []const u8, got: Value) error{TypeError} {
    if (self.trace) |trace| {
        const message = std.fmt.allocPrint(self.allocator, "expected {s}, got {s}", .{ expected, valueTypeName(self, got) }) catch return error.TypeError;
        defer self.allocator.free(message);
        trace.setMessageIfAbsent(message) catch {};
    }
    return error.TypeError;
}

pub fn notCallableError(self: *VM, got: Value) error{NotCallable} {
    if (self.trace) |trace| {
        const message = std.fmt.allocPrint(self.allocator, "expected function, got {s}", .{valueTypeName(self, got)}) catch return error.NotCallable;
        defer self.allocator.free(message);
        trace.setMessageIfAbsent(message) catch {};
    }
    return error.NotCallable;
}

pub fn valueTypeName(self: *VM, value: Value) []const u8 {
    _ = self;
    return switch (value.kind()) {
        .null => "null",
        .bool_false, .bool_true => "bool",
        .int, .boxed_int => "int",
        .float => "float",
        .string => "string",
        .path => "path",
        .list => "list",
        .attrs => "attrs",
        .closure, .builtin, .builtin_closure, .partial_app => "function",
        .thunk => "thunk",
        .string_context => "string",
    };
}
