const std = @import("std");
const types = @import("../../types.zig");
const Value = @import("../../value.zig").Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("../../heap.zig");
const shared = @import("shared.zig");
const strings = @import("strings.zig");

const makeBuiltinThunk = shared.makeBuiltinThunk;
const isCallable = strings.isCallable;
const isPlainString = strings.isPlainString;
const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;

pub fn builtinCatAttrs(self: anytype, name_arg: Value, list_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const list = try self.forceValue(list_arg);
    if (!isPlainString(name) or list.discriminant != .list) return error.TypeError;

    var values: std.ArrayListUnmanaged(Value) = .empty;
    defer values.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const attrs = try self.forceValue(item);
        if (attrs.discriminant != .attrs) return error.TypeError;
        const value = self.heap.getAttrValue(attrs.asObjectId(), try stringTextInternId(self, name)) catch |err| switch (err) {
            error.MissingAttribute => continue,
            else => return err,
        };
        try values.append(self.allocator, value);
    }

    return Value.list(try self.heap.addList(values.items));
}

pub fn builtinZipAttrsWith(self: anytype, func_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(func_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const Group = struct {
        name: InternId,
        values: std.ArrayListUnmanaged(Value) = .empty,
    };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer {
        for (groups.items) |*group| group.values.deinit(self.allocator);
        groups.deinit(self.allocator);
    }

    for (try self.heap.getList(list.asObjectId())) |item| {
        const attrs = try self.forceValue(item);
        if (attrs.discriminant != .attrs) return error.TypeError;

        for (try self.heap.getAttrs(attrs.asObjectId())) |entry| {
            const index = groupIndex(groups.items, entry.name) orelse blk: {
                try groups.append(self.allocator, .{ .name = entry.name });
                break :blk groups.items.len - 1;
            };
            try groups.items[index].values.append(self.allocator, entry.value);
        }
    }

    const entries = try self.allocator.alloc(heap_mod.AttrEntry, groups.items.len);
    defer self.allocator.free(entries);
    for (groups.items, entries) |group, *entry| {
        const values = Value.list(try self.heap.addList(group.values.items));
        entry.* = .{
            .name = group.name,
            .value = try makeBuiltinThunk(self, .zipAttrsValue, &.{ func, Value.string(group.name), values }),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

pub fn builtinZipAttrsValue(self: anytype, func_arg: Value, name_arg: Value, values_arg: Value) !Value {
    const partial = try self.callValue(func_arg, name_arg);
    return self.callValue(partial, values_arg);
}

pub fn attrEntryNameIndex(entries: []const heap_mod.AttrEntry, name: InternId) ?usize {
    for (entries, 0..) |entry, i| {
        if (entry.name == name) return i;
    }
    return null;
}

pub fn groupIndex(groups: anytype, name: InternId) ?usize {
    for (groups, 0..) |group, i| {
        if (group.name == name) return i;
    }
    return null;
}

pub fn callComparator(self: anytype, cmp: Value, left: Value, right: Value) !bool {
    const partial = try self.callValue(cmp, left);
    const result = try self.forceValue(try self.callValue(partial, right));
    if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
    return result.discriminant == .bool_true;
}

pub fn genericClosureAppend(
    self: anytype,
    key_name: InternId,
    item: Value,
    result: *std.ArrayListUnmanaged(Value),
    keys: *std.ArrayListUnmanaged(Value),
) !void {
    const forced = try self.forceValue(item);
    if (forced.discriminant != .attrs) return error.TypeError;
    const key = try self.forceValue(try self.heap.getAttrValue(forced.asObjectId(), key_name));
    if (try self.valueSliceContainsForcedValue(key, keys.items)) return;
    try keys.append(self.allocator, key);
    try result.append(self.allocator, item);
}

pub fn builtinAttrNames(self: anytype, arg: Value) !Value {
    const entries = try sortedAttrEntries(self, arg);
    defer self.allocator.free(entries);

    const values = try self.allocator.alloc(Value, entries.len);
    defer self.allocator.free(values);

    for (entries, values) |entry, *value| {
        value.* = Value.string(entry.name);
    }
    return Value.list(try self.heap.addList(values));
}

pub fn builtinAttrValues(self: anytype, arg: Value) !Value {
    const entries = try sortedAttrEntries(self, arg);
    defer self.allocator.free(entries);

    const values = try self.allocator.alloc(Value, entries.len);
    defer self.allocator.free(values);

    for (entries, values) |entry, *value| {
        value.* = entry.value;
    }
    return Value.list(try self.heap.addList(values));
}

pub fn sortedAttrEntries(self: anytype, arg: Value) ![]heap_mod.AttrEntry {
    const value = try self.forceValue(arg);
    if (value.discriminant != .attrs) return error.TypeError;

    const entries = try self.heap.getAttrs(value.asObjectId());
    const sorted = try self.allocator.dupe(heap_mod.AttrEntry, entries);
    const Comparator = struct {
        pub fn lessThan(vm: @TypeOf(self), a: heap_mod.AttrEntry, b: heap_mod.AttrEntry) bool {
            return std.mem.lessThan(u8, vm.intern.get(a.name), vm.intern.get(b.name));
        }
    };
    std.mem.sort(heap_mod.AttrEntry, sorted, self, Comparator.lessThan);
    return sorted;
}

pub fn builtinHasAttr(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const attrs = try self.forceValue(attrs_arg);
    if (name.discriminant != .string or attrs.discriminant != .attrs) return error.TypeError;

    _ = self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()) catch |err| switch (err) {
        error.MissingAttribute => return Value.boolVal(false),
        else => return err,
    };
    return Value.boolVal(true);
}

pub fn builtinGetAttr(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const attrs = try self.forceValue(attrs_arg);
    if (name.discriminant != .string or attrs.discriminant != .attrs) return error.TypeError;

    return self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()));
}

pub fn builtinElemAt(self: anytype, list_arg: Value, index_arg: Value) !Value {
    const list = try self.forceValue(list_arg);
    const index = try self.forceValue(index_arg);
    if (list.discriminant != .list or index.discriminant != .int) return error.TypeError;
    if (index.asInt() < 0) return error.IndexOutOfBounds;

    const items = try self.heap.getList(list.asObjectId());
    const i: usize = @intCast(index.asInt());
    if (i >= items.len) return error.IndexOutOfBounds;
    return self.forceValue(items[i]);
}

pub fn builtinElem(self: anytype, needle: Value, list_arg: Value) !Value {
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    return Value.boolVal(try self.listContainsValue(needle, items));
}

pub fn builtinSeq(self: anytype, first: Value, second: Value) !Value {
    _ = try self.forceValue(first);
    return self.forceValue(second);
}

pub fn builtinDeepSeq(self: anytype, first: Value, second: Value) !Value {
    try self.forceDeep(first);
    return self.forceValue(second);
}

pub fn builtinAll(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_false) return Value.boolVal(false);
    }
    return Value.boolVal(true);
}

pub fn builtinAny(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_true) return Value.boolVal(true);
    }
    return Value.boolVal(false);
}

pub fn builtinFilter(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_true) try out.append(self.allocator, item);
    }

    return Value.list(try self.heap.addList(out.items));
}

pub fn builtinMap(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    if (!try isCallable(self, func)) return error.NotCallable;
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const out = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(out);

    for (items, out) |item, *mapped| {
        mapped.* = try makeBuiltinThunk(self, .mapValue, &.{ func, item });
    }
    return Value.list(try self.heap.addList(out));
}

pub fn builtinMapValue(self: anytype, func_arg: Value, item_arg: Value) !Value {
    const func = try self.forceValue(func_arg);
    return self.callValue(func, item_arg);
}

pub fn builtinConcatMap(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const mapped = try self.forceValue(try self.callValue(func, item));
        if (mapped.discriminant != .list) return error.TypeError;
        try out.appendSlice(self.allocator, try self.heap.getList(mapped.asObjectId()));
    }
    return Value.list(try self.heap.addList(out.items));
}

pub fn builtinMapAttrs(self: anytype, fn_arg: Value, attrs_arg: Value) !Value {
    const attrs = try self.forceValue(attrs_arg);
    if (attrs.discriminant != .attrs) return error.TypeError;

    const attr_entries = try self.heap.getAttrs(attrs.asObjectId());
    const out = try self.allocator.alloc(heap_mod.AttrEntry, attr_entries.len);
    defer self.allocator.free(out);

    for (attr_entries, out) |entry, *mapped| {
        mapped.* = .{
            .name = entry.name,
            .value = try makeBuiltinThunk(self, .mapAttrValue, &.{ fn_arg, Value.string(entry.name), entry.value }),
        };
    }
    return Value.attrs(try self.heap.addAttrs(out));
}

pub fn builtinMapAttrValue(self: anytype, func_arg: Value, name_arg: Value, value_arg: Value) !Value {
    const func = try self.forceValue(func_arg);
    const partial = try self.callValue(func, name_arg);
    return self.callValue(partial, value_arg);
}

pub fn builtinGenList(self: anytype, fn_arg: Value, count_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    const count = try self.forceValue(count_arg);
    if (count.discriminant != .int or count.asInt() < 0) return error.TypeError;

    const len: usize = @intCast(count.asInt());
    const out = try self.allocator.alloc(Value, len);
    defer self.allocator.free(out);

    for (out, 0..) |*value, i| {
        value.* = try makeBuiltinThunk(self, .mapValue, &.{ func, Value.int(@intCast(i)) });
    }
    return Value.list(try self.heap.addList(out));
}

pub fn builtinSort(self: anytype, cmp_arg: Value, list_arg: Value) !Value {
    const cmp = try self.forceValue(cmp_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const sorted = try self.allocator.dupe(Value, items);
    defer self.allocator.free(sorted);

    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        var j = i;
        while (j > 0 and try callComparator(self, cmp, sorted[j], sorted[j - 1])) : (j -= 1) {
            std.mem.swap(Value, &sorted[j], &sorted[j - 1]);
        }
    }

    return Value.list(try self.heap.addList(sorted));
}

pub fn builtinPartition(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    var right: std.ArrayListUnmanaged(Value) = .empty;
    defer right.deinit(self.allocator);
    var wrong: std.ArrayListUnmanaged(Value) = .empty;
    defer wrong.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_true) {
            try right.append(self.allocator, item);
        } else {
            try wrong.append(self.allocator, item);
        }
    }

    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("right"), .value = Value.list(try self.heap.addList(right.items)) },
        .{ .name = try self.intern.intern("wrong"), .value = Value.list(try self.heap.addList(wrong.items)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn builtinGroupBy(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const Group = struct {
        name: InternId,
        items: std.ArrayListUnmanaged(Value) = .empty,
    };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer {
        for (groups.items) |*group| group.items.deinit(self.allocator);
        groups.deinit(self.allocator);
    }

    for (try self.heap.getList(list.asObjectId())) |item| {
        const key = try self.forceValue(try self.callValue(func, item));
        if (!isPlainString(key)) return error.TypeError;
        const key_id = try stringTextInternId(self, key);
        const index = groupIndex(groups.items, key_id) orelse blk: {
            try groups.append(self.allocator, .{ .name = key_id });
            break :blk groups.items.len - 1;
        };
        try groups.items[index].items.append(self.allocator, item);
    }

    const entries = try self.allocator.alloc(heap_mod.AttrEntry, groups.items.len);
    defer self.allocator.free(entries);
    for (groups.items, entries) |group, *entry| {
        entry.* = .{
            .name = group.name,
            .value = Value.list(try self.heap.addList(group.items.items)),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

pub fn builtinGenericClosure(self: anytype, arg: Value) !Value {
    const attrs = try self.forceValue(arg);
    if (attrs.discriminant != .attrs) return error.TypeError;

    const start_set = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("startSet")));
    const operator = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("operator")));
    if (start_set.discriminant != .list) return error.TypeError;

    var result: std.ArrayListUnmanaged(Value) = .empty;
    defer result.deinit(self.allocator);
    var keys: std.ArrayListUnmanaged(Value) = .empty;
    defer keys.deinit(self.allocator);

    const key_name = try self.intern.intern("key");
    for (try self.heap.getList(start_set.asObjectId())) |item| {
        try genericClosureAppend(self, key_name, item, &result, &keys);
    }

    var index: usize = 0;
    while (index < result.items.len) : (index += 1) {
        const produced = try self.forceValue(try self.callValue(operator, result.items[index]));
        if (produced.discriminant != .list) return error.TypeError;
        for (try self.heap.getList(produced.asObjectId())) |item| {
            try genericClosureAppend(self, key_name, item, &result, &keys);
        }
    }

    return Value.list(try self.heap.addList(result.items));
}

pub fn builtinFunctionArgs(self: anytype, arg: Value) !Value {
    const func = try self.forceValue(arg);
    if (func.discriminant == .builtin or func.discriminant == .builtin_closure) {
        return Value.attrs(try self.heap.addAttrs(&.{}));
    }
    if (func.discriminant != .closure) return error.TypeError;

    const closure = try self.heap.getClosure(func.asObjectId());
    const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
    return Value.attrs(try self.heap.addAttrs(ch.function_args));
}

pub fn builtinUnsafeGetAttrPos(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const attrs = try self.forceValue(attrs_arg);
    if (!isPlainString(name) or attrs.discriminant != .attrs) return error.TypeError;
    const object_id = attrs.asObjectId();
    const name_id = try stringTextInternId(self, name);
    _ = self.heap.getAttrValue(object_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return Value.null_val,
        else => return err,
    };

    const pos = self.heap.getAttrPos(object_id, name_id) orelse return Value.null_val;
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("column"),
            .value = try makeBuiltinThunk(self, .constantValue, &.{Value.int(@intCast(pos.column))}),
        },
        .{
            .name = try self.intern.intern("file"),
            .value = Value.string(pos.file),
        },
        .{
            .name = try self.intern.intern("line"),
            .value = try makeBuiltinThunk(self, .constantValue, &.{Value.int(@intCast(pos.line))}),
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn builtinFoldlStrict(self: anytype, op_arg: Value, nul_arg: Value, list_arg: Value) !Value {
    const op = try self.forceValue(op_arg);
    var acc = try self.forceValue(nul_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const partial = try self.callValue(op, acc);
        acc = try self.forceValue(try self.callValue(partial, item));
    }

    return acc;
}

pub fn builtinRemoveAttrs(self: anytype, attrs_arg: Value, names_arg: Value) !Value {
    const attrs = try self.forceValue(attrs_arg);
    const names = try self.forceValue(names_arg);
    if (attrs.discriminant != .attrs or names.discriminant != .list) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    const attr_entries = try self.heap.getAttrs(attrs.asObjectId());
    for (attr_entries) |entry| {
        if (!try stringListContainsIntern(self, names.asObjectId(), entry.name)) {
            try entries.append(self.allocator, entry);
        }
    }

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

pub fn builtinIntersectAttrs(self: anytype, left_arg: Value, right_arg: Value) !Value {
    const left = try self.forceValue(left_arg);
    const right = try self.forceValue(right_arg);
    if (left.discriminant != .attrs or right.discriminant != .attrs) return error.TypeError;

    const left_entries = try self.heap.getAttrs(left.asObjectId());
    const right_entries = try self.heap.getAttrs(right.asObjectId());

    var entries = try std.ArrayListUnmanaged(heap_mod.AttrEntry).initCapacity(self.allocator, @min(left_entries.len, right_entries.len));
    defer entries.deinit(self.allocator);

    var left_i: usize = 0;
    var right_i: usize = 0;
    while (left_i < left_entries.len and right_i < right_entries.len) {
        const left_entry = left_entries[left_i];
        const right_entry = right_entries[right_i];
        if (left_entry.name < right_entry.name) {
            left_i += 1;
        } else if (left_entry.name > right_entry.name) {
            right_i += 1;
        } else {
            entries.appendAssumeCapacity(right_entry);
            left_i += 1;
            right_i += 1;
        }
    }

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

pub fn stringListContainsIntern(self: anytype, list_id: ObjectId, needle: InternId) !bool {
    const items = try self.heap.getList(list_id);
    for (items) |item| {
        const value = try self.forceValue(item);
        if (!isPlainString(value)) return error.TypeError;
        if (try stringTextInternId(self, value) == needle) return true;
    }
    return false;
}
