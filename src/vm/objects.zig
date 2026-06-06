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

// ---- data structure builders ----

pub fn buildAttrs(self: *VM, count: u16) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairs(self.stack.items[start..self.sp]);
    self.sp = start;
    try self.push(Value.attrs(id));
}

pub fn buildAttrsWithPositions(self: *VM, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairsWithPositions(self.stack.items[start..self.sp], positions);
    self.sp = start;
    try self.push(Value.attrs(id));
}

pub fn buildList(self: *VM, count: u16) !void {
    const start = self.sp - count;
    const id = try self.heap.addList(self.stack.items[start..self.sp]);
    self.sp = start;
    try self.push(Value.list(id));
}

pub fn mergeAttrs(self: *VM, left: Value, right: Value) !Value {
    if (left.discriminant != .attrs) return self.typeErrorExpected("attrs", left);
    if (right.discriminant != .attrs) return self.typeErrorExpected("attrs", right);
    return Value.attrs(try self.heap.addMergedAttrs(left.asObjectId(), right.asObjectId()));
}

pub fn mergeAttrsStrict(self: *VM, left: Value, right: Value) !Value {
    if (left.discriminant != .attrs) return self.typeErrorExpected("attrs", left);
    if (right.discriminant != .attrs) return self.typeErrorExpected("attrs", right);
    return Value.attrs(try self.mergeAttrLiteralObjects(left.asObjectId(), right.asObjectId()));
}

pub fn mergeAttrLiteralObjects(self: *VM, left_id: types.ObjectId, right_id: types.ObjectId) anyerror!types.ObjectId {
    const left = try self.heap.getAttrs(left_id);
    const right = try self.heap.getAttrs(right_id);

    var merged = try std.ArrayListUnmanaged(heap_mod.AttrEntry).initCapacity(self.allocator, left.len + right.len);
    defer merged.deinit(self.allocator);

    var left_i: usize = 0;
    var right_i: usize = 0;
    while (left_i < left.len and right_i < right.len) {
        const l = left[left_i];
        const r = right[right_i];
        if (l.name < r.name) {
            merged.appendAssumeCapacity(l);
            left_i += 1;
        } else if (l.name > r.name) {
            merged.appendAssumeCapacity(r);
            right_i += 1;
        } else {
            const value = try self.mergeAttrLiteralValue(l.value, r.value);
            merged.appendAssumeCapacity(.{ .name = l.name, .value = value });
            left_i += 1;
            right_i += 1;
        }
    }
    while (left_i < left.len) : (left_i += 1) {
        merged.appendAssumeCapacity(left[left_i]);
    }
    while (right_i < right.len) : (right_i += 1) {
        merged.appendAssumeCapacity(right[right_i]);
    }

    return self.heap.addAttrs(merged.items);
}

pub fn mergeAttrLiteralValue(self: *VM, left: Value, right: Value) anyerror!Value {
    const left_forced = try self.forceValue(left);
    const right_forced = try self.forceValue(right);
    if (left_forced.discriminant == .attrs and right_forced.discriminant == .attrs) {
        return Value.attrs(try self.mergeAttrLiteralObjects(left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return error.DuplicateAttribute;
}

pub fn concatLists(self: *VM, left: Value, right: Value) !Value {
    if (left.discriminant != .list) return self.typeErrorExpected("list", left);
    if (right.discriminant != .list) return self.typeErrorExpected("list", right);
    return Value.list(try self.heap.addConcatenatedLists(left.asObjectId(), right.asObjectId()));
}
