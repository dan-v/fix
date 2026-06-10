const std = @import("std");
const types = @import("../../runtime/types.zig");
const Value = @import("../../runtime/value.zig").Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("../../runtime/heap.zig");
const int_mod = @import("../../runtime/int.zig");
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

const makeBuiltinThunk = shared.makeBuiltinThunk;
const isCallable = strings.isCallable;
const isPlainString = strings.isPlainString;
const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;

pub fn builtinCatAttrs(self: anytype, name_arg: Value, list_arg: Value) !Value {
    const name = try vm_force.forceValue(self, name_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!isPlainString(name) or !list.isList()) return error.TypeError;

    var values: std.ArrayListUnmanaged(Value) = .empty;
    defer values.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const attrs = try vm_force.forceValue(self, item);
        if (!attrs.isAttrs()) return error.TypeError;
        const value = self.heap.getAttrValue(attrs.asObjectId(), try stringTextInternId(self, name)) catch |err| switch (err) {
            error.MissingAttribute => continue,
            else => return err,
        };
        try values.append(self.allocator, value);
    }

    return Value.list(try self.heap.addList(values.items));
}

pub fn builtinZipAttrsWith(self: anytype, func_arg: Value, list_arg: Value) !Value {
    const func = try vm_force.forceValue(self, func_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

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
        const attrs = try vm_force.forceValue(self, item);
        if (!attrs.isAttrs()) return error.TypeError;

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
    const partial = try vm_closures.callValue(self, func_arg, name_arg);
    return vm_closures.callValue(self, partial, values_arg);
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
    const partial = try vm_closures.callValue(self, cmp, left);
    const result = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, right));
    if (!result.isBool()) return error.TypeError;
    return result.asBool();
}

pub fn genericClosureAppend(
    self: anytype,
    key_name: InternId,
    item: Value,
    result: *std.ArrayListUnmanaged(Value),
    keys: *std.ArrayListUnmanaged(Value),
) !void {
    const forced = try vm_force.forceValue(self, item);
    if (!forced.isAttrs()) return error.TypeError;
    const key = try vm_force.forceValue(self, try self.heap.getAttrValue(forced.asObjectId(), key_name));
    if (try vm_equality.valueSliceContainsForcedValue(self, key, keys.items)) return;
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
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) return error.TypeError;

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
    const name = try vm_force.forceValue(self, name_arg);
    const attrs = try vm_force.forceValue(self, attrs_arg);
    if (!name.isString() or !attrs.isAttrs()) return error.TypeError;

    _ = self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()) catch |err| switch (err) {
        error.MissingAttribute => return Value.boolVal(false),
        else => return err,
    };
    return Value.boolVal(true);
}

pub fn builtinGetAttr(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try vm_force.forceValue(self, name_arg);
    const attrs = try vm_force.forceValue(self, attrs_arg);
    if (!name.isString() or !attrs.isAttrs()) return error.TypeError;

    return vm_force.forceValue(self, try self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()));
}

pub fn builtinElemAt(self: anytype, list_arg: Value, index_arg: Value) !Value {
    const list = try vm_force.forceValue(self, list_arg);
    const index = try vm_force.forceValue(self, index_arg);
    if (!list.isList() or !int_mod.isAnyInt(index)) return error.TypeError;
    const idx = int_mod.get(index, self.heap);
    if (idx < 0) return error.IndexOutOfBounds;

    const items = try self.heap.getList(list.asObjectId());
    if (idx > std.math.maxInt(usize)) return error.IndexOutOfBounds;
    const i: usize = @intCast(idx);
    if (i >= items.len) return error.IndexOutOfBounds;
    return vm_force.forceValue(self, items[i]);
}

pub fn builtinElem(self: anytype, needle: Value, list_arg: Value) !Value {
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    return Value.boolVal(try vm_equality.listContainsValue(self, needle, items));
}

pub fn builtinSeq(self: anytype, first: Value, second: Value) !Value {
    _ = try vm_force.forceValue(self, first);
    return vm_force.forceValue(self, second);
}

pub fn builtinDeepSeq(self: anytype, first: Value, second: Value) !Value {
    try vm_force.forceDeep(self, first);
    return vm_force.forceValue(self, second);
}

pub fn builtinAll(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (!result.asBool()) return Value.boolVal(false);
    }
    return Value.boolVal(true);
}

pub fn builtinAny(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (result.asBool()) return Value.boolVal(true);
    }
    return Value.boolVal(false);
}

pub fn builtinFilter(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, items);
    for (items) |item| {
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (result.asBool()) try out.append(self.allocator, item);
    }

    return Value.list(try self.heap.addList(out.items));
}

pub fn builtinMap(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try vm_force.forceValue(self, fn_arg);
    if (!try isCallable(self, func)) return error.NotCallable;
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const out = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(out);

    for (items, out) |item, *mapped| {
        mapped.* = try makeBuiltinThunk(self, .mapValue, &.{ func, item });
    }
    return Value.list(try self.heap.addList(out));
}

pub fn builtinMapValue(self: anytype, func_arg: Value, item_arg: Value) !Value {
    const func = try vm_force.forceValue(self, func_arg);
    return vm_closures.callValue(self, func, item_arg);
}

pub fn builtinConcatMap(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try vm_force.forceValue(self, fn_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, items);
    for (items) |item| {
        const mapped = try vm_force.forceValue(self, try vm_closures.callValue(self, func, item));
        if (!mapped.isList()) return error.TypeError;
        try out.appendSlice(self.allocator, try self.heap.getList(mapped.asObjectId()));
    }
    return Value.list(try self.heap.addList(out.items));
}

pub fn builtinMapAttrs(self: anytype, fn_arg: Value, attrs_arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, attrs_arg);
    if (!attrs.isAttrs()) return error.TypeError;

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
    const func = try vm_force.forceValue(self, func_arg);
    const partial = try vm_closures.callValue(self, func, name_arg);
    return vm_closures.callValue(self, partial, value_arg);
}

pub fn builtinGenList(self: anytype, fn_arg: Value, count_arg: Value) !Value {
    const func = try vm_force.forceValue(self, fn_arg);
    const count = try vm_force.forceValue(self, count_arg);
    if (!int_mod.isAnyInt(count)) return error.TypeError;
    const count_i = int_mod.get(count, self.heap);
    if (count_i < 0 or count_i > std.math.maxInt(usize)) return error.TypeError;

    const len: usize = @intCast(count_i);
    const out = try self.allocator.alloc(Value, len);
    defer self.allocator.free(out);

    // Each element is a bytecode thunk over the registry's genlist_apply
    // stub chunk with upvalues `[func, index]`. This skips the
    // per-element `builtin_closure` object that the old `mapValue`-wrapped
    // path allocated — halving the Object slots used by genList output.
    //
    // The old path piggybacked on `makeThunk`'s `shouldSpeculateClosure`
    // hook for `mapValue` builtin closures, which checked whether the
    // wrapped user function was a substantial closure and submitted a
    // speculative force task if so. Replicate that check here so helpers
    // still pre-compute heavy genList bodies on the side.
    const apply_chunk_id = self.registry.well_known.genlist_apply;
    const speculatable = isSpeculatableUserFunc(self, func);
    for (out, 0..) |*value, i| {
        const tid = try self.heap.addBytecodeThunk(apply_chunk_id, &.{ func, Value.int(@intCast(i)) });
        if (speculatable) _ = self.scheduler.submit(.{ .force_thunk = tid }, self.workerId());
        value.* = Value.thunk(tid);
    }
    return Value.list(try self.heap.addList(out));
}

/// Mirror of `force.isSpeculatableBuiltinClosure`'s `.mapValue` branch.
/// Keep behaviour: speculate iff the user function is a `.closure` whose
/// body chunk is marked `speculatable`.
fn isSpeculatableUserFunc(self: anytype, func: Value) bool {
    if (!func.isClosure()) return false;
    const closure = self.heap.getClosure(func.asObjectId()) catch return false;
    const ch = self.registry.get(closure.chunk_id) orelse return false;
    return ch.scheduling.body_is_substantial;
}

pub fn builtinSort(self: anytype, cmp_arg: Value, list_arg: Value) !Value {
    const cmp = try vm_force.forceValue(self, cmp_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, items);
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
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    var right: std.ArrayListUnmanaged(Value) = .empty;
    defer right.deinit(self.allocator);
    var wrong: std.ArrayListUnmanaged(Value) = .empty;
    defer wrong.deinit(self.allocator);

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, items);
    for (items) |item| {
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (result.asBool()) {
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
    const func = try vm_force.forceValue(self, fn_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const Group = struct {
        name: InternId,
        items: std.ArrayListUnmanaged(Value) = .empty,
    };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer {
        for (groups.items) |*group| group.items.deinit(self.allocator);
        groups.deinit(self.allocator);
    }

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, items);
    for (items) |item| {
        const key = try vm_force.forceValue(self, try vm_closures.callValue(self, func, item));
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
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;

    const start_set = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("startSet")));
    const operator = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("operator")));
    if (!start_set.isList()) return error.TypeError;

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
        const produced = try vm_force.forceValue(self, try vm_closures.callValue(self, operator, result.items[index]));
        if (!produced.isList()) return error.TypeError;
        for (try self.heap.getList(produced.asObjectId())) |item| {
            try genericClosureAppend(self, key_name, item, &result, &keys);
        }
    }

    return Value.list(try self.heap.addList(result.items));
}

pub fn builtinFunctionArgs(self: anytype, arg: Value) !Value {
    const func = try vm_force.forceValue(self, arg);
    if (func.isBuiltin() or func.isBuiltinClosure()) {
        return Value.attrs(try self.heap.addAttrs(&.{}));
    }
    if (!func.isClosure()) return error.TypeError;

    const closure = try self.heap.getClosure(func.asObjectId());
    const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
    return Value.attrs(try self.heap.addAttrs(ch.function_args));
}

pub fn builtinUnsafeGetAttrPos(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try vm_force.forceValue(self, name_arg);
    const attrs = try vm_force.forceValue(self, attrs_arg);
    if (!isPlainString(name) or !attrs.isAttrs()) return error.TypeError;
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
    const op = try vm_force.forceValue(self, op_arg);
    var acc = try vm_force.forceValue(self, nul_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, items);
    for (items) |item| {
        const partial = try vm_closures.callValue(self, op, acc);
        acc = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, item));
    }

    return acc;
}

pub fn builtinRemoveAttrs(self: anytype, attrs_arg: Value, names_arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, attrs_arg);
    const names = try vm_force.forceValue(self, names_arg);
    if (!attrs.isAttrs() or !names.isList()) return error.TypeError;

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
    const left = try vm_force.forceValue(self, left_arg);
    const right = try vm_force.forceValue(self, right_arg);
    if (!left.isAttrs() or !right.isAttrs()) return error.TypeError;

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
        const value = try vm_force.forceValue(self, item);
        if (!isPlainString(value)) return error.TypeError;
        if (try stringTextInternId(self, value) == needle) return true;
    }
    return false;
}
