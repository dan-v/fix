const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = @import("../opcode.zig");
const OpCode = opcode.OpCode;
const chunk = @import("../chunk.zig");
const Chunk = chunk.Chunk;
const thunk_mod = @import("../thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const heap_mod = @import("../heap.zig");
const Closure = heap_mod.Closure;
const numeric = @import("../runtime/numeric.zig");
const source_paths = @import("../runtime/source_path.zig");
const vm_builtins = @import("builtins.zig");
const diagnostic = @import("../diagnostic.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

pub fn valuesEqual(self: *VM, a: Value, b: Value) anyerror!bool {
    var seen: std.ArrayListUnmanaged(EqualityPair) = .empty;
    defer seen.deinit(self.allocator);
    return self.valuesEqualSeen(a, b, &seen);
}

pub fn listContainsValue(self: *VM, needle: Value, items: []const Value) anyerror!bool {
    if (items.len == 0) return false;

    const forced_needle = try self.forceValue(needle);
    return self.valueSliceContainsForcedValue(forced_needle, items);
}

pub fn valueSliceContainsForcedValue(self: *VM, forced_needle: Value, items: []const Value) anyerror!bool {
    if (items.len == 0) return false;

    var seen: std.ArrayListUnmanaged(EqualityPair) = .empty;
    defer seen.deinit(self.allocator);

    for (items) |item| {
        seen.clearRetainingCapacity();
        if (try self.valuesEqualSeenForcedLeft(forced_needle, item, &seen)) return true;
    }
    return false;
}

pub const EqualityPair = struct {
    left: Value,
    right: Value,
};

pub fn valuesEqualSeen(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    const va = try self.forceValue(a);
    return self.valuesEqualSeenForcedLeft(va, b, seen);
}

pub fn valuesEqualSeenForcedLeft(self: *VM, va: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    const vb = try self.forceValue(b);
    return self.valuesEqualForced(va, vb, seen);
}

pub fn valuesEqualForced(self: *VM, va: Value, vb: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    if (numeric.isNumeric(va) and numeric.isNumeric(vb)) {
        return try numeric.toFloat(va) == try numeric.toFloat(vb);
    }

    if (isStringComparable(va) and isStringComparable(vb)) {
        return self.stringTextInternIdsEqual(va, vb);
    }
    if (va.discriminant != vb.discriminant) return false;
    return switch (va.discriminant) {
        .null, .bool_false, .bool_true => true,
        .int => va.asInt() == vb.asInt(),
        .float => va.asFloat() == vb.asFloat(),
        .list => try self.listsEqual(va, vb, seen),
        .attrs => try self.attrsEqual(va, vb, seen),
        .closure => va.asObjectId() == vb.asObjectId(),
        .builtin => va.asBuiltinId() == vb.asBuiltinId(),
        .builtin_closure => va.asObjectId() == vb.asObjectId(),
        .string, .path, .string_context, .thunk, .cell => unreachable,
    };
}

pub const CompareResult = enum { lt, eq, gt };

pub fn listsEqual(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    if (a.asObjectId() == b.asObjectId()) return true;
    if (try self.equalityPairSeen(a, b, seen)) return true;

    const a_items = try self.heap.getList(a.asObjectId());
    const b_items = try self.heap.getList(b.asObjectId());
    if (a_items.len != b_items.len) return false;

    for (a_items, b_items) |a_item, b_item| {
        if (!try self.valuesEqualSeen(a_item, b_item, seen)) return false;
    }
    return true;
}

pub fn attrsEqual(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
    if (a.asObjectId() == b.asObjectId()) return true;
    if (try self.equalityPairSeen(a, b, seen)) return true;

    const a_entries = try self.heap.getAttrs(a.asObjectId());
    const b_entries = try self.heap.getAttrs(b.asObjectId());
    if (try self.derivationAttrsEqual(a_entries, b_entries, seen)) |equal| return equal;

    if (a_entries.len != b_entries.len) return false;

    for (a_entries, b_entries) |a_entry, b_entry| {
        if (a_entry.name != b_entry.name) return false;
        if (!try self.valuesEqualSeen(a_entry.value, b_entry.value, seen)) return false;
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

    if (!try self.attrsHaveDerivationType(a_entries, type_name, derivation_type)) return null;
    if (!try self.attrsHaveDerivationType(b_entries, type_name, derivation_type)) return null;

    const out_path_name = try self.intern.intern("outPath");
    const a_out_path = attrValue(a_entries, out_path_name) orelse return null;
    const b_out_path = attrValue(b_entries, out_path_name) orelse return null;

    return try self.valuesEqualSeen(a_out_path, b_out_path, seen);
}

pub fn attrsHaveDerivationType(
    self: *VM,
    entries: []const heap_mod.AttrEntry,
    type_name: InternId,
    derivation_type: InternId,
) !bool {
    const type_value = attrValue(entries, type_name) orelse return false;
    const forced = try self.forceValue(type_value);
    if (!isStringComparable(forced)) return false;
    const text_id = try self.stringTextInternId(forced);
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
        if ((pair.left.memoEq(left, self.intern) and pair.right.memoEq(right, self.intern)) or
            (pair.left.memoEq(right, self.intern) and pair.right.memoEq(left, self.intern)))
        {
            return true;
        }
    }
    try seen.append(self.allocator, .{ .left = left, .right = right });
    return false;
}

pub fn compareValues(self: *VM, a: Value, b: Value) !CompareResult {
    const va = try self.forceValue(a);
    const vb = try self.forceValue(b);

    switch (va.discriminant) {
        .int => {
            const ai = va.asInt();
            if (vb.discriminant == .float) {
                const af: f64 = @floatFromInt(ai);
                const bf = vb.asFloat();
                if (af < bf) return .lt;
                if (af > bf) return .gt;
                return .eq;
            }
            if (vb.discriminant != .int) return error.TypeError;
            if (ai < vb.asInt()) return .lt;
            if (ai > vb.asInt()) return .gt;
            return .eq;
        },
        .float => {
            const af = va.asFloat();
            const bf = try numeric.toFloat(vb);
            if (af < bf) return .lt;
            if (af > bf) return .gt;
            return .eq;
        },
        .string, .path, .string_context => {
            if (!isStringComparable(vb) or vb.discriminant != va.discriminant) return error.TypeError;
            return switch (std.mem.order(u8, self.intern.get(try self.stringTextInternId(va)), self.intern.get(try self.stringTextInternId(vb)))) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
        },
        else => return error.TypeError,
    }
}

pub fn isStringComparable(value: Value) bool {
    return value.discriminant == .string or value.discriminant == .path or value.discriminant == .string_context;
}
