const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const InternId = types.InternId;
const bytecode_mod = @import("../bytecode.zig");

const closures = @import("closures.zig");
const force = @import("force.zig");
const trace = @import("trace.zig");
const vm_builtins = @import("builtins.zig");

const VM = vm_mod.VM;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

pub fn callAttrFunctor(self: *VM, callee: Value) !Value {
    const functor_id = try self.intern.intern("__functor");
    const functor = self.heap.getAttrValue(callee.asObjectId(), functor_id) catch |err| switch (err) {
        error.MissingAttribute => return error.NotCallable,
        else => return err,
    };
    return closures.callValue(self, try force.forceValue(self, functor), callee);
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
    return applyBuiltin(self, closure.builtin_id, args[0 .. closure.args.len + 1]);
}

pub fn getAttrValue(self: *VM, attrs_val: Value, name_id: InternId) !Value {
    const attrs = try force.forceValue(self, attrs_val);
    if (!attrs.isAttrs()) return trace.typeErrorExpected(self, "attrs", attrs);

    // Thread-local inline cache: (heap_token, obj_id, name_id) → raw
    // attr value. Hits skip the binary search inside
    // `heap.getAttrValue`. We still force the cached value — thunks
    // are memoised at the future level, so re-force on a resolved
    // thunk is the fast path. The cache value is the pre-force entry,
    // which keeps invariants identical to the uncached path (caller
    // sees a forced value either way).
    const obj_id = attrs.asObjectId();
    const slot_idx = attrCacheIndex(obj_id, name_id);
    const slot = &attr_cache[slot_idx];
    if (slot.heap_token == self.heap.token and slot.obj_id == obj_id and slot.name_id == name_id) {
        return force.forceValue(self, slot.value);
    }

    const raw = try self.heap.getAttrValue(obj_id, name_id);
    slot.heap_token = self.heap.token;
    slot.obj_id = obj_id;
    slot.name_id = name_id;
    slot.value = raw;
    return force.forceValue(self, raw);
}

const attr_cache_size: usize = 256;

const AttrCacheSlot = struct {
    heap_token: u64 = 0,
    obj_id: types.ObjectId = 0,
    name_id: InternId = 0,
    value: Value = Value.null_val,
};

threadlocal var attr_cache: [attr_cache_size]AttrCacheSlot = @splat(.{});

inline fn attrCacheIndex(obj_id: types.ObjectId, name_id: InternId) usize {
    // Mix obj_id and name_id — same lookup site on the same object
    // hits the same slot, but different lookups on the same object
    // (e.g. `.x` and `.y`) land in different slots.
    const mixed: u64 = (@as(u64, obj_id) *% 0x9E3779B97F4A7C15) ^ @as(u64, name_id);
    return @intCast(mixed % attr_cache_size);
}

pub fn getAttrPathOrValue(self: *VM, attrs_val: Value, default_val: Value, encoded_names: []const u8, wide: bool) !Value {
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (!current.isAttrs()) return force.forceValue(self, default_val);
        const name_id = readInternId(encoded_names, offset, wide);
        current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return force.forceValue(self, default_val),
            else => return err,
        };
        current = try force.forceValue(self, current);
    }
    return current;
}

pub fn getAttrPathDynamicOrValue(self: *VM, attrs_val: Value, dynamic_name: Value, default_val: Value, encoded_names: []const u8, wide: bool) !Value {
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (!current.isAttrs()) return force.forceValue(self, default_val);
        const name_id = readInternId(encoded_names, offset, wide);
        current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return force.forceValue(self, default_val),
            else => return err,
        };
        current = try force.forceValue(self, current);
    }
    const name_val = try force.forceValue(self, dynamic_name);
    if (!name_val.isString()) return error.TypeError;
    if (!current.isAttrs()) return force.forceValue(self, default_val);
    const result = self.heap.getAttrValue(current.asObjectId(), name_val.asInternId()) catch |err| switch (err) {
        error.MissingAttribute => return force.forceValue(self, default_val),
        else => return err,
    };
    return force.forceValue(self, result);
}

pub fn getAttrPathMixedOrValue(self: *VM, attrs_val: Value, dynamic_names: []const Value, default_val: Value, encoded_segments: []const u8, segment_count: usize) !Value {
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    var dynamic_i: usize = 0;
    for (0..segment_count) |_| {
        const tag = encoded_segments[offset];
        offset += 1;
        const name_id: InternId = switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => name: {
                if (!current.isAttrs()) return force.forceValue(self, default_val);
                const id = readU32(encoded_segments, offset);
                offset += 4;
                break :name id;
            },
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => name: {
                const name_val = try force.forceValue(self, dynamic_names[dynamic_i]);
                if (!name_val.isString()) return error.TypeError;
                dynamic_i += 1;
                if (!current.isAttrs()) return force.forceValue(self, default_val);
                break :name name_val.asInternId();
            },
            else => return error.InvalidBytecode,
        };
        current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return force.forceValue(self, default_val),
            else => return err,
        };
        current = try force.forceValue(self, current);
    }
    return current;
}

pub fn hasAttrPath(self: *VM, attrs_val: Value, encoded_names: []const u8, wide: bool) !bool {
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (!current.isAttrs()) return false;
        const name_id = readInternId(encoded_names, offset, wide);
        const attr = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return false,
            else => return err,
        };
        if (offset + stride >= encoded_names.len) return true;
        current = try force.forceValue(self, attr);
    }
    return false;
}

pub fn hasAttrPathMixed(self: *VM, attrs_val: Value, dynamic_names: []const Value, encoded_segments: []const u8, segment_count: usize) !bool {
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    var dynamic_i: usize = 0;
    for (0..segment_count) |segment_index| {
        const tag = encoded_segments[offset];
        offset += 1;
        const name_id: InternId = switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => name: {
                if (!current.isAttrs()) return false;
                const id = readU32(encoded_segments, offset);
                offset += 4;
                break :name id;
            },
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => name: {
                const name_val = try force.forceValue(self, dynamic_names[dynamic_i]);
                if (!name_val.isString()) return error.TypeError;
                dynamic_i += 1;
                if (!current.isAttrs()) return false;
                break :name name_val.asInternId();
            },
            else => return error.InvalidBytecode,
        };
        const attr = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return false,
            else => return err,
        };
        if (segment_index + 1 == segment_count) return true;
        current = try force.forceValue(self, attr);
    }
    return false;
}

pub fn validateAttrs(self: *VM, attrs_val: Value, allow_extra: bool, encoded_names: []const u8, wide: bool) !void {
    const value = try force.forceValue(self, attrs_val);
    if (!value.isAttrs()) return trace.typeErrorExpected(self, "attrs", value);
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
    const stack = @import("stack.zig");
    const start = self.sp - scope_count;
    const scopes = self.stack[start..self.sp];

    for (scopes) |scope| {
        const attrs_val = try force.forceValue(self, scope);
        if (!attrs_val.isAttrs()) return error.TypeError;

        const attr_val = self.heap.getAttrValue(attrs_val.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => continue,
            else => return err,
        };

        const result = try force.forceValue(self, attr_val);
        self.sp = start;
        try stack.push(self, result);
        return;
    }

    self.sp = start;
    return error.UndefinedVariable;
}
