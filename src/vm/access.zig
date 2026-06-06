const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = @import("../opcode.zig");
const OpCode = opcode.OpCode;
const chunk = @import("../chunk.zig");
const Chunk = chunk.Chunk;
const thunk_mod = @import("../thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const heap_mod = @import("../heap.zig");
const Closure = heap_mod.Closure;
const numeric = @import("../runtime/numeric.zig");
const source_paths = @import("../runtime/source_path.zig");
const vm_builtins = @import("builtins.zig");
const diagnostic = @import("../diagnostic.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

pub fn callAttrFunctor(self: *VM, callee: Value) !Value {
    const functor_id = try self.intern.intern("__functor");
    const functor = self.heap.getAttrValue(callee.asObjectId(), functor_id) catch |err| switch (err) {
        error.MissingAttribute => return error.NotCallable,
        else => return err,
    };
    return self.callValue(try self.forceValue(functor), callee);
}

pub fn applyBuiltin(self: *VM, builtin_id: u16, args: []const Value) !Value {
    return vm_builtins.applyBuiltin(self, builtin_id, args);
}

pub fn applyBuiltinClosure(self: *VM, callee: Value, arg: Value) !Value {
    const closure = try self.heap.getBuiltinClosure(callee.asObjectId());
    var args: [8]Value = undefined;
    if (closure.args.len + 1 > args.len) return error.TooManyArguments;
    @memcpy(args[0..closure.args.len], closure.args);
    args[closure.args.len] = arg;
    return self.applyBuiltin(closure.builtin_id, args[0 .. closure.args.len + 1]);
}

pub fn getAttrValue(self: *VM, attrs_val: Value, name_id: InternId) !Value {
    const attrs = try self.forceValue(attrs_val);
    if (attrs.discriminant != .attrs) return self.typeErrorExpected("attrs", attrs);
    return self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), name_id));
}

pub fn getAttrPathOrValue(self: *VM, attrs_val: Value, default_val: Value, encoded_names: []const u8, wide: bool) !Value {
    var current = try self.forceValue(attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (current.discriminant != .attrs) return self.forceValue(default_val);
        const name_id = readInternId(encoded_names, offset, wide);
        current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return self.forceValue(default_val),
            else => return err,
        };
        current = try self.forceValue(current);
    }
    return current;
}

pub fn getAttrPathDynamicOrValue(self: *VM, attrs_val: Value, dynamic_name: Value, default_val: Value, encoded_names: []const u8, wide: bool) !Value {
    var current = try self.forceValue(attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (current.discriminant != .attrs) return self.forceValue(default_val);
        const name_id = readInternId(encoded_names, offset, wide);
        current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return self.forceValue(default_val),
            else => return err,
        };
        current = try self.forceValue(current);
    }
    const name_val = try self.forceValue(dynamic_name);
    if (name_val.discriminant != .string) return error.TypeError;
    if (current.discriminant != .attrs) return self.forceValue(default_val);
    const result = self.heap.getAttrValue(current.asObjectId(), name_val.asInternId()) catch |err| switch (err) {
        error.MissingAttribute => return self.forceValue(default_val),
        else => return err,
    };
    return self.forceValue(result);
}

pub fn getAttrPathMixedOrValue(self: *VM, attrs_val: Value, dynamic_names: []const Value, default_val: Value, encoded_segments: []const u8, segment_count: usize) !Value {
    var current = try self.forceValue(attrs_val);
    var offset: usize = 0;
    var dynamic_i: usize = 0;
    for (0..segment_count) |_| {
        const tag = encoded_segments[offset];
        offset += 1;
        const name_id: InternId = switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => name: {
                if (current.discriminant != .attrs) return self.forceValue(default_val);
                const id = readU32(encoded_segments, offset);
                offset += 4;
                break :name id;
            },
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => name: {
                const name_val = try self.forceValue(dynamic_names[dynamic_i]);
                if (name_val.discriminant != .string) return error.TypeError;
                dynamic_i += 1;
                if (current.discriminant != .attrs) return self.forceValue(default_val);
                break :name name_val.asInternId();
            },
            else => return error.InvalidBytecode,
        };
        current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return self.forceValue(default_val),
            else => return err,
        };
        current = try self.forceValue(current);
    }
    return current;
}

pub fn hasAttrPath(self: *VM, attrs_val: Value, encoded_names: []const u8, wide: bool) !bool {
    var current = try self.forceValue(attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (current.discriminant != .attrs) return false;
        const name_id = readInternId(encoded_names, offset, wide);
        const attr = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return false,
            else => return err,
        };
        if (offset + stride >= encoded_names.len) return true;
        current = try self.forceValue(attr);
    }
    return false;
}

pub fn hasAttrPathMixed(self: *VM, attrs_val: Value, dynamic_names: []const Value, encoded_segments: []const u8, segment_count: usize) !bool {
    var current = try self.forceValue(attrs_val);
    var offset: usize = 0;
    var dynamic_i: usize = 0;
    for (0..segment_count) |segment_index| {
        const tag = encoded_segments[offset];
        offset += 1;
        const name_id: InternId = switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => name: {
                if (current.discriminant != .attrs) return false;
                const id = readU32(encoded_segments, offset);
                offset += 4;
                break :name id;
            },
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => name: {
                const name_val = try self.forceValue(dynamic_names[dynamic_i]);
                if (name_val.discriminant != .string) return error.TypeError;
                dynamic_i += 1;
                if (current.discriminant != .attrs) return false;
                break :name name_val.asInternId();
            },
            else => return error.InvalidBytecode,
        };
        const attr = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return false,
            else => return err,
        };
        if (segment_index + 1 == segment_count) return true;
        current = try self.forceValue(attr);
    }
    return false;
}

pub fn validateAttrs(self: *VM, attrs_val: Value, allow_extra: bool, encoded_names: []const u8, wide: bool) !void {
    const value = try self.forceValue(attrs_val);
    if (value.discriminant != .attrs) return self.typeErrorExpected("attrs", value);
    if (allow_extra) return;

    const entries = try self.heap.getAttrs(value.asObjectId());
    const stride: usize = if (wide) 4 else 2;
    for (entries) |entry| {
        var found = false;
        var offset: usize = 0;
        while (offset < encoded_names.len) : (offset += stride) {
            const name_id = readInternId(encoded_names, offset, wide);
            if (entry.name == name_id) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnexpectedAttribute;
    }
}

pub fn lookupWith(self: *VM, name_id: InternId, scope_count: u8) !void {
    const start = self.sp - scope_count;
    const scopes = self.stack.items[start..self.sp];

    for (scopes) |scope| {
        const attrs_val = try self.forceValue(scope);
        if (attrs_val.discriminant != .attrs) return error.TypeError;

        const attr_val = self.heap.getAttrValue(attrs_val.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => continue,
            else => return err,
        };

        const result = try self.forceValue(attr_val);
        self.sp = start;
        try self.push(result);
        return;
    }

    self.sp = start;
    return error.UndefinedVariable;
}
