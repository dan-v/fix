const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

pub fn builtinGetContext(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.attrs(try self.heap.addAttrs(try contextEntriesForValue(self, value)));
}

pub fn builtinHasContext(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal((try contextEntriesForValue(self, value)).len != 0);
}

pub fn builtinAppendContext(self: anytype, string_arg: Value, context_arg: Value) !Value {
    const string_value = try vm_force.forceValue(self, string_arg);
    if (!strings.isStringLike(string_value)) return error.TypeError;
    const context_value = try vm_force.forceValue(self, context_arg);
    if (!context_value.isAttrs()) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, string_value)) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);
    for (try self.heap.getAttrs(context_value.asObjectId())) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);

    if (entries.items.len == 0) return Value.string(try strings.stringTextInternId(self, string_value));
    return Value.contextString(try self.heap.addContextString(try strings.stringTextInternId(self, string_value), entries.items));
}

pub fn builtinUnsafeDiscardStringContext(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return error.TypeError;
    return Value.string(try strings.stringTextInternId(self, value));
}

pub fn builtinUnsafeDiscardOutputDependency(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return error.TypeError;
    const text_id = try strings.stringTextInternId(self, value);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, value)) |entry| {
        try appendContextEntry(self, &entries, entry.name, try pathContextValue(self));
    }
    if (entries.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

pub fn builtinAddDrvOutputDependencies(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return error.TypeError;
    const text_id = try strings.stringTextInternId(self, value);
    const text = self.intern.get(text_id);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, value)) |entry| {
        const path = self.intern.get(entry.name);
        const context_value = if (std.mem.endsWith(u8, path, ".drv"))
            try allOutputsContextValue(self)
        else
            entry.value;
        try appendContextEntry(self, &entries, entry.name, context_value);
    }
    if (entries.items.len == 0 and std.mem.endsWith(u8, text, ".drv")) {
        try appendContextEntry(self, &entries, text_id, try allOutputsContextValue(self));
    }
    if (entries.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

pub fn contextEntriesForValue(self: anytype, value: Value) ![]const heap_mod.AttrEntry {
    return switch (value.kind()) {
        .string => &.{},
        .path => try singleContextEntry(self, value.asInternId(), try pathContextValue(self)),
        .string_context => (try self.heap.getContextString(value.asObjectId())).context,
        else => error.TypeError,
    };
}

pub fn singleContextEntry(self: anytype, name: InternId, value: Value) ![]const heap_mod.AttrEntry {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, 1);
    entries[0] = .{ .name = name, .value = value };
    return entries;
}

pub fn appendContextEntry(self: anytype, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: InternId, value: Value) !void {
    for (context.items) |*entry| {
        if (entry.name == name) {
            entry.value = try mergeContextValues(self, entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

pub fn mergeContextValues(self: anytype, left: Value, right: Value) !Value {
    const left_forced = try vm_force.forceValue(self, left);
    const right_forced = try vm_force.forceValue(self, right);
    if (left_forced.isAttrs() and right_forced.isAttrs()) {
        return Value.attrs(try mergeContextAttrs(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

pub fn mergeContextAttrs(self: anytype, left_id: ObjectId, right_id: ObjectId) !ObjectId {
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
            const value = try mergeContextAttrValue(self, l.name, l.value, r.value);
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

    return self.heap.addAttrsSorted(merged.items);
}

pub fn mergeContextAttrValue(self: anytype, name: InternId, left: Value, right: Value) !Value {
    if (name == try self.intern.intern("outputs")) return mergeContextOutputs(self, left, right);
    return right;
}

pub fn mergeContextOutputs(self: anytype, left: Value, right: Value) !Value {
    const left_list = try vm_force.forceValue(self, left);
    const right_list = try vm_force.forceValue(self, right);
    if (!left_list.isList() or !right_list.isList()) return error.TypeError;

    var outputs: std.ArrayListUnmanaged(Value) = .empty;
    defer outputs.deinit(self.allocator);

    for (try self.heap.getList(left_list.asObjectId())) |item| try appendUniqueContextOutput(self, &outputs, item);
    for (try self.heap.getList(right_list.asObjectId())) |item| try appendUniqueContextOutput(self, &outputs, item);

    return Value.list(try self.heap.addList(outputs.items));
}

pub fn appendUniqueContextOutput(self: anytype, outputs: *std.ArrayListUnmanaged(Value), item: Value) !void {
    const value = try vm_force.forceValue(self, item);
    if (!strings.isPlainString(value)) return error.TypeError;
    const text = try strings.stringTextInternId(self, value);
    for (outputs.items) |existing| {
        if (try strings.stringTextInternId(self, existing) == text) return;
    }
    try outputs.append(self.allocator, Value.string(text));
}

pub fn pathContextValue(self: anytype) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn allOutputsContextValue(self: anytype) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("allOutputs"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn contextStringWithPath(self: anytype, text_id: InternId) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = text_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextString(text_id, &entries));
}
