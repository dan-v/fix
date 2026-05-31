//! Evaluator-owned builtin values.

const InternTable = @import("intern.zig").InternTable;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const AttrEntry = heap_mod.AttrEntry;
const Value = @import("value.zig").Value;

pub const BuiltinId = enum(u16) {
    toString = 0,
    isAttrs = 1,
    isList = 2,
    isString = 3,
    isInt = 4,
    isBool = 5,
    isNull = 6,
};

pub fn buildAttrSet(intern: *InternTable, heap: *ObjectHeap) !Value {
    const entries = [_]AttrEntry{
        .{
            .name = try intern.intern("toString"),
            .value = Value.builtin(@intFromEnum(BuiltinId.toString)),
        },
        .{
            .name = try intern.intern("isAttrs"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isAttrs)),
        },
        .{
            .name = try intern.intern("isList"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isList)),
        },
        .{
            .name = try intern.intern("isString"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isString)),
        },
        .{
            .name = try intern.intern("isInt"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isInt)),
        },
        .{
            .name = try intern.intern("isBool"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isBool)),
        },
        .{
            .name = try intern.intern("isNull"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isNull)),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}
