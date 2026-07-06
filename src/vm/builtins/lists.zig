const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const numeric = @import("runtime").numeric;
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const attrsets = @import("attrsets.zig");
const vm_force = @import("../force.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");

const isCallable = strings.isCallable;
const isPlainString = strings.isPlainString;
const stringTextInternId = strings.stringTextInternId;
const attrEntryNameIndex = attrsets.attrEntryNameIndex;

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
    vm_force.forceListAccelerate(self, list_id, lists);
    // gc: re-fetch — the outer range may move across the force
    const n = lists.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const list_item = try self.heap.getListItem(list_id, i);
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

    // gc: re-fetch — range may move across the force
    const list_id = value.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
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

    // gc: pass the list id (not a raw slice) — the range may move across the
    // per-element equality forces inside listContainsValue.
    return Value.boolVal(try vm_equality.listContainsValue(self, needle, list.asObjectId()));
}

// seq/deepSeq are general forcing operations, not list-specific, but they
// live here grouped as sequence operations.
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

    // gc: re-fetch — range may move across the force
    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
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

    // gc: re-fetch — range may move across the force
    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (result.asBool()) return Value.boolVal(true);
    }
    return Value.boolVal(false);
}

/// Below this length `filter` uses its plain serial predicate loop; at or above
/// it (and with work-first on) the per-element predicate applications — the
/// expensive part when the predicate forces deep config (e.g. `filter (f:
/// f.enable) (attrValues config.environment.etc)`) — are exposed as work-first
/// split-and-steal so idle workers evaluate them in parallel. `filter` has no
/// short-circuit, so it forces every predicate anyway → demand-safe, no waste.
const filter_work_first_min: usize = 16;

pub fn builtinFilter(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);

    if (self.scheduler.workFirst() and n >= filter_work_first_min) {
        // GC: root the input list + the predicate-application list across the
        // work-first forces (raw slices held over allocation/collection).
        const gc_roots = vm_force.rootsBegin(self);
        defer vm_force.rootsEnd(self, gc_roots);
        vm_force.rootKeep(self, list);
        // One apply-thunk per element: `genlist_apply` = `tail_call pred item`.
        const preds = try self.allocator.alloc(Value, n);
        defer self.allocator.free(preds);
        const apply_chunk_id = self.registry.well_known.genlist_apply;
        var b: usize = 0;
        while (b < n) : (b += 1) {
            const item = try self.heap.getListItem(list_id, b);
            preds[b] = Value.thunk(try self.heap.addBytecodeThunk(apply_chunk_id, &.{ pred, item }));
        }
        const preds_id = try self.heap.addList(preds);
        vm_force.rootKeep(self, Value.list(preds_id));
        // Expose the predicate evaluations as stealable work, then read the
        // (now often already-computed) results in order to preserve output order.
        vm_force.forceListAccelerate(self, preds_id, try self.heap.getList(preds_id));
        var out: std.ArrayListUnmanaged(Value) = .empty;
        defer out.deinit(self.allocator);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const result = try vm_force.forceValue(self, try self.heap.getListItem(preds_id, i));
            if (!result.isBool()) return error.TypeError;
            if (result.asBool()) try out.append(self.allocator, try self.heap.getListItem(list_id, i));
        }
        return Value.list(try self.heap.addList(out.items));
    }

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    // gc: re-fetch — range may move across the force
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
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
    const speculatable = shared.isSpeculatableUserFunc(self, func);
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
    vm_force.forceListAccelerate(self, list_id, items);
    // GC: `out` accumulates elements of NEW lists produced by `func` — not
    // reachable through any argument — and holds them across later iterations'
    // forces. Root each produced list. (`func`/`list` and its elements are
    // covered by the arg roots.)
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    // gc: re-fetch — the input range may move across the force
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const mapped = try vm_force.forceValue(self, try vm_closures.callValue(self, func, item));
        if (!mapped.isList()) return error.TypeError;
        vm_force.rootKeep(self, mapped);
        try out.appendSlice(self.allocator, try self.heap.getList(mapped.asObjectId()));
    }
    return Value.list(try self.heap.addList(out.items));
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
    const speculatable = shared.isSpeculatableUserFunc(self, func);
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

pub fn builtinSort(self: anytype, cmp_arg: Value, list_arg: Value) !Value {
    const cmp = try vm_force.forceValue(self, cmp_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
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
    vm_force.forceListAccelerate(self, list_id, items);
    // gc: re-fetch — range may move across the force
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
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
    vm_force.forceListAccelerate(self, list_id, items);
    // gc: re-fetch — range may move across the force
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const key = try vm_force.forceValue(self, try vm_closures.callValue(self, func, item));
        if (!isPlainString(key)) return error.TypeError;
        const key_id = try stringTextInternId(self, key);
        const index = shared.groupIndex(groups.items, key_id) orelse blk: {
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
    // gc: re-fetch — range may move across genericClosureAppend's force
    const start_id = start_set.asObjectId();
    const start_n = try self.heap.getListLen(start_id);
    var s: usize = 0;
    while (s < start_n) : (s += 1) {
        const item = try self.heap.getListItem(start_id, s);
        try genericClosureAppend(self, key_name, item, &result, &keys);
    }

    var index: usize = 0;
    while (index < result.items.len) : (index += 1) {
        const produced = try vm_force.forceValue(self, try vm_closures.callValue(self, operator, result.items[index]));
        if (!produced.isList()) return error.TypeError;
        vm_force.rootKeep(self, produced);
        // gc: re-fetch — range may move across genericClosureAppend's force
        const produced_id = produced.asObjectId();
        const produced_n = try self.heap.getListLen(produced_id);
        var p: usize = 0;
        while (p < produced_n) : (p += 1) {
            const item = try self.heap.getListItem(produced_id, p);
            try genericClosureAppend(self, key_name, item, &result, &keys);
        }
    }

    return Value.list(try self.heap.addList(result.items));
}

pub fn builtinFoldlStrict(self: anytype, op_arg: Value, nul_arg: Value, list_arg: Value) !Value {
    const op = try vm_force.forceValue(self, op_arg);
    var acc = try vm_force.forceValue(self, nul_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    // GC: `acc` becomes a NEW value produced by `op` (not reachable through any
    // argument) and is held across the next iteration's call/force. Root the
    // running accumulator so it survives collection between iterations. (`op`
    // and `list`/its elements are covered by the arg roots; the seed `nul_arg`
    // is an arg until the first iteration overwrites `acc`.)
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    // gc: re-fetch — range may move across the force
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const partial = try vm_closures.callValue(self, op, acc);
        acc = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, item));
        vm_force.rootKeep(self, acc);
    }

    return acc;
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

test "seq and deepSeq force their first argument's effects before returning the second" {
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.seq (builtins.throw \"boom\") 1"));
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.deepSeq (builtins.throw \"boom\") 1"));

    // deepSeq forces nested structure (seq only forces WHNF).
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.deepSeq { a = builtins.throw \"boom\"; } 1"));
    const seq_shallow = try renderForTest("builtins.seq { a = builtins.throw \"boom\"; } 1");
    defer std_testing.allocator.free(seq_shallow);
    try std_testing.expectEqualStrings("1", seq_shallow);
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
