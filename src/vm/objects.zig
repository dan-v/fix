const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const heap_mod = @import("../heap.zig");

const force = @import("force.zig");
const stack = @import("stack.zig");
const trace = @import("trace.zig");

const VM = vm_mod.VM;

// ---- data structure builders ----

pub fn buildAttrs(self: *VM, count: u16) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairs(self.stack.items[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

pub fn buildAttrsWithPositions(self: *VM, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairsWithPositions(self.stack.items[start..self.sp], positions);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

pub fn buildList(self: *VM, count: u16) !void {
    const start = self.sp - count;
    const id = try self.heap.addList(self.stack.items[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.list(id));
}

pub fn mergeAttrs(self: *VM, left: Value, right: Value) !Value {
    if (left.discriminant != .attrs) return trace.typeErrorExpected(self, "attrs", left);
    if (right.discriminant != .attrs) return trace.typeErrorExpected(self, "attrs", right);
    return Value.attrs(try self.heap.addMergedAttrs(left.asObjectId(), right.asObjectId()));
}

pub fn mergeAttrsStrict(self: *VM, left: Value, right: Value) !Value {
    if (left.discriminant != .attrs) return trace.typeErrorExpected(self, "attrs", left);
    if (right.discriminant != .attrs) return trace.typeErrorExpected(self, "attrs", right);
    return Value.attrs(try mergeAttrLiteralObjects(self, left.asObjectId(), right.asObjectId()));
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
            const value = try mergeAttrLiteralValue(self, l.value, r.value);
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
    const left_forced = try force.forceValue(self, left);
    const right_forced = try force.forceValue(self, right);
    if (left_forced.discriminant == .attrs and right_forced.discriminant == .attrs) {
        return Value.attrs(try mergeAttrLiteralObjects(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return error.DuplicateAttribute;
}

pub fn concatLists(self: *VM, left: Value, right: Value) !Value {
    if (left.discriminant != .list) return trace.typeErrorExpected(self, "list", left);
    if (right.discriminant != .list) return trace.typeErrorExpected(self, "list", right);
    return Value.list(try self.heap.addConcatenatedLists(left.asObjectId(), right.asObjectId()));
}
