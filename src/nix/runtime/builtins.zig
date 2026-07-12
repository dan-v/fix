//! Evaluator-owned builtin values.

const std = @import("std");
const builtin = @import("builtin");
const InternTable = @import("intern.zig").InternTable;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const AttrEntry = heap_mod.AttrEntry;
const Value = @import("value.zig").Value;

pub const NixPathEntry = struct {
    prefix: []const u8,
    path: []const u8,
};

/// Identifies every builtin the evaluator can invoke. Most variants are
/// user-facing: they appear in `builtin_bindings` and are reachable as
/// `builtins.<name>` from Nix. A handful are compiler-internal only —
/// continuations/thunks with no name binding, never nameable from Nix:
/// `mapAttrValue`, `zipAttrsValue`, `derivationLazyAttr`, `mapValue`,
/// and `constantValue`.
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
    unsafeGetAttrPos = 57,
    add = 58,
    sub = 59,
    mul = 60,
    div = 61,
    lessThan = 62,
    bitAnd = 63,
    bitOr = 64,
    bitXor = 65,
    floor = 66,
    ceil = 67,
    baseNameOf = 68,
    dirOf = 69,
    catAttrs = 70,
    zipAttrsWith = 71,
    hashString = 72,
    hashFile = 73,
    mapAttrValue = 74,
    zipAttrsValue = 75,
    toJSON = 76,
    fromJSON = 77,
    compareVersions = 78,
    splitVersion = 79,
    parseDrvName = 80,
    getEnv = 81,
    fromTOML = 82,
    toXML = 83,
    match = 84,
    split = 85,
    traceVerbose = 86,
    addErrorContext = 87,
    unsafeDiscardStringContext = 88,
    unsafeDiscardOutputDependency = 89,
    addDrvOutputDependencies = 90,
    appendContext = 91,
    getContext = 92,
    hasContext = 93,
    toPath = 94,
    toFile = 95,
    placeholder = 96,
    filterSource = 97,
    scopedImport = 98,
    fetchurl = 99,
    fetchTarball = 100,
    fetchGit = 101,
    fetchMercurial = 102,
    fetchTree = 103,
    getFlake = 104,
    parseFlakeRef = 105,
    flakeRefToString = 106,
    break_ = 107,
    derivationLazyAttr = 108,
    mapValue = 109,
    constantValue = 110,
    /// Internal: lazily resolve one flake input (fetch + evaluate on force).
    /// Args: (ref_attrs, sub_inputs | null, is_flake). Backs each `inputs.<name>`
    /// so unused inputs are never fetched. See vm/builtins/fetch.zig.
    resolve_flake_node = 111,
    /// Internal: compute a fetched tree's NAR hash (SRI) on force. Backs the
    /// `narHash` of a fetched tree under plain eval so the (real, Nix-matching)
    /// hash is only computed when accessed. Args: (tree path, exclude basename |
    /// "" — e.g. ".git"/".hg" to drop the VCS dir). See fetch.zig.
    compute_nar_hash = 112,
    warn = 113,
};

const BuiltinBinding = struct {
    name: []const u8,
    id: BuiltinId,
};

const builtin_bindings = [_]BuiltinBinding{
    .{ .name = "toString", .id = .toString },
    .{ .name = "isAttrs", .id = .isAttrs },
    .{ .name = "isList", .id = .isList },
    .{ .name = "isString", .id = .isString },
    .{ .name = "isInt", .id = .isInt },
    .{ .name = "isBool", .id = .isBool },
    .{ .name = "isNull", .id = .isNull },
    .{ .name = "isFloat", .id = .isFloat },
    .{ .name = "isFunction", .id = .isFunction },
    .{ .name = "isPath", .id = .isPath },
    .{ .name = "length", .id = .length },
    .{ .name = "head", .id = .head },
    .{ .name = "tail", .id = .tail },
    .{ .name = "attrNames", .id = .attrNames },
    .{ .name = "attrValues", .id = .attrValues },
    .{ .name = "hasAttr", .id = .hasAttr },
    .{ .name = "getAttr", .id = .getAttr },
    .{ .name = "elemAt", .id = .elemAt },
    .{ .name = "typeOf", .id = .typeOf },
    .{ .name = "concatLists", .id = .concatLists },
    .{ .name = "listToAttrs", .id = .listToAttrs },
    .{ .name = "removeAttrs", .id = .removeAttrs },
    .{ .name = "intersectAttrs", .id = .intersectAttrs },
    .{ .name = "elem", .id = .elem },
    .{ .name = "seq", .id = .seq },
    .{ .name = "all", .id = .all },
    .{ .name = "any", .id = .any },
    .{ .name = "filter", .id = .filter },
    .{ .name = "foldl'", .id = .foldlStrict },
    .{ .name = "deepSeq", .id = .deepSeq },
    .{ .name = "pathExists", .id = .pathExists },
    .{ .name = "readFile", .id = .readFile },
    .{ .name = "import", .id = .import },
    .{ .name = "readDir", .id = .readDir },
    .{ .name = "readFileType", .id = .readFileType },
    .{ .name = "findFile", .id = .findFile },
    .{ .name = "map", .id = .map },
    .{ .name = "concatMap", .id = .concatMap },
    .{ .name = "mapAttrs", .id = .mapAttrs },
    .{ .name = "genList", .id = .genList },
    .{ .name = "stringLength", .id = .stringLength },
    .{ .name = "concatStringsSep", .id = .concatStringsSep },
    .{ .name = "substring", .id = .substring },
    .{ .name = "replaceStrings", .id = .replaceStrings },
    .{ .name = "throw", .id = .throw },
    .{ .name = "abort", .id = .abort },
    .{ .name = "tryEval", .id = .tryEval },
    .{ .name = "trace", .id = .trace },
    .{ .name = "derivation", .id = .derivation },
    .{ .name = "derivationStrict", .id = .derivationStrict },
    .{ .name = "storePath", .id = .storePath },
    .{ .name = "path", .id = .path },
    .{ .name = "sort", .id = .sort },
    .{ .name = "partition", .id = .partition },
    .{ .name = "groupBy", .id = .groupBy },
    .{ .name = "genericClosure", .id = .genericClosure },
    .{ .name = "functionArgs", .id = .functionArgs },
    .{ .name = "unsafeGetAttrPos", .id = .unsafeGetAttrPos },
    .{ .name = "add", .id = .add },
    .{ .name = "sub", .id = .sub },
    .{ .name = "mul", .id = .mul },
    .{ .name = "div", .id = .div },
    .{ .name = "lessThan", .id = .lessThan },
    .{ .name = "bitAnd", .id = .bitAnd },
    .{ .name = "bitOr", .id = .bitOr },
    .{ .name = "bitXor", .id = .bitXor },
    .{ .name = "floor", .id = .floor },
    .{ .name = "ceil", .id = .ceil },
    .{ .name = "baseNameOf", .id = .baseNameOf },
    .{ .name = "dirOf", .id = .dirOf },
    .{ .name = "catAttrs", .id = .catAttrs },
    .{ .name = "zipAttrsWith", .id = .zipAttrsWith },
    .{ .name = "hashString", .id = .hashString },
    .{ .name = "hashFile", .id = .hashFile },
    .{ .name = "toJSON", .id = .toJSON },
    .{ .name = "fromJSON", .id = .fromJSON },
    .{ .name = "compareVersions", .id = .compareVersions },
    .{ .name = "splitVersion", .id = .splitVersion },
    .{ .name = "parseDrvName", .id = .parseDrvName },
    .{ .name = "getEnv", .id = .getEnv },
    .{ .name = "fromTOML", .id = .fromTOML },
    .{ .name = "toXML", .id = .toXML },
    .{ .name = "match", .id = .match },
    .{ .name = "split", .id = .split },
    .{ .name = "traceVerbose", .id = .traceVerbose },
    .{ .name = "warn", .id = .warn },
    .{ .name = "addErrorContext", .id = .addErrorContext },
    .{ .name = "unsafeDiscardStringContext", .id = .unsafeDiscardStringContext },
    .{ .name = "unsafeDiscardOutputDependency", .id = .unsafeDiscardOutputDependency },
    .{ .name = "addDrvOutputDependencies", .id = .addDrvOutputDependencies },
    .{ .name = "appendContext", .id = .appendContext },
    .{ .name = "getContext", .id = .getContext },
    .{ .name = "hasContext", .id = .hasContext },
    .{ .name = "toPath", .id = .toPath },
    .{ .name = "toFile", .id = .toFile },
    .{ .name = "placeholder", .id = .placeholder },
    .{ .name = "filterSource", .id = .filterSource },
    .{ .name = "scopedImport", .id = .scopedImport },
    .{ .name = "fetchurl", .id = .fetchurl },
    .{ .name = "fetchTarball", .id = .fetchTarball },
    .{ .name = "fetchGit", .id = .fetchGit },
    .{ .name = "fetchMercurial", .id = .fetchMercurial },
    .{ .name = "fetchTree", .id = .fetchTree },
    .{ .name = "getFlake", .id = .getFlake },
    .{ .name = "parseFlakeRef", .id = .parseFlakeRef },
    .{ .name = "flakeRefToString", .id = .flakeRefToString },
    .{ .name = "break", .id = .break_ },
};

const constant_bindings = [_][]const u8{
    "true",
    "false",
    "null",
    "langVersion",
    "storeDir",
    "currentSystem",
    "currentTime",
    "nixVersion",
    "nixPath",
};

pub fn idForName(name: []const u8) ?BuiltinId {
    for (builtin_bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding.id;
    }
    return null;
}

pub fn ambientIdForName(name: []const u8) ?BuiltinId {
    const id = idForName(name) orelse return null;
    return switch (id) {
        .abort,
        .baseNameOf,
        .derivation,
        .dirOf,
        .fetchGit,
        .fetchMercurial,
        .fetchTarball,
        .fetchTree,
        .fromTOML,
        .import,
        .isNull,
        .map,
        .placeholder,
        .removeAttrs,
        .scopedImport,
        .throw,
        .toString,
        => id,
        else => null,
    };
}

pub fn hasConstant(name: []const u8) bool {
    for (constant_bindings) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

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
        .toJSON,
        .fromJSON,
        .splitVersion,
        .parseDrvName,
        .getEnv,
        .fromTOML,
        .toXML,
        .unsafeDiscardStringContext,
        .unsafeDiscardOutputDependency,
        .addDrvOutputDependencies,
        .getContext,
        .hasContext,
        .toPath,
        .placeholder,
        .fetchurl,
        .fetchTarball,
        .fetchGit,
        .fetchMercurial,
        .fetchTree,
        .getFlake,
        .parseFlakeRef,
        .flakeRefToString,
        .break_,
        .constantValue,
        .floor,
        .ceil,
        .baseNameOf,
        .dirOf,
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
        .add,
        .sub,
        .mul,
        .div,
        .lessThan,
        .bitAnd,
        .bitOr,
        .bitXor,
        .catAttrs,
        .zipAttrsWith,
        .hashString,
        .hashFile,
        .compareVersions,
        .match,
        .split,
        .traceVerbose,
        .warn,
        .addErrorContext,
        .appendContext,
        .toFile,
        .filterSource,
        .scopedImport,
        .mapValue,
        .derivationLazyAttr,
        .compute_nar_hash,
        => 2,
        .foldlStrict,
        .substring,
        .replaceStrings,
        .mapAttrValue,
        .zipAttrsValue,
        .resolve_flake_node,
        => 3,
    };
}

pub fn buildAttrSet(intern: *InternTable, heap: *ObjectHeap, nix_path: []const NixPathEntry) !Value {
    var entries: std.ArrayListUnmanaged(AttrEntry) = .empty;
    defer entries.deinit(heap.allocator);
    try entries.ensureTotalCapacity(heap.allocator, builtin_bindings.len + constant_bindings.len + 1);

    for (builtin_bindings) |binding| {
        entries.appendAssumeCapacity(try builtinEntry(intern, binding));
    }

    entries.appendAssumeCapacity(.{ .name = try intern.intern("true"), .value = Value.boolVal(true) });
    entries.appendAssumeCapacity(.{ .name = try intern.intern("false"), .value = Value.boolVal(false) });
    entries.appendAssumeCapacity(.{ .name = try intern.intern("null"), .value = Value.null_val });
    entries.appendAssumeCapacity(.{ .name = try intern.intern("langVersion"), .value = Value.int(6) });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("storeDir"),
        .value = Value.string(try intern.intern("/nix/store")),
    });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("currentSystem"),
        .value = Value.string(try intern.intern(hostSystemName())),
    });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("currentTime"),
        .value = Value.int(0),
    });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("nixVersion"),
        .value = Value.string(try intern.intern("2.18.3")),
    });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("nixPath"),
        .value = try buildNixPathValue(intern, heap, nix_path),
    });
    // Self-reference: `builtins.builtins` points back at the attrset we're
    // about to add. Reserve an object slot up front, embed its id in the
    // entries, then fill the slot once we have the AttrRange. This is
    // single-threaded — `Evaluator.evaluate` calls `ensureBuiltins` before
    // `scheduler.start` — so no other thread can observe the in-flight slot.
    const self_id = try heap.reserveObjectSlot();
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("builtins"),
        .value = Value.attrs(self_id),
    });
    const attr_range = try heap.prepareAttrsRange(entries.items);
    heap.fillObjectSlot(self_id, .{ .attrs = .{ .range = attr_range } });
    return Value.attrs(self_id);
}

fn builtinEntry(intern: *InternTable, binding: BuiltinBinding) !AttrEntry {
    return .{
        .name = try intern.intern(binding.name),
        .value = Value.builtin(@intFromEnum(binding.id)),
    };
}

fn buildNixPathValue(intern: *InternTable, heap: *ObjectHeap, nix_path: []const NixPathEntry) !Value {
    const values = try heap.allocator.alloc(Value, nix_path.len);
    defer heap.allocator.free(values);

    const prefix_id = try intern.intern("prefix");
    const path_id = try intern.intern("path");
    for (nix_path, values) |entry, *value| {
        const attrs = [_]AttrEntry{
            .{
                .name = prefix_id,
                .value = Value.string(try intern.intern(entry.prefix)),
            },
            .{
                .name = path_id,
                .value = Value.string(try intern.intern(entry.path)),
            },
        };
        value.* = Value.attrs(try heap.addAttrs(&attrs));
    }

    return Value.list(try heap.addList(values));
}

fn hostSystemName() []const u8 {
    return switch (builtin.target.os.tag) {
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "x86_64-linux",
            .aarch64 => "aarch64-linux",
            .arm => "armv7l-linux",
            .riscv64 => "riscv64-linux",
            else => "unknown-linux",
        },
        .macos => switch (builtin.target.cpu.arch) {
            .x86_64 => "x86_64-darwin",
            .aarch64 => "aarch64-darwin",
            else => "unknown-darwin",
        },
        .freebsd => switch (builtin.target.cpu.arch) {
            .x86_64 => "x86_64-freebsd",
            .aarch64 => "aarch64-freebsd",
            else => "unknown-freebsd",
        },
        else => "unknown",
    };
}
