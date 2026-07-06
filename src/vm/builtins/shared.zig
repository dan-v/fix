const std = @import("std");
const Value = @import("runtime").value.Value;
const BuiltinId = @import("runtime").builtins.BuiltinId;
const InternId = @import("runtime").types.InternId;
const ObjectId = @import("runtime").types.ObjectId;
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

/// Cycle-guard for the recursive JSON writers (`toJSON`, structured
/// derivation env). A stack of (kind, id) pairs; `enterJsonObject` refuses a
/// re-entry into an object already on the stack so a self-referential
/// list/attrset raises `RecursiveThunk` instead of looping. Callers push on
/// descent and `pop()` on the way out.
pub const SeenJsonKind = enum { list, attrs };

pub const SeenJsonObject = struct {
    kind: SeenJsonKind,
    id: ObjectId,
};

pub fn enterJsonObject(self: anytype, kind: SeenJsonKind, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenJsonObject)) !bool {
    for (seen.items) |item| {
        if (item.kind == kind and item.id == id) return false;
    }
    try seen.append(self.allocator, .{ .kind = kind, .id = id });
    return true;
}

pub fn makeBuiltinClosure(self: anytype, builtin_id: u16, args: []const Value) !Value {
    return Value.builtinClosure(try self.heap.addBuiltinClosure(builtin_id, args));
}

pub fn makeBuiltinThunk(self: anytype, id: BuiltinId, args: []const Value) !Value {
    return vm_force.makeThunk(self, try makeBuiltinClosure(self, @intFromEnum(id), args));
}

/// Cross-category helper: linear index of a group whose `.name` matches
/// `name`. Used by both `zipAttrsWith` (attrsets) and `groupBy` (lists).
pub fn groupIndex(groups: anytype, name: InternId) ?usize {
    for (groups, 0..) |group, i| {
        if (group.name == name) return i;
    }
    return null;
}

/// Cross-category helper: the closure half of
/// `force.isSpeculatableBuiltinClosure`'s map-style branch: speculate iff
/// the user function is a `.closure` whose body chunk is substantial. (That
/// branch also speculates on expensive builtins via `isSpeculatableMapFunc`;
/// this fast path only handles the closure case.) Used by `map`/`genList`
/// (lists) and `mapAttrs` (attrsets).
pub fn isSpeculatableUserFunc(self: anytype, func: Value) bool {
    if (!func.isClosure()) return false;
    const closure = self.heap.getClosure(func.asObjectId()) catch return false;
    const ch = self.registry.get(closure.chunk_id) orelse return false;
    return ch.scheduling.body_is_substantial;
}
