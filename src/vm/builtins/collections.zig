const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const numeric = @import("runtime").numeric;
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

/// A hashcode for a forced `genericClosure` key that respects
/// `valuesEqualForced`: equal keys MUST share a hashcode (collisions are
/// fine — they fall back to an exact compare). Numerics hash by their
/// float value (so `1 == 1.0` and the int/float merge rule both hold),
/// with `-0.0` normalized to `0.0`. String-likes hash by their canonical
/// text intern id (string equality is id equality). Compound keys
/// (lists/attrs/closures/...) share one sentinel bucket so they are
/// always exhaustively compared — identical to the old linear scan, just
/// without inflating the simple-key buckets.
fn gcKeyMix(tag: u64, x: u64) u64 {
    var h = (tag *% 0x9E3779B97F4A7C15) ^ x;
    h *%= 0xC2B2AE3D27D4EB4F;
    return h ^ (h >> 31);
}

fn gcKeyHashCode(self: anytype, key: Value) !u64 {
    if (numeric.isNumeric(key)) {
        const f = try numeric.toFloat(key, self.heap);
        const norm: f64 = if (f == 0.0) 0.0 else f; // collapse -0.0 -> 0.0
        return gcKeyMix(1, @bitCast(norm));
    }
    if (vm_equality.isStringComparable(key)) {
        return gcKeyMix(2, try stringTextInternId(self, key));
    }
    return switch (key.kind()) {
        .null => 3,
        .bool_false => 4,
        .bool_true => 5,
        else => 6, // compound: shared sentinel bucket, exhaustively compared
    };
}

/// O(1)-amortized dedup set for `genericClosure` keys, replacing the old
/// O(N) linear scan per insert (O(N²) over the closure). The module
/// system's `genericClosure` over the full module set (N≈3800 on a NixOS
/// toplevel) spent ~114M cy on that scan, all on the serial critical
/// path. Buckets keyed by `gcKeyHashCode`; membership confirmed by the
/// same `valuesEqualForced` the linear scan used, so the result is
/// byte-identical.
pub const GcKeySet = struct {
    index: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(Value)) = .empty,
    seen: std.ArrayListUnmanaged(vm_equality.EqualityPair) = .empty,

    pub fn deinit(self: *GcKeySet, allocator: std.mem.Allocator) void {
        var it = self.index.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.index.deinit(allocator);
        self.seen.deinit(allocator);
    }

    /// True if `key` was already present (skip it); otherwise inserts it
    /// and returns false.
    fn contains(self: *GcKeySet, vm: anytype, key: Value) !bool {
        const hc = try gcKeyHashCode(vm, key);
        const gop = try self.index.getOrPut(vm.allocator, hc);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |stored| {
            self.seen.clearRetainingCapacity();
            if (try vm_equality.valuesEqualForced(vm, key, stored, &self.seen)) return true;
        }
        try gop.value_ptr.append(vm.allocator, key);
        return false;
    }
};

pub fn genericClosureAppend(
    self: anytype,
    key_name: InternId,
    item: Value,
    result: *std.ArrayListUnmanaged(Value),
    keys: *GcKeySet,
) !void {
    const forced = try vm_force.forceValue(self, item);
    if (!forced.isAttrs()) return error.TypeError;
    const key = try vm_force.forceValue(self, try self.heap.getAttrValue(forced.asObjectId(), key_name));
    if (try keys.contains(self, key)) return;
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

    // Reuse the genlist_apply chunk (`tail_call upvalues[0] upvalues[1]`).
    // The chunk doesn't care that the second upvalue is a list element
    // instead of an integer index — it just calls `func arg`. This swap
    // drops the per-element `BuiltinClosureObject` that the old
    // `mapValue`-wrapped path allocated alongside the Thunk; now we
    // have one Object per element instead of two.
    const apply_chunk_id = self.registry.well_known.genlist_apply;
    const speculatable = isSpeculatableUserFunc(self, func);
    for (items, out) |item, *mapped| {
        const tid = try self.heap.addBytecodeThunk(apply_chunk_id, &.{ func, item });
        if (speculatable) _ = self.scheduler.submit(.{ .force_thunk = tid }, self.workerId());
        mapped.* = Value.thunk(tid);
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
    // GC: `out` accumulates elements of NEW lists produced by `func` — not
    // reachable through any argument — and holds them across later iterations'
    // forces. Root each produced list. (`func`/`list` and its elements are
    // covered by the arg roots.)
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    for (items) |item| {
        const mapped = try vm_force.forceValue(self, try vm_closures.callValue(self, func, item));
        if (!mapped.isList()) return error.TypeError;
        vm_force.rootKeep(self, mapped);
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

    // Two paths. When `fn_arg` is already a callable value (closure,
    // builtin, builtin-closure, callable attrs), use the
    // `mapattrs_apply` bytecode-thunk path — one Object per entry
    // instead of two (BuiltinClosureObject + Thunk).
    //
    // When `fn_arg` is still a thunk, we can't safely pre-force it
    // here: recursive-attrset eval can route a self-reference
    // through the function being mapped, and forcing eagerly would
    // blackhole. Fall back to the `.mapAttrValue` builtin-closure
    // path; that handler forces `func` on the forcing fiber, where
    // the claim identity differs from ours.
    if (fn_arg.isThunk()) {
        for (attr_entries, out) |entry, *mapped| {
            mapped.* = .{
                .name = entry.name,
                .value = try makeBuiltinThunk(self, .mapAttrValue, &.{ fn_arg, Value.string(entry.name), entry.value }),
            };
        }
        return Value.attrs(try self.heap.addAttrs(out));
    }

    const apply_chunk_id = self.registry.well_known.mapattrs_apply;
    const speculatable = isSpeculatableUserFunc(self, fn_arg);
    for (attr_entries, out) |entry, *mapped| {
        const tid = try self.heap.addBytecodeThunk(apply_chunk_id, &.{ fn_arg, Value.string(entry.name), entry.value });
        if (speculatable) _ = self.scheduler.submit(.{ .force_thunk = tid }, self.workerId());
        mapped.* = .{ .name = entry.name, .value = Value.thunk(tid) };
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
        // Abandon a speculative genList of a never-demanded result rather
        // than allocate the whole list (see force.specBailRequested).
        if (i & 8191 == 0 and vm_force.specBailRequested(self)) return error.SpeculativeBail;
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
    var keys: GcKeySet = .{};
    defer keys.deinit(self.allocator);

    // GC: `result` (a Zig-side list) holds items from `start_set` (reachable
    // through the arg) and from NEW lists `operator` produces, read back across
    // later forces. Root each produced list so its items — and thus `result`'s
    // contents and the `keys` set — stay alive.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);

    const key_name = try self.intern.intern("key");
    for (try self.heap.getList(start_set.asObjectId())) |item| {
        try genericClosureAppend(self, key_name, item, &result, &keys);
    }

    var index: usize = 0;
    while (index < result.items.len) : (index += 1) {
        const produced = try vm_force.forceValue(self, try vm_closures.callValue(self, operator, result.items[index]));
        if (!produced.isList()) return error.TypeError;
        vm_force.rootKeep(self, produced);
        for (try self.heap.getList(produced.asObjectId())) |item| {
            try genericClosureAppend(self, key_name, item, &result, &keys);
        }
    }

    return Value.list(try self.heap.addList(result.items));
}

pub fn builtinFunctionArgs(self: anytype, arg: Value) !Value {
    const func = try vm_force.forceValue(self, arg);
    // PAPs wrap merged *value*-lambda chunks, which carry no formal-arg
    // metadata — `functionArgs` of a simple-param lambda is `{}`, same as
    // for builtins.
    if (func.isBuiltin() or func.isBuiltinClosure() or func.isPartialApp()) {
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
    // GC: `acc` becomes a NEW value produced by `op` (not reachable through any
    // argument) and is held across the next iteration's call/force. Root the
    // running accumulator so it survives collection between iterations. (`op`
    // and `list`/its elements are covered by the arg roots; the seed `nul_arg`
    // is an arg until the first iteration overwrites `acc`.)
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    for (items) |item| {
        const partial = try vm_closures.callValue(self, op, acc);
        acc = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, item));
        vm_force.rootKeep(self, acc);
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

    // `left_entries` and `right_entries` are sorted by name (heap
    // invariant); the merge-walk preserves order and adds no
    // duplicates, so `entries.items` is sorted+unique by construction.
    return Value.attrs(try self.heap.addAttrsSorted(entries.items));
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

const std_testing = std.testing;
const renderForTest = @import("../../eval/test_helpers.zig").renderForTest;

test "map filter all any concatMap and mapAttrs on empty inputs" {
    const mapped = try renderForTest("builtins.map (x: x + 1) [ ]");
    defer std_testing.allocator.free(mapped);
    try std_testing.expectEqualStrings("[ ]", mapped);

    const filtered = try renderForTest("builtins.filter (x: x) [ ]");
    defer std_testing.allocator.free(filtered);
    try std_testing.expectEqualStrings("[ ]", filtered);

    const all_empty = try renderForTest("builtins.all (x: x) [ ]");
    defer std_testing.allocator.free(all_empty);
    try std_testing.expectEqualStrings("true", all_empty);

    const any_empty = try renderForTest("builtins.any (x: x) [ ]");
    defer std_testing.allocator.free(any_empty);
    try std_testing.expectEqualStrings("false", any_empty);

    const concat_mapped = try renderForTest("builtins.concatMap (x: [ x ]) [ ]");
    defer std_testing.allocator.free(concat_mapped);
    try std_testing.expectEqualStrings("[ ]", concat_mapped);

    const mapped_attrs = try renderForTest("builtins.mapAttrs (name: value: value) { }");
    defer std_testing.allocator.free(mapped_attrs);
    try std_testing.expectEqualStrings("{ }", mapped_attrs);
}

test "map rejects a non-callable function argument" {
    try std_testing.expectError(error.NotCallable, renderForTest("builtins.map 1 [ 1 ]"));
}

test "concatMap rejects a function whose result is not a list" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.concatMap (x: x) [ 1 ]"));
}

test "elemAt reports out-of-bounds and negative indices" {
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.elemAt [ 1 2 ] 2"));
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.elemAt [ 1 2 ] (-1)"));
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.elemAt [ ] 0"));
}

test "elem on an empty list is false without forcing the needle" {
    const result = try renderForTest("builtins.elem 1 [ ]");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("false", result);
}

test "hasAttr and getAttr reject non-attrs and non-string names" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.hasAttr \"a\" 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.hasAttr 1 { a = 1; }"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.getAttr \"a\" 1"));
}

test "getAttr on a missing name raises rather than returning null" {
    try std_testing.expectError(error.MissingAttribute, renderForTest("builtins.getAttr \"missing\" { a = 1; }"));
}

test "seq and deepSeq force their first argument's effects before returning the second" {
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.seq (builtins.throw \"boom\") 1"));
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.deepSeq (builtins.throw \"boom\") 1"));

    // deepSeq forces nested structure (seq only forces WHNF).
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.deepSeq { a = builtins.throw \"boom\"; } 1"));
    const seq_shallow = try renderForTest("builtins.seq { a = builtins.throw \"boom\"; } 1");
    defer std_testing.allocator.free(seq_shallow);
    try std_testing.expectEqualStrings("1", seq_shallow);
}

test "zipAttrsWith unions keys across mismatched attribute sets" {
    const names = try renderForTest("builtins.attrNames (builtins.zipAttrsWith (name: values: values) [ { a = 1; } { b = 2; } { a = 3; c = 4; } ])");
    defer std_testing.allocator.free(names);
    try std_testing.expectEqualStrings("[ \"a\" \"b\" \"c\" ]", names);

    const a_values = try renderForTest("builtins.length ((builtins.zipAttrsWith (name: values: values) [ { a = 1; } { b = 2; } { a = 3; c = 4; } ]).a)");
    defer std_testing.allocator.free(a_values);
    try std_testing.expectEqualStrings("2", a_values);

    const c_values = try renderForTest("builtins.length ((builtins.zipAttrsWith (name: values: values) [ { a = 1; } { b = 2; } { a = 3; c = 4; } ]).c)");
    defer std_testing.allocator.free(c_values);
    try std_testing.expectEqualStrings("1", c_values);
}

test "zipAttrsWith and catAttrs reject non-attrs list elements" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.zipAttrsWith (name: values: values) [ 1 ]"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.catAttrs \"a\" [ 1 ]"));
}

test "attrNames and attrValues on an empty attrset" {
    const names = try renderForTest("builtins.attrNames { }");
    defer std_testing.allocator.free(names);
    try std_testing.expectEqualStrings("[ ]", names);

    const values = try renderForTest("builtins.attrValues { }");
    defer std_testing.allocator.free(values);
    try std_testing.expectEqualStrings("[ ]", values);
}

test "sort partition groupBy and genericClosure on empty inputs" {
    const sorted = try renderForTest("builtins.sort (a: b: a < b) [ ]");
    defer std_testing.allocator.free(sorted);
    try std_testing.expectEqualStrings("[ ]", sorted);

    const partitioned = try renderForTest("builtins.toJSON (builtins.partition (x: x) [ ])");
    defer std_testing.allocator.free(partitioned);
    try std_testing.expectEqualStrings("\"{\\\"right\\\":[],\\\"wrong\\\":[]}\"", partitioned);

    const grouped = try renderForTest("builtins.groupBy (x: \"k\") [ ]");
    defer std_testing.allocator.free(grouped);
    try std_testing.expectEqualStrings("{ }", grouped);

    const closure_empty = try renderForTest("builtins.genericClosure { startSet = [ ]; operator = item: [ ]; }");
    defer std_testing.allocator.free(closure_empty);
    try std_testing.expectEqualStrings("[ ]", closure_empty);
}

test "sort partition and groupBy reject non-list arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.sort (a: b: a < b) 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.partition (x: x) 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.groupBy (x: \"k\") 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.genericClosure { startSet = 1; operator = item: [ ]; }"));
}

test "foldl' on an empty list returns the seed without calling the operator" {
    const result = try renderForTest("builtins.foldl' (a: b: builtins.throw \"boom\") 5 [ ]");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("5", result);
}

test "functionArgs rejects non-function values" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.functionArgs 1"));
}

test "functionArgs on builtins and partial applications reports no formal args" {
    const builtin_args = try renderForTest("builtins.functionArgs builtins.head");
    defer std_testing.allocator.free(builtin_args);
    try std_testing.expectEqualStrings("{ }", builtin_args);

    const partial_args = try renderForTest("builtins.functionArgs (builtins.elemAt [ 1 ])");
    defer std_testing.allocator.free(partial_args);
    try std_testing.expectEqualStrings("{ }", partial_args);
}

test "unsafeGetAttrPos returns null for a missing attribute" {
    const result = try renderForTest("builtins.unsafeGetAttrPos \"missing\" { a = 1; }");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("null", result);
}

test "removeAttrs and intersectAttrs reject non-attrs and non-list arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.removeAttrs 1 [ \"a\" ]"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.removeAttrs { a = 1; } 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.intersectAttrs 1 { a = 1; }"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.intersectAttrs { a = 1; } 1"));
}

test "removeAttrs and intersectAttrs on empty attrsets" {
    const removed = try renderForTest("builtins.removeAttrs { } [ \"a\" ]");
    defer std_testing.allocator.free(removed);
    try std_testing.expectEqualStrings("{ }", removed);

    const intersected = try renderForTest("builtins.intersectAttrs { } { a = 1; }");
    defer std_testing.allocator.free(intersected);
    try std_testing.expectEqualStrings("{ }", intersected);
}
