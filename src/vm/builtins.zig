//! Builtin dispatch and builtin implementations for the bytecode VM.

const std = @import("std");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("../heap.zig");
const file_cache = @import("../file_cache.zig");
const builtins_mod = @import("../builtins.zig");
const BuiltinId = builtins_mod.BuiltinId;
const numeric = @import("../runtime/numeric.zig");
const derivation = @import("../derivation.zig");
const nar = @import("../runtime/nar.zig");
const source_paths = @import("../runtime/source_path.zig");
const shared = @import("builtins/shared.zig");
const strings = @import("builtins/strings.zig");
const collections = @import("builtins/collections.zig");
const serial = @import("builtins/serial.zig");
const fetch = @import("builtins/fetch.zig");
const derivation_builtins = @import("builtins/derivation.zig");
pub const makeBuiltinClosure = shared.makeBuiltinClosure;
pub const makeBuiltinThunk = shared.makeBuiltinThunk;
pub const firstReplacementIdAt = strings.firstReplacementIdAt;
pub const pathArg = strings.pathArg;
pub const builtinStringLength = strings.builtinStringLength;
pub const builtinConcatStringsSep = strings.builtinConcatStringsSep;
pub const coerceStringContextId = strings.coerceStringContextId;
pub const coerceStringContextValue = strings.coerceStringContextValue;
pub const coerceAttrsStringContextValue = strings.coerceAttrsStringContextValue;
pub const sourcePathStringValue = strings.sourcePathStringValue;
pub const builtinSubstring = strings.builtinSubstring;
pub const builtinReplaceStrings = strings.builtinReplaceStrings;
pub const builtinThrow = strings.builtinThrow;
pub const builtinAbort = strings.builtinAbort;
pub const builtinTryEval = strings.builtinTryEval;
pub const builtinAddErrorContext = strings.builtinAddErrorContext;
pub const builtinTrace = strings.builtinTrace;
pub const builtinTraceVerbose = strings.builtinTraceVerbose;
pub const builtinGetContext = strings.builtinGetContext;
pub const builtinHasContext = strings.builtinHasContext;
pub const builtinAppendContext = strings.builtinAppendContext;
pub const builtinUnsafeDiscardStringContext = strings.builtinUnsafeDiscardStringContext;
pub const builtinUnsafeDiscardOutputDependency = strings.builtinUnsafeDiscardOutputDependency;
pub const builtinAddDrvOutputDependencies = strings.builtinAddDrvOutputDependencies;
pub const tryEvalResult = strings.tryEvalResult;
pub const stringArg = strings.stringArg;
pub const isStringLike = strings.isStringLike;
pub const isPlainString = strings.isPlainString;
pub const isCallable = strings.isCallable;
pub const stringTextInternId = strings.stringTextInternId;
pub const contextEntriesForValue = strings.contextEntriesForValue;
pub const singleContextEntry = strings.singleContextEntry;
pub const appendContextEntry = strings.appendContextEntry;
pub const mergeContextValues = strings.mergeContextValues;
pub const mergeContextAttrs = strings.mergeContextAttrs;
pub const mergeContextAttrValue = strings.mergeContextAttrValue;
pub const mergeContextOutputs = strings.mergeContextOutputs;
pub const appendUniqueContextOutput = strings.appendUniqueContextOutput;
pub const pathContextValue = strings.pathContextValue;
pub const allOutputsContextValue = strings.allOutputsContextValue;
pub const contextStringWithPath = strings.contextStringWithPath;
pub const stringListArg = strings.stringListArg;
pub const stringListInternIdsArg = strings.stringListInternIdsArg;
pub const stringListValuesArg = strings.stringListValuesArg;
pub const builtinToString = strings.builtinToString;
pub const coerceToStringId = strings.coerceToStringId;
pub const coerceToStringValue = strings.coerceToStringValue;
pub const coerceListToStringId = strings.coerceListToStringId;
pub const coerceListToStringValue = strings.coerceListToStringValue;
pub const isEmptyListStringItem = strings.isEmptyListStringItem;
pub const coerceAttrsToStringValue = strings.coerceAttrsToStringValue;
pub const coerceDerivationStringValue = strings.coerceDerivationStringValue;
pub const coerceDerivationListToStringValue = strings.coerceDerivationListToStringValue;
pub const coerceDerivationAttrsToStringValue = strings.coerceDerivationAttrsToStringValue;
pub const builtinCatAttrs = collections.builtinCatAttrs;
pub const builtinZipAttrsWith = collections.builtinZipAttrsWith;
pub const builtinZipAttrsValue = collections.builtinZipAttrsValue;
pub const attrEntryNameIndex = collections.attrEntryNameIndex;
pub const groupIndex = collections.groupIndex;
pub const callComparator = collections.callComparator;
pub const genericClosureAppend = collections.genericClosureAppend;
pub const builtinAttrNames = collections.builtinAttrNames;
pub const builtinAttrValues = collections.builtinAttrValues;
pub const sortedAttrEntries = collections.sortedAttrEntries;
pub const builtinHasAttr = collections.builtinHasAttr;
pub const builtinGetAttr = collections.builtinGetAttr;
pub const builtinElemAt = collections.builtinElemAt;
pub const builtinElem = collections.builtinElem;
pub const builtinSeq = collections.builtinSeq;
pub const builtinDeepSeq = collections.builtinDeepSeq;
pub const builtinAll = collections.builtinAll;
pub const builtinAny = collections.builtinAny;
pub const builtinFilter = collections.builtinFilter;
pub const builtinMap = collections.builtinMap;
pub const builtinMapValue = collections.builtinMapValue;
pub const builtinConcatMap = collections.builtinConcatMap;
pub const builtinMapAttrs = collections.builtinMapAttrs;
pub const builtinMapAttrValue = collections.builtinMapAttrValue;
pub const builtinGenList = collections.builtinGenList;
pub const builtinSort = collections.builtinSort;
pub const builtinPartition = collections.builtinPartition;
pub const builtinGroupBy = collections.builtinGroupBy;
pub const builtinGenericClosure = collections.builtinGenericClosure;
pub const builtinFunctionArgs = collections.builtinFunctionArgs;
pub const builtinUnsafeGetAttrPos = collections.builtinUnsafeGetAttrPos;
pub const builtinFoldlStrict = collections.builtinFoldlStrict;
pub const builtinRemoveAttrs = collections.builtinRemoveAttrs;
pub const builtinIntersectAttrs = collections.builtinIntersectAttrs;
pub const stringListContainsIntern = collections.stringListContainsIntern;
pub const builtinToJSON = serial.builtinToJSON;
pub const writeJsonValue = serial.writeJsonValue;
pub const builtinToXML = serial.builtinToXML;
pub const writeLazyXmlValue = serial.writeLazyXmlValue;
pub const builtinFromJSON = serial.builtinFromJSON;
pub const builtinFromTOML = serial.builtinFromTOML;
pub const builtinCompareVersions = serial.builtinCompareVersions;
pub const builtinSplitVersion = serial.builtinSplitVersion;
pub const builtinMatch = serial.builtinMatch;
pub const builtinSplit = serial.builtinSplit;
pub const builtinParseDrvName = serial.builtinParseDrvName;
pub const builtinGetEnv = fetch.builtinGetEnv;
pub const builtinToPath = fetch.builtinToPath;
pub const builtinToFile = fetch.builtinToFile;
pub const builtinFilterSource = fetch.builtinFilterSource;
pub const builtinFetchGit = fetch.builtinFetchGit;
pub const builtinFetchurl = fetch.builtinFetchurl;
pub const builtinFetchTarball = fetch.builtinFetchTarball;
pub const builtinFetchMercurial = fetch.builtinFetchMercurial;
pub const builtinFetchTree = fetch.builtinFetchTree;
pub const builtinGetFlake = fetch.builtinGetFlake;
pub const builtinParseFlakeRef = fetch.builtinParseFlakeRef;
pub const builtinFlakeRefToString = fetch.builtinFlakeRefToString;
pub const filterSourceAccepts = fetch.filterSourceAccepts;
pub const DerivationMode = derivation_builtins.DerivationMode;
pub const builtinDerivation = derivation_builtins.builtinDerivation;
pub const builtinDerivationLazyAttr = derivation_builtins.builtinDerivationLazyAttr;

const path_ops = @import("../runtime/paths.zig");
const nix_hash = @import("../runtime/hash.zig");

pub fn applyBuiltin(self: anytype, builtin_id: u16, args: []const Value) !Value {
    const id: BuiltinId = @enumFromInt(builtin_id);
    const arity = builtins_mod.arity(id);
    if (args.len < arity) return makeBuiltinClosure(self, builtin_id, args);
    if (args.len > arity) return error.TooManyArguments;

    return switch (id) {
        .toString => builtinToString(self, args[0]),
        .isAttrs => builtinTypePredicate(self, args[0], .attrs),
        .isList => builtinTypePredicate(self, args[0], .list),
        .isString => builtinIsString(self, args[0]),
        .isInt => builtinTypePredicate(self, args[0], .int),
        .isBool => builtinIsBool(self, args[0]),
        .isNull => builtinTypePredicate(self, args[0], .null),
        .isFloat => builtinTypePredicate(self, args[0], .float),
        .isFunction => builtinIsFunction(self, args[0]),
        .isPath => builtinTypePredicate(self, args[0], .path),
        .length => builtinLength(self, args[0]),
        .head => builtinHead(self, args[0]),
        .tail => builtinTail(self, args[0]),
        .attrNames => builtinAttrNames(self, args[0]),
        .attrValues => builtinAttrValues(self, args[0]),
        .typeOf => builtinTypeOf(self, args[0]),
        .concatLists => builtinConcatLists(self, args[0]),
        .listToAttrs => builtinListToAttrs(self, args[0]),
        .pathExists => builtinPathExists(self, args[0]),
        .readFile => builtinReadFile(self, args[0]),
        .import => builtinImport(self, args[0]),
        .readDir => builtinReadDir(self, args[0]),
        .readFileType => builtinReadFileType(self, args[0]),
        .findFile => builtinFindFile(self, args[0], args[1]),
        .hasAttr => builtinHasAttr(self, args[0], args[1]),
        .getAttr => builtinGetAttr(self, args[0], args[1]),
        .elemAt => builtinElemAt(self, args[0], args[1]),
        .removeAttrs => builtinRemoveAttrs(self, args[0], args[1]),
        .intersectAttrs => builtinIntersectAttrs(self, args[0], args[1]),
        .elem => builtinElem(self, args[0], args[1]),
        .seq => builtinSeq(self, args[0], args[1]),
        .all => builtinAll(self, args[0], args[1]),
        .any => builtinAny(self, args[0], args[1]),
        .filter => builtinFilter(self, args[0], args[1]),
        .map => builtinMap(self, args[0], args[1]),
        .concatMap => builtinConcatMap(self, args[0], args[1]),
        .mapAttrs => builtinMapAttrs(self, args[0], args[1]),
        .genList => builtinGenList(self, args[0], args[1]),
        .stringLength => builtinStringLength(self, args[0]),
        .concatStringsSep => builtinConcatStringsSep(self, args[0], args[1]),
        .foldlStrict => builtinFoldlStrict(self, args[0], args[1], args[2]),
        .substring => builtinSubstring(self, args[0], args[1], args[2]),
        .replaceStrings => builtinReplaceStrings(self, args[0], args[1], args[2]),
        .deepSeq => builtinDeepSeq(self, args[0], args[1]),
        .throw => builtinThrow(self, args[0]),
        .abort => builtinAbort(self, args[0]),
        .tryEval => builtinTryEval(self, args[0]),
        .trace => builtinTrace(self, args[0], args[1]),
        .derivation => builtinDerivation(self, args[0], .lazy),
        .derivationStrict => builtinDerivation(self, args[0], .strict),
        .storePath => builtinStorePath(self, args[0]),
        .path => builtinPath(self, args[0]),
        .sort => builtinSort(self, args[0], args[1]),
        .partition => builtinPartition(self, args[0], args[1]),
        .groupBy => builtinGroupBy(self, args[0], args[1]),
        .genericClosure => builtinGenericClosure(self, args[0]),
        .functionArgs => builtinFunctionArgs(self, args[0]),
        .unsafeGetAttrPos => builtinUnsafeGetAttrPos(self, args[0], args[1]),
        .add => builtinAdd(self, args[0], args[1]),
        .sub => builtinSub(self, args[0], args[1]),
        .mul => builtinMul(self, args[0], args[1]),
        .div => builtinDiv(self, args[0], args[1]),
        .lessThan => builtinLessThan(self, args[0], args[1]),
        .bitAnd => builtinBitAnd(self, args[0], args[1]),
        .bitOr => builtinBitOr(self, args[0], args[1]),
        .bitXor => builtinBitXor(self, args[0], args[1]),
        .floor => builtinFloor(self, args[0]),
        .ceil => builtinCeil(self, args[0]),
        .baseNameOf => builtinBaseNameOf(self, args[0]),
        .dirOf => builtinDirOf(self, args[0]),
        .catAttrs => builtinCatAttrs(self, args[0], args[1]),
        .zipAttrsWith => builtinZipAttrsWith(self, args[0], args[1]),
        .hashString => builtinHashString(self, args[0], args[1]),
        .hashFile => builtinHashFile(self, args[0], args[1]),
        .mapAttrValue => builtinMapAttrValue(self, args[0], args[1], args[2]),
        .zipAttrsValue => builtinZipAttrsValue(self, args[0], args[1], args[2]),
        .toJSON => builtinToJSON(self, args[0]),
        .fromJSON => builtinFromJSON(self, args[0]),
        .toXML => builtinToXML(self, args[0]),
        .compareVersions => builtinCompareVersions(self, args[0], args[1]),
        .splitVersion => builtinSplitVersion(self, args[0]),
        .parseDrvName => builtinParseDrvName(self, args[0]),
        .getEnv => builtinGetEnv(self, args[0]),
        .match => builtinMatch(self, args[0], args[1]),
        .split => builtinSplit(self, args[0], args[1]),
        .fromTOML => builtinFromTOML(self, args[0]),
        .filterSource => builtinFilterSource(self, args[0], args[1]),
        .fetchGit => builtinFetchGit(self, args[0]),
        .fetchurl => builtinFetchurl(self, args[0]),
        .fetchTarball => builtinFetchTarball(self, args[0]),
        .fetchTree => builtinFetchTree(self, args[0]),
        .parseFlakeRef => builtinParseFlakeRef(self, args[0]),
        .flakeRefToString => builtinFlakeRefToString(self, args[0]),
        .fetchMercurial => builtinFetchMercurial(self, args[0]),
        .getFlake => builtinGetFlake(self, args[0]),
        .scopedImport => builtinScopedImport(self, args[0], args[1]),
        .traceVerbose => builtinTraceVerbose(self, args[0], args[1]),
        .addErrorContext => builtinAddErrorContext(self, args[0], args[1]),
        .unsafeDiscardStringContext => builtinUnsafeDiscardStringContext(self, args[0]),
        .unsafeDiscardOutputDependency => builtinUnsafeDiscardOutputDependency(self, args[0]),
        .addDrvOutputDependencies => builtinAddDrvOutputDependencies(self, args[0]),
        .appendContext => builtinAppendContext(self, args[0], args[1]),
        .break_ => self.forceValue(args[0]),
        .getContext => builtinGetContext(self, args[0]),
        .hasContext => builtinHasContext(self, args[0]),
        .toPath => builtinToPath(self, args[0]),
        .toFile => builtinToFile(self, args[0], args[1]),
        .placeholder => builtinPlaceholder(self, args[0]),
        .derivationLazyAttr => builtinDerivationLazyAttr(self, args[0], args[1]),
        .mapValue => builtinMapValue(self, args[0], args[1]),
        .constantValue => args[0],
    };
}

fn builtinTypePredicate(self: anytype, arg: Value, expected: @import("../value.zig").ValueType) !Value {
    const value = try self.forceValue(arg);
    return Value.boolVal(value.discriminant == expected);
}

fn builtinIsString(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return Value.boolVal(value.discriminant == .string or value.discriminant == .string_context);
}

fn builtinIsBool(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return Value.boolVal(value.isBool());
}

fn builtinIsFunction(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return Value.boolVal(value.discriminant == .closure or value.discriminant == .builtin or value.discriminant == .builtin_closure);
}

fn builtinTypeOf(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    const name: []const u8 = switch (value.discriminant) {
        .null => "null",
        .bool_false, .bool_true => "bool",
        .int => "int",
        .float => "float",
        .string, .string_context => "string",
        .path => "path",
        .list => "list",
        .attrs => "set",
        .closure, .builtin, .builtin_closure => "lambda",
        .thunk, .cell => unreachable,
    };
    return Value.string(try self.intern.intern(name));
}

fn builtinAdd(self: anytype, left: Value, right: Value) !Value {
    return numeric.add(try self.forceValue(left), try self.forceValue(right));
}

fn builtinSub(self: anytype, left: Value, right: Value) !Value {
    return numeric.sub(try self.forceValue(left), try self.forceValue(right));
}

fn builtinMul(self: anytype, left: Value, right: Value) !Value {
    return numeric.mul(try self.forceValue(left), try self.forceValue(right));
}

fn builtinDiv(self: anytype, left: Value, right: Value) !Value {
    return numeric.div(try self.forceValue(left), try self.forceValue(right));
}

fn builtinLessThan(self: anytype, left: Value, right: Value) !Value {
    return Value.boolVal(try self.compareValues(left, right) == .lt);
}

fn builtinBitAnd(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitAnd(try self.forceValue(left), try self.forceValue(right));
}

fn builtinBitOr(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitOr(try self.forceValue(left), try self.forceValue(right));
}

fn builtinBitXor(self: anytype, left: Value, right: Value) !Value {
    return numeric.bitXor(try self.forceValue(left), try self.forceValue(right));
}

fn builtinFloor(self: anytype, arg: Value) !Value {
    return numeric.floor(try self.forceValue(arg));
}

fn builtinCeil(self: anytype, arg: Value) !Value {
    return numeric.ceil(try self.forceValue(arg));
}

fn builtinBaseNameOf(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    const path = switch (value.discriminant) {
        .path, .string, .string_context => self.intern.get(try stringTextInternId(self, value)),
        else => return error.TypeError,
    };
    return Value.string(try self.intern.intern(path_ops.baseName(path)));
}

fn builtinDirOf(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    const path = switch (value.discriminant) {
        .path, .string, .string_context => self.intern.get(try stringTextInternId(self, value)),
        else => return error.TypeError,
    };
    const dir = try self.intern.intern(path_ops.dirOf(path));
    return switch (value.discriminant) {
        .path => Value.path(dir),
        .string, .string_context => Value.string(dir),
        else => unreachable,
    };
}

fn builtinHashString(self: anytype, algorithm_arg: Value, string_arg: Value) !Value {
    const algorithm_value = try self.forceValue(algorithm_arg);
    const string_value = try self.forceValue(string_arg);
    if (!isPlainString(algorithm_value) or !isPlainString(string_value)) return error.TypeError;
    const algorithm = self.intern.get(try stringTextInternId(self, algorithm_value));
    const string = self.intern.get(try stringTextInternId(self, string_value));
    const digest = try nix_hash.hashBytes(self.allocator, algorithm, string);
    defer self.allocator.free(digest);
    return Value.string(try self.intern.intern(digest));
}

fn builtinHashFile(self: anytype, algorithm_arg: Value, path_arg: Value) !Value {
    const algorithm = try stringArg(self, algorithm_arg);
    const contents = try self.files.readFile(try pathArg(self, path_arg));
    const digest = try nix_hash.hashBytes(self.allocator, algorithm, contents);
    defer self.allocator.free(digest);
    return Value.string(try self.intern.intern(digest));
}

fn builtinLength(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (value.discriminant != .list) return error.TypeError;
    return Value.int(@intCast(try self.heap.getListLen(value.asObjectId())));
}

fn builtinHead(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (value.discriminant != .list) return error.TypeError;
    const items = try self.heap.getList(value.asObjectId());
    if (items.len == 0) return error.IndexOutOfBounds;
    return self.forceValue(items[0]);
}

fn builtinTail(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (value.discriminant != .list) return error.TypeError;
    const items = try self.heap.getList(value.asObjectId());
    if (items.len == 0) return error.IndexOutOfBounds;
    return Value.list(try self.heap.addList(items[1..]));
}

fn builtinConcatLists(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (value.discriminant != .list) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    const lists = try self.heap.getList(value.asObjectId());
    for (lists) |list_item| {
        const list = try self.forceValue(list_item);
        if (list.discriminant != .list) return error.TypeError;
        try out.appendSlice(self.allocator, try self.heap.getList(list.asObjectId()));
    }

    return Value.list(try self.heap.addList(out.items));
}

fn builtinListToAttrs(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (value.discriminant != .list) return error.TypeError;

    const name_id = try self.intern.intern("name");
    const value_id = try self.intern.intern("value");
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    const items = try self.heap.getList(value.asObjectId());
    for (items) |item| {
        const item_value = try self.forceValue(item);
        if (item_value.discriminant != .attrs) return error.TypeError;

        const name_value = try self.forceValue(try self.heap.getAttrValue(item_value.asObjectId(), name_id));
        if (!isPlainString(name_value)) return error.TypeError;
        const name_intern = try stringTextInternId(self, name_value);
        if (attrEntryNameIndex(entries.items, name_intern) != null) continue;

        try entries.append(self.allocator, .{
            .name = name_intern,
            .value = try self.heap.getAttrValue(item_value.asObjectId(), value_id),
        });
    }

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn builtinPathExists(self: anytype, arg: Value) !Value {
    return Value.boolVal(try self.files.pathExists(try pathArg(self, arg)));
}

fn builtinReadFile(self: anytype, arg: Value) !Value {
    const contents = try self.files.readFile(try pathArg(self, arg));
    return Value.string(try self.intern.intern(contents));
}

fn builtinReadFileType(self: anytype, arg: Value) !Value {
    const kind = try self.files.fileType(try pathArg(self, arg));
    return Value.string(try self.intern.intern(kind.nixTypeName()));
}

fn builtinImport(self: anytype, arg: Value) !Value {
    const host = self.import_host orelse return error.ImportUnavailable;
    return host.import_value(host.context, try pathArg(self, arg));
}

fn builtinScopedImport(self: anytype, scope_arg: Value, path_arg: Value) !Value {
    const scope = try self.forceValue(scope_arg);
    if (scope.discriminant != .attrs) return self.typeErrorExpected("attrs", scope);
    const host = self.import_host orelse return error.ImportUnavailable;
    return host.scoped_import(host.context, scope, try pathArg(self, path_arg));
}

fn builtinReadDir(self: anytype, arg: Value) !Value {
    const dir_entries = try self.files.readDir(try pathArg(self, arg));
    var attrs: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer attrs.deinit(self.allocator);
    try attrs.ensureTotalCapacity(self.allocator, dir_entries.len);

    for (dir_entries) |dir_entry| {
        attrs.appendAssumeCapacity(.{
            .name = try self.intern.intern(dir_entry.name),
            .value = Value.string(try self.intern.intern(dir_entry.kind.nixTypeName())),
        });
    }

    return Value.attrs(try self.heap.addAttrs(attrs.items));
}

fn builtinFindFile(self: anytype, search_path_arg: Value, name_arg: Value) !Value {
    const search_path = try self.forceValue(search_path_arg);
    if (search_path.discriminant != .list) return error.TypeError;
    const name = try pathArg(self, name_arg);

    const path_id = try self.intern.intern("path");
    const prefix_id = try self.intern.intern("prefix");
    for (try self.heap.getList(search_path.asObjectId())) |item| {
        const entry = try self.forceValue(item);
        if (entry.discriminant != .attrs) return error.TypeError;

        const base_value = try self.forceValue(try self.heap.getAttrValue(entry.asObjectId(), path_id));
        const base = switch (base_value.discriminant) {
            .path, .string, .string_context => self.intern.get(try stringTextInternId(self, base_value)),
            else => return error.TypeError,
        };

        const prefix_value = self.heap.getAttrValue(entry.asObjectId(), prefix_id) catch |err| switch (err) {
            error.MissingAttribute => Value.string(try self.intern.intern("")),
            else => return err,
        };
        const prefix_forced = try self.forceValue(prefix_value);
        if (!isPlainString(prefix_forced)) return error.TypeError;
        const prefix = self.intern.get(try stringTextInternId(self, prefix_forced));

        if (try findFileCandidate(self, base, prefix, name)) |candidate| {
            defer self.allocator.free(candidate);
            return Value.path(try self.intern.intern(candidate));
        }
    }
    return error.FileNotFound;
}

fn findFileCandidate(self: anytype, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
    const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
    const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
    errdefer self.allocator.free(candidate);
    if (try self.files.pathExists(candidate)) return candidate;
    self.allocator.free(candidate);
    return null;
}

fn builtinPlaceholder(self: anytype, arg: Value) !Value {
    const output = try stringArg(self, arg);
    const fingerprint = try std.fmt.allocPrint(self.allocator, "nix-output:{s}", .{output});
    defer self.allocator.free(fingerprint);
    const hash = try nix_hash.hashBytesNixBase32(self.allocator, "sha256", fingerprint);
    defer self.allocator.free(hash);
    const text = try std.fmt.allocPrint(self.allocator, "/{s}", .{hash});
    defer self.allocator.free(text);
    return Value.string(try self.intern.intern(text));
}

fn builtinStorePath(self: anytype, arg: Value) !Value {
    const path = try pathArg(self, arg);
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn builtinPath(self: anytype, arg: Value) !Value {
    const attrs = try self.forceValue(arg);
    if (attrs.discriminant != .attrs) return error.TypeError;
    const attrs_id = attrs.asObjectId();

    const path_id = try self.intern.intern("path");
    const path_value = try self.forceValue(try self.heap.getAttrValue(attrs_id, path_id));
    const path = switch (path_value.discriminant) {
        .path, .string, .string_context => self.intern.get(try stringTextInternId(self, path_value)),
        else => return error.TypeError,
    };
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;

    const name_id = try self.intern.intern("name");
    const name_value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => Value.null_val,
        else => return err,
    };
    var store_name = path_ops.baseName(path);
    if (name_value.discriminant != .null) {
        const name = try self.forceValue(name_value);
        if (!isPlainString(name)) return error.TypeError;
        store_name = self.intern.get(try stringTextInternId(self, name));
    }

    const filter_id = try self.intern.intern("filter");
    const filter_value = self.heap.getAttrValue(attrs_id, filter_id) catch |err| switch (err) {
        error.MissingAttribute => Value.null_val,
        else => return err,
    };

    const store_path = if (filter_value.discriminant == .null)
        try source_paths.storePathForSourceName(self.allocator, self.files, self.derivations.store_dir, path, store_name)
    else filtered: {
        const pred = try self.forceValue(filter_value);
        const Context = struct {
            vm: @TypeOf(self),
            pred: Value,

            fn accept(context: *anyopaque, candidate: []const u8, kind: file_cache.FileCache.FileKind) anyerror!bool {
                const ctx: *@This() = @ptrCast(@alignCast(context));
                return filterSourceAccepts(ctx.vm, ctx.pred, candidate, kind);
            }
        };
        var context: Context = .{ .vm = self, .pred = pred };
        const hash = try nar.hashPathFiltered(self.allocator, self.files, path, .{
            .context = &context,
            .accept = Context.accept,
        });
        defer self.allocator.free(hash);
        break :filtered try derivation.sourcePath(self.allocator, self.derivations.store_dir, store_name, hash);
    };
    defer self.allocator.free(store_path);
    return contextStringWithPath(self, try self.intern.intern(store_path));
}
