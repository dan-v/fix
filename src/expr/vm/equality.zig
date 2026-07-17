//! Value equality (`==`) and ordering (`<`): recursive structural comparison over
//! lists and attrsets with cycle-pair tracking, the derivation `outPath` fast
//! path, and the numeric/string coercion rules.
const std = @import("std");
const vm_mod = @import("context.zig");
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

pub fn listContainsValue(self: *VM, needle: Value, list_id: heap_mod.ObjectId) anyerror!bool {
    if ((try self.heap.getListLen(list_id)) == 0) return false;

    const forced_needle = try force.forceValue(self, needle);
    return valueSliceContainsForcedValue(self, forced_needle, list_id);
}

pub fn valueSliceContainsForcedValue(self: *VM, forced_needle: Value, list_id: heap_mod.ObjectId) anyerror!bool {
    const n = try self.heap.getListLen(list_id);
    if (n == 0) return false;

    var seen: std.ArrayListUnmanaged(EqualityPair) = .empty;
    defer seen.deinit(self.allocator);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        // gc: re-fetch — range may move across the force
        const item = try self.heap.getListItem(list_id, i);
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
        .closure => va.bits == vb.bits,
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

    const a_id = a.asObjectId();
    const b_id = b.asObjectId();
    const a_len = try self.heap.getListLen(a_id);
    const b_len = try self.heap.getListLen(b_id);
    if (a_len != b_len) return false;

    var i: usize = 0;
    while (i < a_len) : (i += 1) {
        // gc: re-fetch — ranges may move across valuesEqualSeen's force
        const a_item = try self.heap.getListItem(a_id, i);
        const b_item = try self.heap.getListItem(b_id, i);
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

    const a_id = a.asObjectId();
    const b_id = b.asObjectId();
    if (try derivationAttrsEqual(self, a_id, b_id, seen)) |equal| return equal;

    const a_len = (try self.heap.getAttrs(a_id)).len;
    const b_len = (try self.heap.getAttrs(b_id)).len;
    if (a_len != b_len) return false;

    var i: usize = 0;
    while (i < a_len) : (i += 1) {
        // gc: re-fetch — ranges may move across valuesEqualSeen's force
        const a_entry = (try self.heap.getAttrs(a_id))[i];
        const b_entry = (try self.heap.getAttrs(b_id))[i];
        if (a_entry.name != b_entry.name) return false;
        if (!try valuesEqualSeen(self, a_entry.value, b_entry.value, seen)) return false;
    }
    return true;
}

pub fn derivationAttrsEqual(
    self: *VM,
    a_id: heap_mod.ObjectId,
    b_id: heap_mod.ObjectId,
    seen: *std.ArrayListUnmanaged(EqualityPair),
) !?bool {
    const type_name = try self.intern.intern("type");
    const derivation_type = try self.intern.intern("derivation");

    if (!try attrsHaveDerivationType(self, a_id, type_name, derivation_type)) return null;
    if (!try attrsHaveDerivationType(self, b_id, type_name, derivation_type)) return null;

    const out_path_name = try self.intern.intern("outPath");
    // gc: re-fetch — ranges may move across attrsHaveDerivationType's force
    const a_out_path = attrValue(try self.heap.getAttrs(a_id), out_path_name) orelse return null;
    const b_out_path = attrValue(try self.heap.getAttrs(b_id), out_path_name) orelse return null;

    return try valuesEqualSeen(self, a_out_path, b_out_path, seen);
}

pub fn attrsHaveDerivationType(
    self: *VM,
    id: heap_mod.ObjectId,
    type_name: InternId,
    derivation_type: InternId,
) !bool {
    const type_value = attrValue(try self.heap.getAttrs(id), type_name) orelse return false;
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
        // Lexicographic list ordering (Nix's stable `lexical-lists-comparison`):
        // compare element-wise; the first non-equal pair decides, else the
        // shorter list is less. Equal elements are skipped via `valuesEqual`,
        // so equal-but-unorderable elements (e.g. two identical attrsets) don't
        // spuriously error — only a genuinely differing, unorderable pair does,
        // exactly as Nix's element-wise `<` would.
        .list => {
            if (!vb.isList()) return error.TypeError;
            const ida = va.asObjectId();
            const idb = vb.asObjectId();
            const na = try self.heap.getListLen(ida);
            const nb = try self.heap.getListLen(idb);
            const n = @min(na, nb);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                // Re-fetch each element by index: comparing an earlier element
                // forces values, which can move the list segment under GC.
                const ea = try self.heap.getListItem(ida, i);
                const eb = try self.heap.getListItem(idb, i);
                if (try valuesEqual(self, ea, eb)) continue;
                return try compareValues(self, ea, eb);
            }
            if (na < nb) return .lt;
            if (na > nb) return .gt;
            return .eq;
        },
        else => return error.TypeError,
    }
}

pub fn isStringComparable(value: Value) bool {
    return value.isString() or value.isPath() or value.isContextString();
}
