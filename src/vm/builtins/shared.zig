const std = @import("std");
const Value = @import("runtime").value.Value;
const BuiltinId = @import("runtime").builtins.BuiltinId;
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
