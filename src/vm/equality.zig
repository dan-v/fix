const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const heap_mod = @import("runtime").heap;
const numeric = @import("runtime").numeric;
const int_mod = @import("runtime").int;

const force = @import("force.zig");
const strings = @import("strings.zig");

const VM = vm_mod.VM;

pub fn valuesEqual(self: *VM, a: Value, b: Value) anyerror!bool {
    var seen: std.ArrayListUnmanaged(EqualityPair) = .empty;
    defer seen.deinit(self.allocator);
    return valuesEqualSeen(self, a, b, &seen);
}

pub fn listContainsValue(self: *VM, needle: Value, items: []const Value) anyerror!bool {
    if (items.len == 0) return false;

    const forced_needle = try force.forceValue(self, needle);
    return valueSliceContainsForcedValue(self, forced_needle, items);
}

pub fn valueSliceContainsForcedValue(self: *VM, forced_needle: Value, items: []const Value) anyerror!bool {
    if (items.len == 0) return false;

    var seen: std.ArrayListUnmanaged(EqualityPair) = .empty;
    defer seen.deinit(self.allocator);

    for (items) |item| {
        seen.clearRetainingCapacity();
        if (try valuesEqualSeenForcedLeft(self, forced_needle, item, &seen)) return true;
    }
    return false;
}

pub const EqualityPair = struct {
    left: Value,
    right: Value,
};

pub fn valuesEqualSeen(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    const va = try force.forceValue(self, a);
    return valuesEqualSeenForcedLeft(self, va, b, seen);
}

pub fn valuesEqualSeenForcedLeft(self: *VM, va: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    const vb = try force.forceValue(self, b);
    return valuesEqualForced(self, va, vb, seen);
}

pub fn valuesEqualForced(self: *VM, va: Value, vb: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    if (int_mod.isAnyInt(va) and int_mod.isAnyInt(vb)) {
        return int_mod.get(va, self.heap) == int_mod.get(vb, self.heap);
    }
    if (numeric.isNumeric(va) and numeric.isNumeric(vb)) {
        return try numeric.toFloat(va, self.heap) == try numeric.toFloat(vb, self.heap);
    }

    if (isStringComparable(va) and isStringComparable(vb)) {
        return strings.stringTextInternIdsEqual(self, va, vb);
    }
    if (va.kind() != vb.kind()) return false;
    return switch (va.kind()) {
        .null, .bool_false, .bool_true => true,
        .int => va.asInt() == vb.asInt(),
        .boxed_int => (try self.heap.getBoxedInt(va.asObjectId())) == (try self.heap.getBoxedInt(vb.asObjectId())),
        .float => va.asFloat() == vb.asFloat(),
        .list => try listsEqual(self, va, vb, seen),
        .attrs => try attrsEqual(self, va, vb, seen),
        .closure => va.asObjectId() == vb.asObjectId(),
        .builtin => va.asBuiltinId() == vb.asBuiltinId(),
        .builtin_closure => va.asObjectId() == vb.asObjectId(),
        .partial_app => va.asObjectId() == vb.asObjectId(),
        .string, .path, .string_context, .thunk => unreachable,
    };
}

pub const CompareResult = enum { lt, eq, gt };

pub fn listsEqual(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    if (a.asObjectId() == b.asObjectId()) return true;
    if (try equalityPairSeen(self, a, b, seen)) return true;

    // a/b may be nested containers reached via getList (not on the operand
    // stack); root them so their backing slices survive the element forces.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, a);
    force.rootKeep(self, b);

    const a_items = try self.heap.getList(a.asObjectId());
    const b_items = try self.heap.getList(b.asObjectId());
    if (a_items.len != b_items.len) return false;

    for (a_items, b_items) |a_item, b_item| {
        if (!try valuesEqualSeen(self, a_item, b_item, seen)) return false;
    }
    return true;
}

pub fn attrsEqual(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    if (a.asObjectId() == b.asObjectId()) return true;
    if (try equalityPairSeen(self, a, b, seen)) return true;

    // a/b may be nested containers reached via getAttrs (not on the operand
    // stack); root them so a_entries/b_entries survive the value forces in
    // derivationAttrsEqual + the element loop.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, a);
    force.rootKeep(self, b);

    const a_entries = try self.heap.getAttrs(a.asObjectId());
    const b_entries = try self.heap.getAttrs(b.asObjectId());
    if (try derivationAttrsEqual(self, a_entries, b_entries, seen)) |equal| return equal;

    if (a_entries.len != b_entries.len) return false;

    for (a_entries, b_entries) |a_entry, b_entry| {
        if (a_entry.name != b_entry.name) return false;
        if (!try valuesEqualSeen(self, a_entry.value, b_entry.value, seen)) return false;
    }
    return true;
}

pub fn derivationAttrsEqual(
    self: *VM,
    a_entries: []const heap_mod.AttrEntry,
    b_entries: []const heap_mod.AttrEntry,
    seen: *std.ArrayListUnmanaged(EqualityPair),
) !?bool {
    const type_name = try self.intern.intern("type");
    const derivation_type = try self.intern.intern("derivation");

    if (!try attrsHaveDerivationType(self, a_entries, type_name, derivation_type)) return null;
    if (!try attrsHaveDerivationType(self, b_entries, type_name, derivation_type)) return null;

    const out_path_name = try self.intern.intern("outPath");
    const a_out_path = attrValue(a_entries, out_path_name) orelse return null;
    const b_out_path = attrValue(b_entries, out_path_name) orelse return null;

    return try valuesEqualSeen(self, a_out_path, b_out_path, seen);
}

pub fn attrsHaveDerivationType(
    self: *VM,
    entries: []const heap_mod.AttrEntry,
    type_name: InternId,
    derivation_type: InternId,
) !bool {
    const type_value = attrValue(entries, type_name) orelse return false;
    const forced = try force.forceValue(self, type_value);
    if (!isStringComparable(forced)) return false;
    const text_id = try strings.stringTextInternId(self, forced);
    return text_id == derivation_type;
}

pub fn attrValue(entries: []const heap_mod.AttrEntry, name: InternId) ?Value {
    var lo: usize = 0;
    var hi: usize = entries.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = entries[mid];
        if (entry.name == name) return entry.value;
        if (entry.name < name) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    return null;
}

pub fn equalityPairSeen(self: *VM, left: Value, right: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) !bool {
    for (seen.items) |pair| {
        if ((pair.left.idEq(left) and pair.right.idEq(right)) or
            (pair.left.idEq(right) and pair.right.idEq(left)))
        {
            return true;
        }
    }
    try seen.append(self.allocator, .{ .left = left, .right = right });
    return false;
}

pub fn compareValues(self: *VM, a: Value, b: Value) !CompareResult {
    const va = try force.forceValue(self, a);
    const vb = try force.forceValue(self, b);

    switch (va.kind()) {
        .int, .boxed_int => {
            const ai = int_mod.get(va, self.heap);
            if (vb.isFloat()) {
                const af: f64 = @floatFromInt(ai);
                const bf = vb.asFloat();
                if (af < bf) return .lt;
                if (af > bf) return .gt;
                return .eq;
            }
            if (!int_mod.isAnyInt(vb)) return error.TypeError;
            const bi = int_mod.get(vb, self.heap);
            if (ai < bi) return .lt;
            if (ai > bi) return .gt;
            return .eq;
        },
        .float => {
            const af = va.asFloat();
            const bf = try numeric.toFloat(vb, self.heap);
            if (af < bf) return .lt;
            if (af > bf) return .gt;
            return .eq;
        },
        .string, .path, .string_context => {
            if (!isStringComparable(vb) or vb.kind() != va.kind()) return error.TypeError;
            return switch (std.mem.order(u8, self.intern.get(try strings.stringTextInternId(self, va)), self.intern.get(try strings.stringTextInternId(self, vb)))) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
        },
        else => return error.TypeError,
    }
}

pub fn isStringComparable(value: Value) bool {
    return value.isString() or value.isPath() or value.isContextString();
}
