const std = @import("std");
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const collections = @import("collections.zig");
const vm_force = @import("../force.zig");

const isPlainString = strings.isPlainString;
const stringTextInternId = strings.stringTextInternId;
const attrEntryNameIndex = collections.attrEntryNameIndex;

pub fn builtinLength(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;
    return Value.int(@intCast(try self.heap.getListLen(value.asObjectId())));
}

pub fn builtinHead(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;
    const items = try self.heap.getList(value.asObjectId());
    if (items.len == 0) return error.IndexOutOfBounds;
    return vm_force.forceValue(self, items[0]);
}

pub fn builtinTail(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;
    const items = try self.heap.getList(value.asObjectId());
    if (items.len == 0) return error.IndexOutOfBounds;
    return Value.list(try self.heap.addList(items[1..]));
}

pub fn builtinConcatLists(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    const list_id = value.asObjectId();
    const lists = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, lists);
    for (lists) |list_item| {
        const list = try vm_force.forceValue(self, list_item);
        if (!list.isList()) return error.TypeError;
        try out.appendSlice(self.allocator, try self.heap.getList(list.asObjectId()));
    }

    return Value.list(try self.heap.addList(out.items));
}

pub fn builtinListToAttrs(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;

    const name_id = try self.intern.intern("name");
    const value_id = try self.intern.intern("value");
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    const items = try self.heap.getList(value.asObjectId());
    for (items) |item| {
        const item_value = try vm_force.forceValue(self, item);
        if (!item_value.isAttrs()) return error.TypeError;

        const name_value = try vm_force.forceValue(self, try self.heap.getAttrValue(item_value.asObjectId(), name_id));
        if (!isPlainString(name_value)) return error.TypeError;
        const name_intern = try stringTextInternId(self, name_value);
        if (attrEntryNameIndex(entries.items, name_intern) != null) continue;

        try entries.append(self.allocator, .{
            .name = name_intern,
            .value = try self.heap.getAttrValue(item_value.asObjectId(), value_id),
        });
    }

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

const std_testing = std.testing;
const renderForTest = @import("../../eval/test_helpers.zig").renderForTest;

test "length head and tail reject non-list arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.length 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.head 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.tail 1"));
}

test "head and tail on an empty list raise index out of bounds" {
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.head [ ]"));
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.tail [ ]"));
}

test "tail on a single-element list returns the empty list" {
    const result = try renderForTest("builtins.tail [ 1 ]");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("[ ]", result);
}

test "concatLists on an empty list and rejects non-list elements" {
    const empty = try renderForTest("builtins.concatLists [ ]");
    defer std_testing.allocator.free(empty);
    try std_testing.expectEqualStrings("[ ]", empty);

    try std_testing.expectError(error.TypeError, renderForTest("builtins.concatLists 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.concatLists [ 1 ]"));
}

test "listToAttrs on an empty list and rejects non-attrs elements" {
    const empty = try renderForTest("builtins.listToAttrs [ ]");
    defer std_testing.allocator.free(empty);
    try std_testing.expectEqualStrings("{ }", empty);

    try std_testing.expectError(error.TypeError, renderForTest("builtins.listToAttrs 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.listToAttrs [ 1 ]"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.listToAttrs [ { name = 1; value = 2; } ]"));
}
