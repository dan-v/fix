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
    isFloat = 7,
    isFunction = 8,
    isPath = 9,
    length = 10,
    head = 11,
    tail = 12,
    attrNames = 13,
    attrValues = 14,
    hasAttr = 15,
    getAttr = 16,
    elemAt = 17,
    typeOf = 18,
    concatLists = 19,
    listToAttrs = 20,
    removeAttrs = 21,
    intersectAttrs = 22,
    elem = 23,
    seq = 24,
    all = 25,
    any = 26,
    filter = 27,
    foldlStrict = 28,
    deepSeq = 29,
    pathExists = 30,
    readFile = 31,
    import = 32,
    readDir = 33,
    readFileType = 34,
    findFile = 35,
};

pub fn arity(id: BuiltinId) u8 {
    return switch (id) {
        .toString,
        .isAttrs,
        .isList,
        .isString,
        .isInt,
        .isBool,
        .isNull,
        .isFloat,
        .isFunction,
        .isPath,
        .length,
        .head,
        .tail,
        .attrNames,
        .attrValues,
        .typeOf,
        .concatLists,
        .listToAttrs,
        .pathExists,
        .readFile,
        .import,
        .readDir,
        .readFileType,
        => 1,
        .hasAttr,
        .getAttr,
        .elemAt,
        .removeAttrs,
        .intersectAttrs,
        .elem,
        .seq,
        .all,
        .any,
        .filter,
        .deepSeq,
        .findFile,
        => 2,
        .foldlStrict => 3,
    };
}

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
        .{
            .name = try intern.intern("isFloat"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isFloat)),
        },
        .{
            .name = try intern.intern("isFunction"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isFunction)),
        },
        .{
            .name = try intern.intern("isPath"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isPath)),
        },
        .{
            .name = try intern.intern("length"),
            .value = Value.builtin(@intFromEnum(BuiltinId.length)),
        },
        .{
            .name = try intern.intern("head"),
            .value = Value.builtin(@intFromEnum(BuiltinId.head)),
        },
        .{
            .name = try intern.intern("tail"),
            .value = Value.builtin(@intFromEnum(BuiltinId.tail)),
        },
        .{
            .name = try intern.intern("attrNames"),
            .value = Value.builtin(@intFromEnum(BuiltinId.attrNames)),
        },
        .{
            .name = try intern.intern("attrValues"),
            .value = Value.builtin(@intFromEnum(BuiltinId.attrValues)),
        },
        .{
            .name = try intern.intern("hasAttr"),
            .value = Value.builtin(@intFromEnum(BuiltinId.hasAttr)),
        },
        .{
            .name = try intern.intern("getAttr"),
            .value = Value.builtin(@intFromEnum(BuiltinId.getAttr)),
        },
        .{
            .name = try intern.intern("elemAt"),
            .value = Value.builtin(@intFromEnum(BuiltinId.elemAt)),
        },
        .{
            .name = try intern.intern("typeOf"),
            .value = Value.builtin(@intFromEnum(BuiltinId.typeOf)),
        },
        .{
            .name = try intern.intern("concatLists"),
            .value = Value.builtin(@intFromEnum(BuiltinId.concatLists)),
        },
        .{
            .name = try intern.intern("listToAttrs"),
            .value = Value.builtin(@intFromEnum(BuiltinId.listToAttrs)),
        },
        .{
            .name = try intern.intern("removeAttrs"),
            .value = Value.builtin(@intFromEnum(BuiltinId.removeAttrs)),
        },
        .{
            .name = try intern.intern("intersectAttrs"),
            .value = Value.builtin(@intFromEnum(BuiltinId.intersectAttrs)),
        },
        .{
            .name = try intern.intern("elem"),
            .value = Value.builtin(@intFromEnum(BuiltinId.elem)),
        },
        .{
            .name = try intern.intern("seq"),
            .value = Value.builtin(@intFromEnum(BuiltinId.seq)),
        },
        .{
            .name = try intern.intern("all"),
            .value = Value.builtin(@intFromEnum(BuiltinId.all)),
        },
        .{
            .name = try intern.intern("any"),
            .value = Value.builtin(@intFromEnum(BuiltinId.any)),
        },
        .{
            .name = try intern.intern("filter"),
            .value = Value.builtin(@intFromEnum(BuiltinId.filter)),
        },
        .{
            .name = try intern.intern("foldl'"),
            .value = Value.builtin(@intFromEnum(BuiltinId.foldlStrict)),
        },
        .{
            .name = try intern.intern("deepSeq"),
            .value = Value.builtin(@intFromEnum(BuiltinId.deepSeq)),
        },
        .{
            .name = try intern.intern("pathExists"),
            .value = Value.builtin(@intFromEnum(BuiltinId.pathExists)),
        },
        .{
            .name = try intern.intern("readFile"),
            .value = Value.builtin(@intFromEnum(BuiltinId.readFile)),
        },
        .{
            .name = try intern.intern("import"),
            .value = Value.builtin(@intFromEnum(BuiltinId.import)),
        },
        .{
            .name = try intern.intern("readDir"),
            .value = Value.builtin(@intFromEnum(BuiltinId.readDir)),
        },
        .{
            .name = try intern.intern("readFileType"),
            .value = Value.builtin(@intFromEnum(BuiltinId.readFileType)),
        },
        .{
            .name = try intern.intern("findFile"),
            .value = Value.builtin(@intFromEnum(BuiltinId.findFile)),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}
