//! Nix attribute-set builtins: attrNames/attrValues, hasAttr/getAttr,
//! mapAttrs, removeAttrs, intersectAttrs, catAttrs, and zipAttrsWith.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

const makeBuiltinThunk = shared.makeBuiltinThunk;
const isPlainString = strings.isPlainString;
const stringTextInternId = strings.stringTextInternId;

pub fn builtinCatAttrs(self: *VM, name_arg: Value, list_arg: Value) !Value {
    const name = try vm_force.forceValue(self, name_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!isPlainString(name) or !list.isList()) return error.TypeError;

    var values: std.ArrayListUnmanaged(Value) = .empty;
    defer values.deinit(self.allocator);

    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
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

pub fn builtinZipAttrsWith(self: *VM, func_arg: Value, list_arg: Value) !Value {
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
    var group_idx: shared.NameIndex = .{};
    defer group_idx.deinit(self.allocator);

    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const attrs = try vm_force.forceValue(self, item);
        if (!attrs.isAttrs()) return error.TypeError;

        for (try self.heap.materializeAttrs(attrs.asObjectId())) |entry| {
            const index = (try group_idx.find(self.allocator, groups.items, entry.name)) orelse blk: {
                try groups.append(self.allocator, .{ .name = entry.name });
                const idx = groups.items.len - 1;
                try group_idx.record(self.allocator, entry.name, idx);
                break :blk idx;
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

pub fn builtinZipAttrsValue(self: *VM, func_arg: Value, name_arg: Value, values_arg: Value) !Value {
    const partial = try vm_closures.callValue(self, func_arg, name_arg);
    return vm_closures.callValue(self, partial, values_arg);
}

pub fn attrEntryNameIndex(entries: []const heap_mod.AttrEntry, name: InternId) ?usize {
    for (entries, 0..) |entry, i| {
        if (entry.name == name) return i;
    }
    return null;
}

pub fn builtinAttrNames(self: *VM, arg: Value) !Value {
    const entries = try sortedAttrEntries(self, arg);
    defer self.allocator.free(entries);

    const values = try self.allocator.alloc(Value, entries.len);
    defer self.allocator.free(values);

    for (entries, values) |entry, *value| {
        value.* = Value.string(entry.name);
    }
    return Value.list(try self.heap.addList(values));
}

pub fn builtinAttrValues(self: *VM, arg: Value) !Value {
    const entries = try sortedAttrEntries(self, arg);
    defer self.allocator.free(entries);

    const values = try self.allocator.alloc(Value, entries.len);
    defer self.allocator.free(values);

    for (entries, values) |entry, *value| {
        value.* = entry.value;
    }
    return Value.list(try self.heap.addList(values));
}

pub fn sortedAttrEntries(self: *VM, arg: Value) ![]heap_mod.AttrEntry {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) return error.TypeError;

    const entries = try self.heap.materializeAttrs(value.asObjectId());
    const sorted = try self.allocator.dupe(heap_mod.AttrEntry, entries);
    errdefer self.allocator.free(sorted);
    try self.intern.sortByNameLex(self.allocator, heap_mod.AttrEntry, sorted);
    return sorted;
}

pub fn builtinHasAttr(self: *VM, name_arg: Value, attrs_arg: Value) !Value {
    const name = try vm_force.forceValue(self, name_arg);
    const attrs = try vm_force.forceValue(self, attrs_arg);
    if (!name.isString() or !attrs.isAttrs()) return error.TypeError;

    _ = self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()) catch |err| switch (err) {
        error.MissingAttribute => return Value.boolVal(false),
        else => return err,
    };
    return Value.boolVal(true);
}

pub fn builtinGetAttr(self: *VM, name_arg: Value, attrs_arg: Value) !Value {
    const name = try vm_force.forceValue(self, name_arg);
    const attrs = try vm_force.forceValue(self, attrs_arg);
    if (!name.isString() or !attrs.isAttrs()) return error.TypeError;

    return vm_force.forceValue(self, try self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()));
}

pub fn builtinMapAttrs(self: *VM, fn_arg: Value, attrs_arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, attrs_arg);
    if (!attrs.isAttrs()) return error.TypeError;

    const attr_entries = try self.heap.materializeAttrs(attrs.asObjectId());
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
        // `out` preserves the input's order (names copied 1:1 from the
        // already sorted+deduped source attrs), so it is sorted+unique by
        // construction — skip the redundant sort+dedup in `addAttrs`.
        return Value.attrs(try self.heap.addAttrsSorted(out));
    }

    const apply_chunk_id = self.registry.well_known.mapattrs_apply;
    const speculatable = shared.isSpeculatableUserFunc(self, fn_arg);
    for (attr_entries, out) |entry, *mapped| {
        const tid = try self.heap.addBytecodeThunk(apply_chunk_id, &.{ fn_arg, Value.string(entry.name), entry.value });
        if (speculatable) _ = self.scheduler.submit(.{ .force_thunk = tid }, self.workerId());
        mapped.* = .{ .name = entry.name, .value = Value.thunk(tid) };
    }
    // Sorted+unique by construction (see the thunk-path note above).
    return Value.attrs(try self.heap.addAttrsSorted(out));
}

pub fn builtinMapAttrValue(self: *VM, func_arg: Value, name_arg: Value, value_arg: Value) !Value {
    const func = try vm_force.forceValue(self, func_arg);
    const partial = try vm_closures.callValue(self, func, name_arg);
    return vm_closures.callValue(self, partial, value_arg);
}

pub fn builtinFunctionArgs(self: *VM, arg: Value) !Value {
    const func = try vm_force.forceValue(self, arg);
    // PAPs wrap merged *value*-lambda chunks, which carry no formal-arg
    // metadata — `functionArgs` of a simple-param lambda is `{}`, same as
    // for builtins.
    if (func.isBuiltin() or func.isBuiltinClosure() or func.isPartialApp()) {
        return Value.attrs(try self.heap.addAttrs(&.{}));
    }
    if (!func.isNixClosure()) return vm_trace.typeErrorExpected(self, "a function", func);

    const closure = try vm_closures.closureRef(self, func);
    const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
    // Carry the formals' source positions so unsafeGetAttrPos works on the
    // result (Nix records a parameter's declaration site).
    if (ch.function_arg_pos.len != 0) {
        return Value.attrs(try self.heap.addAttrsWithPositions(ch.function_args, ch.function_arg_pos));
    }
    return Value.attrs(try self.heap.addAttrs(ch.function_args));
}

pub fn builtinUnsafeGetAttrPos(self: *VM, name_arg: Value, attrs_arg: Value) !Value {
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

pub fn builtinRemoveAttrs(self: *VM, attrs_arg: Value, names_arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, attrs_arg);
    const names = try vm_force.forceValue(self, names_arg);
    if (!attrs.isAttrs() or !names.isList()) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    // Resolve names into a prefix cache at most once. Stop extending the
    // prefix after a match so unused later names remain lazy.
    var resolved: std.ArrayListUnmanaged(InternId) = .empty;
    defer resolved.deinit(self.allocator);

    const attrs_id = attrs.asObjectId();
    const names_id = names.asObjectId();
    const names_len = try self.heap.getListLen(names_id);
    const n = (try self.heap.materializeAttrs(attrs_id)).len;
    var i: usize = 0;
    outer: while (i < n) : (i += 1) {
        const entry = (try self.heap.materializeAttrs(attrs_id))[i];
        for (resolved.items) |name_id| {
            if (name_id == entry.name) continue :outer;
        }
        while (resolved.items.len < names_len) {
            const item = try self.heap.getListItem(names_id, resolved.items.len);
            const value = try vm_force.forceValue(self, item);
            if (!isPlainString(value)) return error.TypeError;
            const name_id = try stringTextInternId(self, value);
            try resolved.append(self.allocator, name_id);
            if (name_id == entry.name) continue :outer;
        }
        try entries.append(self.allocator, entry);
    }

    // Surviving entries are a subsequence of the (sorted, unique) input,
    // so the output is sorted+unique by construction — skip the re-sort.
    // Nix keeps each surviving attr's source position; carry them over when the
    // source has any (falling through to the fast sorted path otherwise).
    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);
    for (entries.items) |entry| {
        if (self.heap.getAttrPos(attrs_id, entry.name)) |pos| {
            try positions.append(self.allocator, .{ .name = entry.name, .pos = pos });
        }
    }
    if (positions.items.len == 0) return Value.attrs(try self.heap.addAttrsSorted(entries.items));
    return Value.attrs(try self.heap.addAttrsWithPositions(entries.items, positions.items));
}

/// Binary search a sorted attr-entry slice by name (heap invariant:
/// entries are sorted by InternId, no duplicates).
fn sortedEntryIndex(entries: []const heap_mod.AttrEntry, name: InternId) ?usize {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const n = entries[mid].name;
        if (n == name) return mid;
        if (n < name) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// Size ratio beyond which `intersectAttrs` walks the smaller operand and
/// binary-searches the larger instead of merge-walking both. This bounds work
/// for highly skewed sets such as function arguments intersected with `pkgs`.
const intersection_skew = 8;

pub fn builtinIntersectAttrs(self: *VM, left_arg: Value, right_arg: Value) !Value {
    const left = try vm_force.forceValue(self, left_arg);
    const right = try vm_force.forceValue(self, right_arg);
    if (!left.isAttrs() or !right.isAttrs()) return error.TypeError;

    const left_entries = try self.heap.materializeAttrs(left.asObjectId());
    const right_entries = try self.heap.materializeAttrs(right.asObjectId());

    var entries = try std.ArrayListUnmanaged(heap_mod.AttrEntry).initCapacity(self.allocator, @min(left_entries.len, right_entries.len));
    defer entries.deinit(self.allocator);

    // All three paths emit the same set — the RIGHT entry for every name
    // present in both — walking names in ascending order, so the output
    // is identical regardless of which strategy runs.
    if (left_entries.len / intersection_skew > right_entries.len) {
        for (right_entries) |re| {
            if (sortedEntryIndex(left_entries, re.name) != null) entries.appendAssumeCapacity(re);
        }
    } else if (right_entries.len / intersection_skew > left_entries.len) {
        for (left_entries) |le| {
            if (sortedEntryIndex(right_entries, le.name)) |ri| entries.appendAssumeCapacity(right_entries[ri]);
        }
    } else {
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
    }

    // `left_entries` and `right_entries` are sorted by name (heap
    // invariant); each strategy preserves order and adds no
    // duplicates, so `entries.items` is sorted+unique by construction.
    // The emitted entries are the RIGHT ones, so their positions (which Nix
    // reports) come from the right operand.
    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);
    const right_id = right.asObjectId();
    for (entries.items) |entry| {
        if (self.heap.getAttrPos(right_id, entry.name)) |pos| {
            try positions.append(self.allocator, .{ .name = entry.name, .pos = pos });
        }
    }
    if (positions.items.len == 0) return Value.attrs(try self.heap.addAttrsSorted(entries.items));
    return Value.attrs(try self.heap.addAttrsWithPositions(entries.items, positions.items));
}
