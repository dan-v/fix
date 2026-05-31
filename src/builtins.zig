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
    map = 36,
    concatMap = 37,
    mapAttrs = 38,
    genList = 39,
    stringLength = 40,
    concatStringsSep = 41,
    substring = 42,
    replaceStrings = 43,
    throw = 44,
    abort = 45,
    tryEval = 46,
    trace = 47,
    derivation = 48,
    derivationStrict = 49,
    storePath = 50,
    path = 51,
    sort = 52,
    partition = 53,
    groupBy = 54,
    genericClosure = 55,
    functionArgs = 56,
    isCallable = 57,
    unsafeGetAttrPos = 58,
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
        .stringLength,
        .throw,
        .abort,
        .tryEval,
        .derivation,
        .derivationStrict,
        .storePath,
        .path,
        .genericClosure,
        .functionArgs,
        .isCallable,
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
        .map,
        .concatMap,
        .mapAttrs,
        .genList,
        .concatStringsSep,
        .trace,
        .sort,
        .partition,
        .groupBy,
        .unsafeGetAttrPos,
        => 2,
        .foldlStrict,
        .substring,
        .replaceStrings,
        => 3,
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
        .{
            .name = try intern.intern("map"),
            .value = Value.builtin(@intFromEnum(BuiltinId.map)),
        },
        .{
            .name = try intern.intern("concatMap"),
            .value = Value.builtin(@intFromEnum(BuiltinId.concatMap)),
        },
        .{
            .name = try intern.intern("mapAttrs"),
            .value = Value.builtin(@intFromEnum(BuiltinId.mapAttrs)),
        },
        .{
            .name = try intern.intern("genList"),
            .value = Value.builtin(@intFromEnum(BuiltinId.genList)),
        },
        .{
            .name = try intern.intern("stringLength"),
            .value = Value.builtin(@intFromEnum(BuiltinId.stringLength)),
        },
        .{
            .name = try intern.intern("concatStringsSep"),
            .value = Value.builtin(@intFromEnum(BuiltinId.concatStringsSep)),
        },
        .{
            .name = try intern.intern("substring"),
            .value = Value.builtin(@intFromEnum(BuiltinId.substring)),
        },
        .{
            .name = try intern.intern("replaceStrings"),
            .value = Value.builtin(@intFromEnum(BuiltinId.replaceStrings)),
        },
        .{
            .name = try intern.intern("throw"),
            .value = Value.builtin(@intFromEnum(BuiltinId.throw)),
        },
        .{
            .name = try intern.intern("abort"),
            .value = Value.builtin(@intFromEnum(BuiltinId.abort)),
        },
        .{
            .name = try intern.intern("tryEval"),
            .value = Value.builtin(@intFromEnum(BuiltinId.tryEval)),
        },
        .{
            .name = try intern.intern("trace"),
            .value = Value.builtin(@intFromEnum(BuiltinId.trace)),
        },
        .{
            .name = try intern.intern("derivation"),
            .value = Value.builtin(@intFromEnum(BuiltinId.derivation)),
        },
        .{
            .name = try intern.intern("derivationStrict"),
            .value = Value.builtin(@intFromEnum(BuiltinId.derivationStrict)),
        },
        .{
            .name = try intern.intern("storePath"),
            .value = Value.builtin(@intFromEnum(BuiltinId.storePath)),
        },
        .{
            .name = try intern.intern("path"),
            .value = Value.builtin(@intFromEnum(BuiltinId.path)),
        },
        .{
            .name = try intern.intern("sort"),
            .value = Value.builtin(@intFromEnum(BuiltinId.sort)),
        },
        .{
            .name = try intern.intern("partition"),
            .value = Value.builtin(@intFromEnum(BuiltinId.partition)),
        },
        .{
            .name = try intern.intern("groupBy"),
            .value = Value.builtin(@intFromEnum(BuiltinId.groupBy)),
        },
        .{
            .name = try intern.intern("genericClosure"),
            .value = Value.builtin(@intFromEnum(BuiltinId.genericClosure)),
        },
        .{
            .name = try intern.intern("functionArgs"),
            .value = Value.builtin(@intFromEnum(BuiltinId.functionArgs)),
        },
        .{
            .name = try intern.intern("isCallable"),
            .value = Value.builtin(@intFromEnum(BuiltinId.isCallable)),
        },
        .{
            .name = try intern.intern("unsafeGetAttrPos"),
            .value = Value.builtin(@intFromEnum(BuiltinId.unsafeGetAttrPos)),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}
