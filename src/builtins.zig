//! Evaluator-owned builtin values.

const InternTable = @import("intern.zig").InternTable;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const AttrEntry = heap_mod.AttrEntry;
const Value = @import("value.zig").Value;

pub const BuiltinId = enum(u16) {
    toString = 0,
};

pub fn buildAttrSet(intern: *InternTable, heap: *ObjectHeap) !Value {
    const to_string_name = try intern.intern("toString");
    const entries = [_]AttrEntry{
        .{
            .name = to_string_name,
            .value = Value.builtin(@intFromEnum(BuiltinId.toString)),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}
