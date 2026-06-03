//! Builtin dispatch and builtin implementations for the bytecode VM.

const std = @import("std");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("../heap.zig");
const file_cache = @import("../file_cache.zig");
const fetch_cache = @import("../fetch_cache.zig");
const builtins_mod = @import("../builtins.zig");
const BuiltinId = builtins_mod.BuiltinId;
const derivation = @import("../derivation.zig");
const numeric = @import("../runtime/numeric.zig");
const path_ops = @import("../runtime/paths.zig");
const nix_hash = @import("../runtime/hash.zig");
const version = @import("../runtime/version.zig");
const regex = @import("../runtime/regex.zig");
const toml = @import("../runtime/toml.zig");
const ThunkState = @import("../thunk.zig").ThunkState;

fn firstReplacementAt(input: []const u8, needles: []const []const u8) ?usize {
    for (needles, 0..) |needle, i| {
        if (std.mem.startsWith(u8, input, needle)) return i;
    }
    return null;
}

fn firstReplacementIdAt(self: anytype, input: []const u8, needles: []const InternId) ?usize {
    for (needles, 0..) |needle_id, i| {
        if (std.mem.startsWith(u8, input, self.intern.get(needle_id))) return i;
    }
    return null;
}

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

fn makeBuiltinClosure(self: anytype, builtin_id: u16, args: []const Value) !Value {
    return Value.builtinClosure(try self.heap.addBuiltinClosure(builtin_id, args));
}

fn makeBuiltinThunk(self: anytype, id: BuiltinId, args: []const Value) !Value {
    return self.makeThunk(try makeBuiltinClosure(self, @intFromEnum(id), args));
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

fn builtinCatAttrs(self: anytype, name_arg: Value, list_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const list = try self.forceValue(list_arg);
    if (!isPlainString(name) or list.discriminant != .list) return error.TypeError;

    var values: std.ArrayListUnmanaged(Value) = .empty;
    defer values.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const attrs = try self.forceValue(item);
        if (attrs.discriminant != .attrs) return error.TypeError;
        const value = self.heap.getAttrValue(attrs.asObjectId(), try stringTextInternId(self, name)) catch |err| switch (err) {
            error.MissingAttribute => continue,
            else => return err,
        };
        try values.append(self.allocator, value);
    }

    return Value.list(try self.heap.addList(values.items));
}

fn builtinZipAttrsWith(self: anytype, func_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(func_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const Group = struct {
        name: InternId,
        values: std.ArrayListUnmanaged(Value) = .empty,
    };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer {
        for (groups.items) |*group| group.values.deinit(self.allocator);
        groups.deinit(self.allocator);
    }

    for (try self.heap.getList(list.asObjectId())) |item| {
        const attrs = try self.forceValue(item);
        if (attrs.discriminant != .attrs) return error.TypeError;

        for (try self.heap.getAttrs(attrs.asObjectId())) |entry| {
            const index = groupIndex(groups.items, entry.name) orelse blk: {
                try groups.append(self.allocator, .{ .name = entry.name });
                break :blk groups.items.len - 1;
            };
            try groups.items[index].values.append(self.allocator, entry.value);
        }
    }

    const entries = try self.allocator.alloc(heap_mod.AttrEntry, groups.items.len);
    defer self.allocator.free(entries);
    for (groups.items, entries) |group, *entry| {
        const values = Value.list(try self.heap.addList(group.values.items));
        entry.* = .{
            .name = group.name,
            .value = try makeBuiltinThunk(self, .zipAttrsValue, &.{ func, Value.string(group.name), values }),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

fn builtinZipAttrsValue(self: anytype, func_arg: Value, name_arg: Value, values_arg: Value) !Value {
    const partial = try self.callValue(func_arg, name_arg);
    return self.callValue(partial, values_arg);
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

fn builtinToJSON(self: anytype, arg: Value) !Value {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    try writeJsonValue(self, &out.writer, arg);
    const text = try out.toOwnedSlice();
    defer self.allocator.free(text);
    return Value.string(try self.intern.intern(text));
}

pub fn writeJsonValue(self: anytype, writer: *std.Io.Writer, value: Value) !void {
    var seen: std.ArrayListUnmanaged(SeenJsonObject) = .empty;
    defer seen.deinit(self.allocator);

    try writeJsonValueInner(self, writer, value, &seen);
}

const SeenJsonKind = enum { list, attrs };

const SeenJsonObject = struct {
    kind: SeenJsonKind,
    id: ObjectId,
};

fn writeJsonValueInner(self: anytype, writer: *std.Io.Writer, value: Value, seen: *std.ArrayListUnmanaged(SeenJsonObject)) anyerror!void {
    const forced = try self.forceValue(value);
    switch (forced.discriminant) {
        .null => try writer.writeAll("null"),
        .bool_false => try writer.writeAll("false"),
        .bool_true => try writer.writeAll("true"),
        .int => try writer.print("{}", .{forced.asInt()}),
        .float => try writer.print("{d}", .{forced.asFloat()}),
        .string, .path, .string_context => try std.json.Stringify.encodeJsonString(self.intern.get(try stringTextInternId(self, forced)), .{}, writer),
        .list => try writeJsonList(self, writer, forced.asObjectId(), seen),
        .attrs => {
            if (try jsonAttrsStringValue(self, forced)) |string_value| {
                try std.json.Stringify.encodeJsonString(self.intern.get(try stringTextInternId(self, string_value)), .{}, writer);
            } else {
                try writeJsonAttrs(self, writer, forced.asObjectId(), seen);
            }
        },
        .closure, .builtin, .builtin_closure => return error.TypeError,
        .thunk, .cell => unreachable,
    }
}

fn jsonAttrsStringValue(self: anytype, attrs: Value) !?Value {
    const attrs_id = attrs.asObjectId();

    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs_id, to_string_id)) |_| {
        return try coerceAttrsToStringValue(self, attrs);
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    if (self.heap.getAttrValue(attrs_id, out_path_id)) |_| {
        return try coerceAttrsToStringValue(self, attrs);
    } else |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    }
}

fn writeJsonList(self: anytype, writer: *std.Io.Writer, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenJsonObject)) !void {
    if (!try enterJsonObject(self, .list, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    try writer.writeByte('[');
    for (try self.heap.getList(id), 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonValueInner(self, writer, item, seen);
    }
    try writer.writeByte(']');
}

fn writeJsonAttrs(self: anytype, writer: *std.Io.Writer, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenJsonObject)) !void {
    if (!try enterJsonObject(self, .attrs, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    const sorted = try sortedAttrEntries(self, Value.attrs(id));
    defer self.allocator.free(sorted);

    try writer.writeByte('{');
    for (sorted, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(self.intern.get(entry.name), .{}, writer);
        try writer.writeByte(':');
        try writeJsonValueInner(self, writer, entry.value, seen);
    }
    try writer.writeByte('}');
}

fn enterJsonObject(self: anytype, kind: SeenJsonKind, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenJsonObject)) !bool {
    for (seen.items) |item| {
        if (item.kind == kind and item.id == id) return false;
    }
    try seen.append(self.allocator, .{ .kind = kind, .id = id });
    return true;
}

fn builtinToXML(self: anytype, arg: Value) !Value {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    var seen: std.ArrayListUnmanaged(SeenDeepObject) = .empty;
    defer seen.deinit(self.allocator);
    try forceDeep(self, arg, &seen);
    try writeXmlDocument(self, &out.writer, try self.forceValue(arg));

    const text = try out.toOwnedSlice();
    defer self.allocator.free(text);
    return Value.string(try self.intern.intern(text));
}

pub fn writeLazyXmlValue(self: anytype, writer: *std.Io.Writer, value: Value) !void {
    try writeXmlDocument(self, writer, try self.forceValue(value));
}

fn writeXmlDocument(self: anytype, writer: *std.Io.Writer, value: Value) !void {
    var seen: std.ArrayListUnmanaged(SeenJsonObject) = .empty;
    defer seen.deinit(self.allocator);

    try writer.writeAll("<?xml version='1.0' encoding='utf-8'?>\n<expr>\n");
    try writeXmlValue(self, writer, value, 1, &seen);
    try writer.writeAll("</expr>\n");
}

fn writeXmlValue(
    self: anytype,
    writer: *std.Io.Writer,
    value: Value,
    depth: usize,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
) anyerror!void {
    const maybe_forced = try xmlVisibleValue(self, value);
    const forced = maybe_forced orelse {
        try writeXmlIndent(writer, depth);
        try writer.writeAll("<unevaluated />\n");
        return;
    };

    try writeXmlIndent(writer, depth);
    switch (forced.discriminant) {
        .null => try writer.writeAll("<null />\n"),
        .bool_false => try writer.writeAll("<bool value=\"false\" />\n"),
        .bool_true => try writer.writeAll("<bool value=\"true\" />\n"),
        .int => try writer.print("<int value=\"{}\" />\n", .{forced.asInt()}),
        .float => try writer.print("<float value=\"{d}\" />\n", .{forced.asFloat()}),
        .string => {
            try writer.writeAll("<string value=\"");
            try writeXmlEscaped(writer, self.intern.get(forced.asInternId()));
            try writer.writeAll("\" />\n");
        },
        .string_context => {
            try writer.writeAll("<string value=\"");
            try writeXmlEscaped(writer, self.intern.get(try stringTextInternId(self, forced)));
            try writer.writeAll("\" />\n");
        },
        .path => {
            try writer.writeAll("<path value=\"");
            try writeXmlEscaped(writer, self.intern.get(forced.asInternId()));
            try writer.writeAll("\" />\n");
        },
        .list => try writeXmlList(self, writer, forced.asObjectId(), depth, seen),
        .attrs => try writeXmlAttrs(self, writer, forced.asObjectId(), depth, seen),
        .closure, .builtin, .builtin_closure => try writer.writeAll("<function />\n"),
        .thunk, .cell => unreachable,
    }
}

fn xmlVisibleValue(self: anytype, value: Value) anyerror!?Value {
    return switch (value.discriminant) {
        .thunk => xmlThunkValue(self, value.asObjectId()),
        .cell => xmlVisibleValue(self, try self.heap.getCellValue(value.asObjectId())),
        else => value,
    };
}

fn xmlThunkValue(self: anytype, id: ObjectId) anyerror!?Value {
    const thunk = try self.heap.getThunk(id);
    const state: ThunkState = @enumFromInt(thunk.state.load(.acquire));
    if (state != .resolved) return null;
    return xmlVisibleValue(self, thunk.result);
}

fn writeXmlList(
    self: anytype,
    writer: *std.Io.Writer,
    id: ObjectId,
    depth: usize,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
) !void {
    if (!try enterJsonObject(self, .list, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    try writer.writeAll("<list>\n");
    for (try self.heap.getList(id)) |item| try writeXmlValue(self, writer, item, depth + 1, seen);
    try writeXmlIndent(writer, depth);
    try writer.writeAll("</list>\n");
}

fn writeXmlAttrs(
    self: anytype,
    writer: *std.Io.Writer,
    id: ObjectId,
    depth: usize,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
) !void {
    if (!try enterJsonObject(self, .attrs, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    const sorted = try sortedAttrEntries(self, Value.attrs(id));
    defer self.allocator.free(sorted);

    try writer.writeAll("<attrs>\n");
    for (sorted) |entry| {
        try writeXmlIndent(writer, depth + 1);
        try writer.writeAll("<attr name=\"");
        try writeXmlEscaped(writer, self.intern.get(entry.name));
        try writer.writeAll("\">\n");
        try writeXmlValue(self, writer, entry.value, depth + 2, seen);
        try writeXmlIndent(writer, depth + 1);
        try writer.writeAll("</attr>\n");
    }
    try writeXmlIndent(writer, depth);
    try writer.writeAll("</attrs>\n");
}

fn writeXmlIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("  ");
}

fn writeXmlEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(c),
    };
}

fn builtinFromJSON(self: anytype, arg: Value) !Value {
    const text = try stringArg(self, arg);
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, text, .{});
    defer parsed.deinit();
    return valueFromJson(self, parsed.value);
}

fn valueFromJson(self: anytype, value: std.json.Value) anyerror!Value {
    return switch (value) {
        .null => Value.null_val,
        .bool => |b| Value.boolVal(b),
        .integer => |i| Value.int(i),
        .float => |f| Value.float(f),
        .number_string => |s| numberStringFromJson(self, s),
        .string => |s| Value.string(try self.intern.intern(s)),
        .array => |array| listFromJson(self, array.items),
        .object => |object| attrsFromJson(self, object),
    };
}

fn numberStringFromJson(self: anytype, text: []const u8) !Value {
    _ = self;
    if (std.fmt.parseInt(i64, text, 10)) |i| return Value.int(i) else |_| {}
    return Value.float(std.fmt.parseFloat(f64, text) catch return error.TypeError);
}

fn listFromJson(self: anytype, values: []const std.json.Value) !Value {
    const items = try self.allocator.alloc(Value, values.len);
    defer self.allocator.free(items);
    for (values, items) |item, *out| out.* = try valueFromJson(self, item);
    return Value.list(try self.heap.addList(items));
}

fn attrsFromJson(self: anytype, object: anytype) !Value {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, object.count());
    defer self.allocator.free(entries);

    var iter = object.iterator();
    var index: usize = 0;
    while (iter.next()) |entry| : (index += 1) {
        entries[index] = .{
            .name = try self.intern.intern(entry.key_ptr.*),
            .value = try valueFromJson(self, entry.value_ptr.*),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

fn builtinFromTOML(self: anytype, arg: Value) !Value {
    const text = try stringArg(self, arg);
    var parsed = try toml.parse(self.allocator, text);
    defer parsed.deinit();
    return valueFromToml(self, .{ .table = parsed.root });
}

fn valueFromToml(self: anytype, value: toml.Value) anyerror!Value {
    return switch (value) {
        .boolean => |b| Value.boolVal(b),
        .integer => |i| Value.int(i),
        .float => |f| Value.float(f),
        .string => |s| Value.string(try self.intern.intern(s)),
        .array => |items| listFromToml(self, items),
        .table => |table| attrsFromToml(self, table),
    };
}

fn listFromToml(self: anytype, values: []const toml.Value) !Value {
    const items = try self.allocator.alloc(Value, values.len);
    defer self.allocator.free(items);
    for (values, items) |item, *out| out.* = try valueFromToml(self, item);
    return Value.list(try self.heap.addList(items));
}

fn attrsFromToml(self: anytype, table: *toml.Table) !Value {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, table.entries.items.len);
    defer self.allocator.free(entries);
    for (table.entries.items, entries) |entry, *out| {
        out.* = .{
            .name = try self.intern.intern(entry.key),
            .value = try valueFromToml(self, entry.value),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

fn builtinCompareVersions(self: anytype, left_arg: Value, right_arg: Value) !Value {
    const left_value = try self.forceValue(left_arg);
    const right_value = try self.forceValue(right_arg);
    if (!isPlainString(left_value) or !isPlainString(right_value)) return error.TypeError;
    const left = self.intern.get(try stringTextInternId(self, left_value));
    const right = self.intern.get(try stringTextInternId(self, right_value));
    return Value.int(try version.compareVersions(self.allocator, left, right));
}

fn builtinSplitVersion(self: anytype, arg: Value) !Value {
    const text = try stringArg(self, arg);
    const parts = try version.splitVersion(self.allocator, text);
    defer self.allocator.free(parts);

    const values = try self.allocator.alloc(Value, parts.len);
    defer self.allocator.free(values);
    for (parts, values) |part, *value| {
        value.* = Value.string(try self.intern.intern(part));
    }
    return Value.list(try self.heap.addList(values));
}

fn builtinMatch(self: anytype, regex_arg: Value, text_arg: Value) !Value {
    const pattern_value = try self.forceValue(regex_arg);
    const text_value = try self.forceValue(text_arg);
    if (!isPlainString(pattern_value) or !isPlainString(text_value)) return error.TypeError;
    const pattern_text = self.intern.get(try stringTextInternId(self, pattern_value));
    const text = self.intern.get(try stringTextInternId(self, text_value));

    var pattern = try regex.Pattern.compile(self.allocator, pattern_text);
    defer pattern.deinit();

    const matched = (try pattern.matchFull(self.allocator, text)) orelse return Value.null_val;
    defer matched.deinit(self.allocator);
    return regexCapturesValue(self, matched.captures);
}

fn builtinSplit(self: anytype, regex_arg: Value, text_arg: Value) !Value {
    const pattern_value = try self.forceValue(regex_arg);
    const text_value = try self.forceValue(text_arg);
    if (!isPlainString(pattern_value) or !isPlainString(text_value)) return error.TypeError;
    const pattern_text = self.intern.get(try stringTextInternId(self, pattern_value));
    const text = self.intern.get(try stringTextInternId(self, text_value));

    var pattern = try regex.Pattern.compile(self.allocator, pattern_text);
    defer pattern.deinit();

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    var cursor: usize = 0;
    var search_start: usize = 0;
    while (search_start <= text.len) {
        const found = (try pattern.find(self.allocator, text, search_start)) orelse break;
        errdefer found.deinit(self.allocator);

        try out.append(self.allocator, Value.string(try self.intern.intern(text[cursor..found.start])));
        try out.append(self.allocator, try regexCapturesValue(self, found.captures));

        cursor = found.end;
        search_start = found.end;
        if (found.start == found.end) {
            if (cursor >= text.len) {
                found.deinit(self.allocator);
                break;
            }
            try out.append(self.allocator, Value.string(try self.intern.intern(text[cursor .. cursor + 1])));
            cursor += 1;
            search_start = cursor;
        }
        found.deinit(self.allocator);
    }

    try out.append(self.allocator, Value.string(try self.intern.intern(text[cursor..])));
    return Value.list(try self.heap.addList(out.items));
}

fn regexCapturesValue(self: anytype, captures: []const ?[]const u8) !Value {
    const values = try self.allocator.alloc(Value, captures.len);
    defer self.allocator.free(values);

    for (captures, values) |capture, *value| {
        value.* = if (capture) |text|
            Value.string(try self.intern.intern(text))
        else
            Value.null_val;
    }
    return Value.list(try self.heap.addList(values));
}

fn builtinParseDrvName(self: anytype, arg: Value) !Value {
    const parsed = version.parseDrvName(try stringArg(self, arg));
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("name"),
            .value = Value.string(try self.intern.intern(parsed.name)),
        },
        .{
            .name = try self.intern.intern("version"),
            .value = Value.string(try self.intern.intern(parsed.version)),
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
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

fn pathArg(self: anytype, arg: Value) ![]const u8 {
    const value = try self.stringLikeValue(arg);
    return switch (value.discriminant) {
        .path, .string => self.intern.get(value.asInternId()),
        .string_context => self.intern.get((try self.heap.getContextString(value.asObjectId())).text),
        else => self.typeErrorExpected("path or string", value),
    };
}

fn attrEntryNameIndex(entries: []const heap_mod.AttrEntry, name: InternId) ?usize {
    for (entries, 0..) |entry, i| {
        if (entry.name == name) return i;
    }
    return null;
}

fn groupIndex(groups: anytype, name: InternId) ?usize {
    for (groups, 0..) |group, i| {
        if (group.name == name) return i;
    }
    return null;
}

fn callComparator(self: anytype, cmp: Value, left: Value, right: Value) !bool {
    const partial = try self.callValue(cmp, left);
    const result = try self.forceValue(try self.callValue(partial, right));
    if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
    return result.discriminant == .bool_true;
}

fn genericClosureAppend(
    self: anytype,
    item: Value,
    result: *std.ArrayListUnmanaged(Value),
    keys: *std.ArrayListUnmanaged(Value),
) !void {
    const forced = try self.forceValue(item);
    if (forced.discriminant != .attrs) return error.TypeError;
    const key = try self.forceValue(try self.heap.getAttrValue(forced.asObjectId(), try self.intern.intern("key")));
    for (keys.items) |seen| {
        if (try self.valuesEqual(seen, key)) return;
    }
    try keys.append(self.allocator, key);
    try result.append(self.allocator, item);
}

fn builtinAttrNames(self: anytype, arg: Value) !Value {
    const entries = try sortedAttrEntries(self, arg);
    defer self.allocator.free(entries);

    const values = try self.allocator.alloc(Value, entries.len);
    defer self.allocator.free(values);

    for (entries, values) |entry, *value| {
        value.* = Value.string(entry.name);
    }
    return Value.list(try self.heap.addList(values));
}

fn builtinAttrValues(self: anytype, arg: Value) !Value {
    const entries = try sortedAttrEntries(self, arg);
    defer self.allocator.free(entries);

    const values = try self.allocator.alloc(Value, entries.len);
    defer self.allocator.free(values);

    for (entries, values) |entry, *value| {
        value.* = entry.value;
    }
    return Value.list(try self.heap.addList(values));
}

fn sortedAttrEntries(self: anytype, arg: Value) ![]heap_mod.AttrEntry {
    const value = try self.forceValue(arg);
    if (value.discriminant != .attrs) return error.TypeError;

    const entries = try self.heap.getAttrs(value.asObjectId());
    const sorted = try self.allocator.dupe(heap_mod.AttrEntry, entries);
    const Comparator = struct {
        fn lessThan(vm: @TypeOf(self), a: heap_mod.AttrEntry, b: heap_mod.AttrEntry) bool {
            return std.mem.lessThan(u8, vm.intern.get(a.name), vm.intern.get(b.name));
        }
    };
    std.mem.sort(heap_mod.AttrEntry, sorted, self, Comparator.lessThan);
    return sorted;
}

fn builtinHasAttr(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const attrs = try self.forceValue(attrs_arg);
    if (name.discriminant != .string or attrs.discriminant != .attrs) return error.TypeError;

    _ = self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()) catch |err| switch (err) {
        error.MissingAttribute => return Value.boolVal(false),
        else => return err,
    };
    return Value.boolVal(true);
}

fn builtinGetAttr(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const attrs = try self.forceValue(attrs_arg);
    if (name.discriminant != .string or attrs.discriminant != .attrs) return error.TypeError;

    return self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()));
}

fn builtinElemAt(self: anytype, list_arg: Value, index_arg: Value) !Value {
    const list = try self.forceValue(list_arg);
    const index = try self.forceValue(index_arg);
    if (list.discriminant != .list or index.discriminant != .int) return error.TypeError;
    if (index.asInt() < 0) return error.IndexOutOfBounds;

    const items = try self.heap.getList(list.asObjectId());
    const i: usize = @intCast(index.asInt());
    if (i >= items.len) return error.IndexOutOfBounds;
    return self.forceValue(items[i]);
}

fn builtinElem(self: anytype, needle: Value, list_arg: Value) !Value {
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    for (items) |item| {
        if (try self.valuesEqual(needle, item)) return Value.boolVal(true);
    }
    return Value.boolVal(false);
}

fn builtinSeq(self: anytype, first: Value, second: Value) !Value {
    _ = try self.forceValue(first);
    return self.forceValue(second);
}

fn builtinDeepSeq(self: anytype, first: Value, second: Value) !Value {
    var seen: std.ArrayListUnmanaged(SeenDeepObject) = .empty;
    defer seen.deinit(self.allocator);
    try forceDeep(self, first, &seen);
    return self.forceValue(second);
}

const SeenDeepKind = enum { list, attrs };

const SeenDeepObject = struct {
    kind: SeenDeepKind,
    id: ObjectId,
};

fn forceDeep(self: anytype, value: Value, seen: *std.ArrayListUnmanaged(SeenDeepObject)) anyerror!void {
    const forced = try self.forceValue(value);
    switch (forced.discriminant) {
        .list => {
            const id = forced.asObjectId();
            if (!try enterDeep(self, .list, id, seen)) return;
            for (try self.heap.getList(id)) |item| try forceDeep(self, item, seen);
        },
        .attrs => {
            const id = forced.asObjectId();
            if (!try enterDeep(self, .attrs, id, seen)) return;
            for (try self.heap.getAttrs(id)) |entry| try forceDeep(self, entry.value, seen);
        },
        else => {},
    }
}

fn enterDeep(self: anytype, kind: SeenDeepKind, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenDeepObject)) !bool {
    for (seen.items) |item| {
        if (item.kind == kind and item.id == id) return false;
    }
    try seen.append(self.allocator, .{ .kind = kind, .id = id });
    return true;
}

fn builtinAll(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_false) return Value.boolVal(false);
    }
    return Value.boolVal(true);
}

fn builtinAny(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_true) return Value.boolVal(true);
    }
    return Value.boolVal(false);
}

fn builtinFilter(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_true) try out.append(self.allocator, item);
    }

    return Value.list(try self.heap.addList(out.items));
}

fn builtinMap(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    if (!try isCallable(self, func)) return error.NotCallable;
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const out = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(out);

    for (items, out) |item, *mapped| {
        mapped.* = try makeBuiltinThunk(self, .mapValue, &.{ func, item });
    }
    return Value.list(try self.heap.addList(out));
}

fn builtinMapValue(self: anytype, func_arg: Value, item_arg: Value) !Value {
    const func = try self.forceValue(func_arg);
    return self.callValue(func, item_arg);
}

fn builtinConcatMap(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const mapped = try self.forceValue(try self.callValue(func, item));
        if (mapped.discriminant != .list) return error.TypeError;
        try out.appendSlice(self.allocator, try self.heap.getList(mapped.asObjectId()));
    }
    return Value.list(try self.heap.addList(out.items));
}

fn builtinMapAttrs(self: anytype, fn_arg: Value, attrs_arg: Value) !Value {
    const attrs = try self.forceValue(attrs_arg);
    if (attrs.discriminant != .attrs) return error.TypeError;

    const attr_entries = try self.heap.getAttrs(attrs.asObjectId());
    const out = try self.allocator.alloc(heap_mod.AttrEntry, attr_entries.len);
    defer self.allocator.free(out);

    for (attr_entries, out) |entry, *mapped| {
        mapped.* = .{
            .name = entry.name,
            .value = try makeBuiltinThunk(self, .mapAttrValue, &.{ fn_arg, Value.string(entry.name), entry.value }),
        };
    }
    return Value.attrs(try self.heap.addAttrs(out));
}

fn builtinMapAttrValue(self: anytype, func_arg: Value, name_arg: Value, value_arg: Value) !Value {
    const func = try self.forceValue(func_arg);
    const partial = try self.callValue(func, name_arg);
    return self.callValue(partial, value_arg);
}

fn builtinGenList(self: anytype, fn_arg: Value, count_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    const count = try self.forceValue(count_arg);
    if (count.discriminant != .int or count.asInt() < 0) return error.TypeError;

    const len: usize = @intCast(count.asInt());
    const out = try self.allocator.alloc(Value, len);
    defer self.allocator.free(out);

    for (out, 0..) |*value, i| {
        value.* = try self.callValue(func, Value.int(@intCast(i)));
    }
    return Value.list(try self.heap.addList(out));
}

fn builtinStringLength(self: anytype, arg: Value) !Value {
    return Value.int(@intCast(self.intern.get(try coerceStringContextId(self, arg)).len));
}

fn builtinConcatStringsSep(self: anytype, sep_arg: Value, list_arg: Value) !Value {
    const sep_value = try self.forceValue(sep_arg);
    const list = try self.forceValue(list_arg);
    if (!isPlainString(sep_value) or list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const item_values = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(item_values);
    for (items, item_values) |item, *value| value.* = try coerceStringContextValue(self, item);

    const sep = self.intern.get(try stringTextInternId(self, sep_value));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    for (item_values, 0..) |item_value, i| {
        if (i > 0) try out.appendSlice(self.allocator, sep);
        const item_id = try stringTextInternId(self, item_value);
        try out.appendSlice(self.allocator, self.intern.get(item_id));
        for (try contextEntriesForValue(self, item_value)) |entry| {
            try appendContextEntry(self, &context, entry.name, entry.value);
        }
    }

    const text_id = try self.intern.intern(out.items);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

fn coerceStringContextId(self: anytype, arg: Value) !InternId {
    return stringTextInternId(self, try coerceStringContextValue(self, arg));
}

fn coerceStringContextValue(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return switch (value.discriminant) {
        .string, .path, .string_context => value,
        .attrs => coerceAttrsStringContextValue(self, value),
        else => error.TypeError,
    };
}

fn coerceAttrsStringContextValue(self: anytype, attrs: Value) !Value {
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        const result = try self.callValue(try self.forceValue(to_string), attrs);
        return coerceStringContextValue(self, result);
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return error.TypeError,
        else => return err,
    };
    return coerceStringContextValue(self, out_path);
}

fn builtinSubstring(self: anytype, start_arg: Value, len_arg: Value, string_arg: Value) !Value {
    const start_value = try self.forceValue(start_arg);
    const len_value = try self.forceValue(len_arg);
    if (start_value.discriminant != .int or len_value.discriminant != .int) return error.TypeError;
    if (start_value.asInt() < 0) return error.TypeError;

    const string_value = try coerceStringContextValue(self, string_arg);
    const string = self.intern.get(try stringTextInternId(self, string_value));
    const start: usize = @intCast(start_value.asInt());
    if (start >= string.len) return Value.string(try self.intern.intern(""));
    const available = string.len - start;
    const requested_len: usize = if (len_value.asInt() < 0) available else @intCast(len_value.asInt());
    const end = start + @min(available, requested_len);
    const text_id = try self.intern.intern(string[start..end]);
    const context = try contextEntriesForValue(self, string_value);
    if (context.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context));
}

fn builtinReplaceStrings(self: anytype, from_arg: Value, to_arg: Value, string_arg: Value) !Value {
    const from_ids = try stringListInternIdsArg(self, from_arg);
    defer self.allocator.free(from_ids);
    const to_ids = try stringListInternIdsArg(self, to_arg);
    defer self.allocator.free(to_ids);
    const input_value = try self.forceValue(string_arg);
    if (from_ids.len != to_ids.len or !isPlainString(input_value)) return error.TypeError;

    const input = self.intern.get(try stringTextInternId(self, input_value));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);

    var index: usize = 0;
    while (index < input.len) {
        if (firstReplacementIdAt(self, input[index..], from_ids)) |replacement_index| {
            const needle = self.intern.get(from_ids[replacement_index]);
            if (needle.len == 0) return error.TypeError;
            try out.appendSlice(self.allocator, self.intern.get(to_ids[replacement_index]));
            index += needle.len;
        } else {
            try out.append(self.allocator, input[index]);
            index += 1;
        }
    }

    return Value.string(try self.intern.intern(out.items));
}

fn builtinThrow(self: anytype, message_arg: Value) !Value {
    try self.setErrorMessage(try stringArg(self, message_arg));
    return error.NixThrow;
}

fn builtinAbort(self: anytype, message_arg: Value) !Value {
    try self.setErrorMessage(try stringArg(self, message_arg));
    return error.NixAbort;
}

fn builtinTryEval(self: anytype, arg: Value) !Value {
    const value = self.forceValue(arg) catch |err| switch (err) {
        error.NixThrow,
        error.NixAbort,
        error.AssertionFailed,
        error.FileNotFound,
        => {
            self.clearErrorTrace();
            return tryEvalResult(self, false, Value.boolVal(false));
        },
        else => return err,
    };
    return tryEvalResult(self, true, value);
}

fn builtinAddErrorContext(self: anytype, message_arg: Value, value_arg: Value) !Value {
    return self.forceValue(value_arg) catch |err| {
        const message = stringArg(self, message_arg) catch return err;
        self.pushErrorContext(message) catch return err;
        return err;
    };
}

fn builtinTrace(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try self.forceValue(message_arg);
    return self.forceValue(value_arg);
}

fn builtinTraceVerbose(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try self.forceValue(message_arg);
    return self.forceValue(value_arg);
}

fn builtinGetContext(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return Value.attrs(try self.heap.addAttrs(try contextEntriesForValue(self, value)));
}

fn builtinHasContext(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return Value.boolVal((try contextEntriesForValue(self, value)).len != 0);
}

fn builtinAppendContext(self: anytype, string_arg: Value, context_arg: Value) !Value {
    const string_value = try self.forceValue(string_arg);
    if (!isStringLike(string_value)) return error.TypeError;
    const context_value = try self.forceValue(context_arg);
    if (context_value.discriminant != .attrs) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, string_value)) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);
    for (try self.heap.getAttrs(context_value.asObjectId())) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);

    if (entries.items.len == 0) return Value.string(try stringTextInternId(self, string_value));
    return Value.contextString(try self.heap.addContextString(try stringTextInternId(self, string_value), entries.items));
}

fn builtinUnsafeDiscardStringContext(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (!isStringLike(value)) return error.TypeError;
    return Value.string(try stringTextInternId(self, value));
}

fn builtinUnsafeDiscardOutputDependency(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (!isStringLike(value)) return error.TypeError;
    const text_id = try stringTextInternId(self, value);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, value)) |entry| {
        try appendContextEntry(self, &entries, entry.name, try pathContextValue(self));
    }
    if (entries.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

fn builtinAddDrvOutputDependencies(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (!isStringLike(value)) return error.TypeError;
    const text_id = try stringTextInternId(self, value);
    const text = self.intern.get(text_id);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, value)) |entry| {
        const path = self.intern.get(entry.name);
        const context_value = if (std.mem.endsWith(u8, path, ".drv"))
            try allOutputsContextValue(self)
        else
            entry.value;
        try appendContextEntry(self, &entries, entry.name, context_value);
    }
    if (entries.items.len == 0 and std.mem.endsWith(u8, text, ".drv")) {
        try appendContextEntry(self, &entries, text_id, try allOutputsContextValue(self));
    }
    if (entries.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

fn builtinGetEnv(self: anytype, name_arg: Value) !Value {
    const name = try stringArg(self, name_arg);
    const host = self.import_host orelse return Value.string(try self.intern.intern(""));
    const value = try host.get_env(host.context, name);
    return Value.string(try self.intern.intern(value));
}

fn builtinToPath(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    const text_id: InternId = switch (value.discriminant) {
        .path, .string, .string_context => try stringTextInternId(self, value),
        else => return error.TypeError,
    };
    if (!std.fs.path.isAbsolute(self.intern.get(text_id))) return error.RelativePath;
    if (value.discriminant == .string_context) return value;
    return Value.string(text_id);
}

fn builtinToFile(self: anytype, name_arg: Value, contents_arg: Value) !Value {
    const name_value = try self.forceValue(name_arg);
    const contents_value = try self.forceValue(contents_arg);
    if (!isStringLike(name_value) or !isStringLike(contents_value)) return error.TypeError;

    const name = self.intern.get(try stringTextInternId(self, name_value));
    const contents = self.intern.get(try stringTextInternId(self, contents_value));
    const path_id = try storeLikePath(self, name, contents);
    return contextStringWithPath(self, path_id);
}

fn builtinFilterSource(self: anytype, pred_arg: Value, path_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const root_arg = try pathArg(self, path_arg);
    const root = try self.allocator.dupe(u8, root_arg);
    defer self.allocator.free(root);

    var fingerprint: std.ArrayListUnmanaged(u8) = .empty;
    defer fingerprint.deinit(self.allocator);
    try fingerprint.appendSlice(self.allocator, "filterSource\n");
    try fingerprint.appendSlice(self.allocator, root);
    try fingerprint.append(self.allocator, '\n');

    const root_kind = try self.files.fileType(root);
    try fingerprint.appendSlice(self.allocator, root_kind.nixTypeName());
    try fingerprint.append(self.allocator, '\n');
    if (root_kind == .directory) {
        try appendFilteredTreeFingerprint(self, pred, root, &fingerprint);
    }

    return Value.string(try storeLikePath(self, path_ops.baseName(root), fingerprint.items));
}

const FetchGitSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,
    ref: ?[]u8,
    submodules: bool,

    fn deinit(self: FetchGitSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
        if (self.ref) |ref| allocator.free(ref);
    }

    fn borrowed(self: FetchGitSpec) fetch_cache.FetchCache.GitSpec {
        return .{
            .url = self.url,
            .name = self.name,
            .rev = self.rev,
            .ref = self.ref,
            .submodules = self.submodules,
        };
    }
};

fn builtinFetchGit(self: anytype, arg: Value) !Value {
    const spec = try fetchGitSpec(self, arg);
    defer spec.deinit(self.allocator);

    const result = try self.fetchers.fetchGit(self.files, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);
    return gitResultValue(self, result);
}

fn gitResultValue(self: anytype, result: fetch_cache.FetchCache.GitResult) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(result.last_modified) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern(result.last_modified_date)) },
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(result.nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = Value.string(try self.intern.intern(result.out_path)) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
        .{ .name = try self.intern.intern("revCount"), .value = Value.int(result.rev_count) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
        .{ .name = try self.intern.intern("submodules"), .value = Value.boolVal(result.submodules) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn pathTreeValue(self: anytype, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(0) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern("19700101000000")) },
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = Value.string(try self.intern.intern(path)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn fileTreeValue(self: anytype, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = Value.string(try self.intern.intern(path)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn fetchGitSpec(self: anytype, arg: Value) !FetchGitSpec {
    const value = try self.forceValue(arg);
    if (value.discriminant != .attrs) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try self.allocator.dupe(u8, "source"),
            .rev = null,
            .ref = null,
            .submodules = false,
        };
    }

    return fetchGitSpecFromAttrs(self, value.asObjectId());
}

fn fetchGitSpecFromAttrs(self: anytype, attrs_id: ObjectId) !FetchGitSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    errdefer self.allocator.free(name);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev) |owned| self.allocator.free(owned);
    const ref = try optionalStringAttr(self, attrs_id, "ref");
    errdefer if (ref) |owned| self.allocator.free(owned);
    const submodules = try optionalBoolAttr(self, attrs_id, "submodules") orelse false;

    return .{
        .url = url,
        .name = name,
        .rev = rev,
        .ref = ref,
        .submodules = submodules,
    };
}

const FetchUrlSpec = struct {
    url: []u8,
    name: []u8,

    fn deinit(self: FetchUrlSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
    }

    fn borrowed(self: FetchUrlSpec) fetch_cache.FetchCache.UrlSpec {
        return .{ .url = self.url, .name = self.name };
    }
};

fn builtinFetchurl(self: anytype, arg: Value) !Value {
    const spec = try fetchUrlSpec(self, arg);
    defer spec.deinit(self.allocator);

    const result = try self.fetchers.fetchUrl(self.files, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);
    return Value.string(try self.intern.intern(result.path));
}

fn fetchUrlSpec(self: anytype, arg: Value) !FetchUrlSpec {
    const value = try self.forceValue(arg);
    if (value.discriminant != .attrs) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try defaultFetchName(self, url),
        };
    }

    return fetchUrlSpecFromAttrs(self, value.asObjectId(), null);
}

fn fetchUrlSpecFromAttrs(self: anytype, attrs_id: ObjectId, default_name: ?[]const u8) !FetchUrlSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse if (default_name) |name|
        try self.allocator.dupe(u8, name)
    else
        try defaultFetchName(self, url);
    return .{ .url = url, .name = name };
}

fn builtinFetchTarball(self: anytype, arg: Value) !Value {
    const spec = try fetchUrlSpec(self, arg);
    defer spec.deinit(self.allocator);

    const path = try self.fetchers.fetchTarball(self.files, .{ .url = spec.url, .name = spec.name });
    defer self.fetchers.allocator.free(path);
    return Value.string(try self.intern.intern(path));
}

const FetchMercurialSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,

    fn deinit(self: FetchMercurialSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
    }

    fn borrowed(self: FetchMercurialSpec) fetch_cache.FetchCache.MercurialSpec {
        return .{ .url = self.url, .name = self.name, .rev = self.rev };
    }
};

fn builtinFetchMercurial(self: anytype, arg: Value) !Value {
    const spec = try fetchMercurialSpec(self, arg);
    defer spec.deinit(self.allocator);

    const result = try self.fetchers.fetchMercurial(self.files, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);

    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(result.nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = Value.string(try self.intern.intern(result.out_path)) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn fetchMercurialSpec(self: anytype, arg: Value) !FetchMercurialSpec {
    const value = try self.forceValue(arg);
    if (value.discriminant != .attrs) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try self.allocator.dupe(u8, "source"),
            .rev = null,
        };
    }

    return fetchMercurialSpecFromAttrs(self, value.asObjectId());
}

fn fetchMercurialSpecFromAttrs(self: anytype, attrs_id: ObjectId) !FetchMercurialSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    errdefer self.allocator.free(name);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev) |owned| self.allocator.free(owned);

    return .{ .url = url, .name = name, .rev = rev };
}

const GithubTreeSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,

    fn deinit(self: GithubTreeSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
    }
};

fn githubTreeSpec(self: anytype, attrs_id: ObjectId) !GithubTreeSpec {
    const owner = try requiredStringAttr(self, attrs_id, "owner");
    defer self.allocator.free(owner);
    const repo = try requiredStringAttr(self, attrs_id, "repo");
    defer self.allocator.free(repo);
    const rev = try optionalStringAttr(self, attrs_id, "rev") orelse try optionalStringAttr(self, attrs_id, "ref");
    errdefer if (rev) |owned| self.allocator.free(owned);
    const archive_ref = rev orelse "HEAD";
    const url = try std.fmt.allocPrint(self.allocator, "https://github.com/{s}/{s}/archive/{s}.tar.gz", .{ owner, repo, archive_ref });
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    return .{ .url = url, .name = name, .rev = rev };
}

fn githubTreeValue(self: anytype, path: []const u8, nar_hash: []const u8, rev: ?[]const u8) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try entries.appendSlice(self.allocator, &.{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(0) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern("19700101000000")) },
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = Value.string(try self.intern.intern(path)) },
    });
    if (rev) |value| {
        try appendStringAttr(self, &entries, "rev", value);
        try appendStringAttr(self, &entries, "shortRev", value[0..@min(value.len, 7)]);
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn builtinFetchTree(self: anytype, arg: Value) !Value {
    const attrs = try self.forceValue(arg);
    if (attrs.discriminant == .path) {
        const path = self.intern.get(attrs.asInternId());
        const nar_hash = try self.fetchers.sourceHash(path, "");
        defer self.fetchers.allocator.free(nar_hash);
        return pathTreeValue(self, path, nar_hash);
    }
    if (attrs.discriminant == .string) {
        const parsed = try builtinParseFlakeRef(self, attrs);
        return builtinFetchTree(self, parsed);
    }
    if (attrs.discriminant != .attrs) return error.TypeError;

    const attrs_id = attrs.asObjectId();
    const type_value = try requiredStringAttr(self, attrs_id, "type");
    defer self.allocator.free(type_value);

    if (std.mem.eql(u8, type_value, "path")) {
        const path = try dupPathAttr(self, attrs_id, "path");
        defer self.allocator.free(path);
        const nar_hash = try self.fetchers.sourceHash(path, "");
        defer self.fetchers.allocator.free(nar_hash);
        return pathTreeValue(self, path, nar_hash);
    }

    if (std.mem.eql(u8, type_value, "file")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, null);
        defer spec.deinit(self.allocator);
        const result = try self.fetchers.fetchUrl(self.files, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        return fileTreeValue(self, result.path, result.hash);
    }

    if (std.mem.eql(u8, type_value, "tarball")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, "source");
        defer spec.deinit(self.allocator);
        const path = try self.fetchers.fetchTarball(self.files, .{ .url = spec.url, .name = spec.name });
        defer self.fetchers.allocator.free(path);
        const nar_hash = try self.fetchers.sourceHash(path, "");
        defer self.fetchers.allocator.free(nar_hash);
        return pathTreeValue(self, path, nar_hash);
    }

    if (std.mem.eql(u8, type_value, "git")) {
        const spec = try fetchGitSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try self.fetchers.fetchGit(self.files, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        return gitResultValue(self, result);
    }

    if (std.mem.eql(u8, type_value, "github")) {
        const spec = try githubTreeSpec(self, attrs_id);
        defer spec.deinit(self.allocator);
        const path = try self.fetchers.fetchTarball(self.files, .{ .url = spec.url, .name = spec.name });
        defer self.fetchers.allocator.free(path);
        const nar_hash = try self.fetchers.sourceHash(path, spec.rev orelse "");
        defer self.fetchers.allocator.free(nar_hash);
        return githubTreeValue(self, path, nar_hash, spec.rev);
    }

    if (std.mem.eql(u8, type_value, "mercurial")) {
        const spec = try fetchMercurialSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try self.fetchers.fetchMercurial(self.files, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        const entries = [_]heap_mod.AttrEntry{
            .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(result.nar_hash)) },
            .{ .name = try self.intern.intern("outPath"), .value = Value.string(try self.intern.intern(result.out_path)) },
            .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
            .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
        };
        return Value.attrs(try self.heap.addAttrs(&entries));
    }

    return error.InvalidFlakeRef;
}

fn builtinGetFlake(self: anytype, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    const ref_value = Value.string(try self.intern.intern(ref));
    const source_info = try builtinFetchTree(self, try builtinParseFlakeRef(self, ref_value));
    const out_path = try requiredStringAttr(self, source_info.asObjectId(), "outPath");
    defer self.allocator.free(out_path);

    const flake_path = try std.fs.path.join(self.allocator, &.{ out_path, "flake.nix" });
    defer self.allocator.free(flake_path);

    const host = self.import_host orelse return error.ImportUnavailable;
    const flake_value = try self.forceValue(try host.import_value(host.context, flake_path));
    if (flake_value.discriminant != .attrs) return error.TypeError;

    const outputs_id = try self.intern.intern("outputs");
    const outputs_func = try self.forceValue(try self.heap.getAttrValue(flake_value.asObjectId(), outputs_id));
    const self_input = try flakeSelfInput(self, source_info);
    const inputs_entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("self"), .value = self_input },
    };
    const inputs = Value.attrs(try self.heap.addAttrs(&inputs_entries));
    const outputs = try self.forceValue(try self.callValue(outputs_func, inputs));
    if (outputs.discriminant != .attrs) return error.TypeError;

    return flakeResultValue(self, source_info, inputs, outputs);
}

fn flakeSelfInput(self: anytype, source_info: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try entries.append(self.allocator, .{ .name = try self.intern.intern("_type"), .value = Value.string(try self.intern.intern("flake")) });
    try appendExistingAttr(self, &entries, source_info.asObjectId(), "outPath");
    try entries.append(self.allocator, .{ .name = try self.intern.intern("sourceInfo"), .value = source_info });
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn flakeResultValue(self: anytype, source_info: Value, inputs: Value, outputs: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    try entries.append(self.allocator, .{ .name = try self.intern.intern("_type"), .value = Value.string(try self.intern.intern("flake")) });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("inputs"), .value = inputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("outputs"), .value = outputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("sourceInfo"), .value = source_info });

    const source_attrs_id = source_info.asObjectId();
    try appendExistingAttr(self, &entries, source_attrs_id, "lastModified");
    try appendExistingAttr(self, &entries, source_attrs_id, "lastModifiedDate");
    try appendExistingAttr(self, &entries, source_attrs_id, "narHash");
    try appendExistingAttr(self, &entries, source_attrs_id, "outPath");
    try appendExistingAttr(self, &entries, source_attrs_id, "rev");
    try appendExistingAttr(self, &entries, source_attrs_id, "shortRev");

    for (try self.heap.getAttrs(outputs.asObjectId())) |entry| {
        if (attrEntryNameIndex(entries.items, entry.name) == null) {
            try entries.append(self.allocator, entry);
        }
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn appendExistingAttr(self: anytype, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), attrs_id: ObjectId, name: []const u8) !void {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return,
        else => return err,
    };
    try entries.append(self.allocator, .{ .name = name_id, .value = value });
}

fn builtinParseFlakeRef(self: anytype, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    if (std.mem.startsWith(u8, ref, "github:")) {
        try appendStringAttr(self, &entries, "type", "github");
        var parts = std.mem.splitScalar(u8, ref["github:".len..], '/');
        const owner = parts.next() orelse return error.InvalidFlakeRef;
        const repo = parts.next() orelse return error.InvalidFlakeRef;
        try appendStringAttr(self, &entries, "owner", owner);
        try appendStringAttr(self, &entries, "repo", repo);
        if (parts.next()) |branch| {
            if (branch.len != 0) try appendStringAttr(self, &entries, "ref", branch);
        }
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    if (std.mem.startsWith(u8, ref, "path:")) {
        try appendStringAttr(self, &entries, "type", "path");
        const rest = ref["path:".len..];
        const query_start = std.mem.indexOfScalar(u8, rest, '?');
        const path = if (query_start) |i| rest[0..i] else rest;
        try appendStringAttr(self, &entries, "path", path);
        if (query_start) |i| try appendFlakeQueryAttrs(self, &entries, rest[i + 1 ..]);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    if (std.fs.path.isAbsolute(ref)) {
        try appendStringAttr(self, &entries, "type", "path");
        try appendStringAttr(self, &entries, "path", ref);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    return error.InvalidFlakeRef;
}

fn builtinFlakeRefToString(self: anytype, arg: Value) !Value {
    const attrs = try self.forceValue(arg);
    if (attrs.discriminant != .attrs) return error.TypeError;

    const type_value = try requiredStringAttr(self, attrs.asObjectId(), "type");
    defer self.allocator.free(type_value);
    if (std.mem.eql(u8, type_value, "github")) {
        const owner = try requiredStringAttr(self, attrs.asObjectId(), "owner");
        defer self.allocator.free(owner);
        const repo = try requiredStringAttr(self, attrs.asObjectId(), "repo");
        defer self.allocator.free(repo);
        const ref = try optionalStringAttr(self, attrs.asObjectId(), "ref");
        defer if (ref) |owned| self.allocator.free(owned);
        const text = if (ref) |branch|
            try std.fmt.allocPrint(self.allocator, "github:{s}/{s}/{s}", .{ owner, repo, branch })
        else
            try std.fmt.allocPrint(self.allocator, "github:{s}/{s}", .{ owner, repo });
        defer self.allocator.free(text);
        return Value.string(try self.intern.intern(text));
    }

    if (std.mem.eql(u8, type_value, "path")) {
        const path = try requiredStringAttr(self, attrs.asObjectId(), "path");
        defer self.allocator.free(path);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "path:");
        try out.appendSlice(self.allocator, path);
        var first_query = true;
        try appendFlakeQueryString(self, attrs.asObjectId(), "ref", &out, &first_query);
        try appendFlakeQueryString(self, attrs.asObjectId(), "rev", &out, &first_query);
        try appendFlakeQueryString(self, attrs.asObjectId(), "narHash", &out, &first_query);
        return Value.string(try self.intern.intern(out.items));
    }

    return error.InvalidFlakeRef;
}

fn appendFlakeQueryAttrs(self: anytype, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), query: []const u8) !void {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        if (std.mem.eql(u8, key, "ref") or std.mem.eql(u8, key, "rev") or std.mem.eql(u8, key, "narHash")) {
            try appendStringAttr(self, entries, key, value);
        }
    }
}

fn appendFlakeQueryString(self: anytype, attrs_id: ObjectId, name: []const u8, out: *std.ArrayListUnmanaged(u8), first: *bool) !void {
    const value = try optionalStringAttr(self, attrs_id, name) orelse return;
    defer self.allocator.free(value);
    try out.append(self.allocator, if (first.*) '?' else '&');
    first.* = false;
    try out.appendSlice(self.allocator, name);
    try out.append(self.allocator, '=');
    try out.appendSlice(self.allocator, value);
}

fn appendStringAttr(self: anytype, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: []const u8, value: []const u8) !void {
    try entries.append(self.allocator, .{
        .name = try self.intern.intern(name),
        .value = Value.string(try self.intern.intern(value)),
    });
}

fn defaultFetchName(self: anytype, url: []const u8) ![]u8 {
    const basename = path_ops.baseName(url);
    if (basename.len != 0) return self.allocator.dupe(u8, basename);
    return self.allocator.dupe(u8, "source");
}

fn dupPathAttr(self: anytype, attrs_id: ObjectId, name: []const u8) ![]u8 {
    const name_id = try self.intern.intern(name);
    const value = try self.forceValue(try self.heap.getAttrValue(attrs_id, name_id));
    return switch (value.discriminant) {
        .path, .string, .string_context => self.allocator.dupe(u8, self.intern.get(try stringTextInternId(self, value))),
        else => error.TypeError,
    };
}

fn optionalStringAttr(self: anytype, attrs_id: ObjectId, name: []const u8) !?[]u8 {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    const forced = try self.forceValue(value);
    if (!isPlainString(forced)) return error.TypeError;
    return try self.allocator.dupe(u8, self.intern.get(try stringTextInternId(self, forced)));
}

fn requiredStringAttr(self: anytype, attrs_id: ObjectId, name: []const u8) ![]u8 {
    return try optionalStringAttr(self, attrs_id, name) orelse error.MissingAttribute;
}

fn optionalBoolAttr(self: anytype, attrs_id: ObjectId, name: []const u8) !?bool {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    const forced = try self.forceValue(value);
    if (forced.discriminant != .bool_true and forced.discriminant != .bool_false) return error.TypeError;
    return forced.discriminant == .bool_true;
}

fn appendPathFingerprint(
    self: anytype,
    path: []const u8,
    fingerprint: *std.ArrayListUnmanaged(u8),
) !void {
    const kind = try self.files.fileType(path);
    try fingerprint.appendSlice(self.allocator, path);
    try fingerprint.append(self.allocator, 0);
    try fingerprint.appendSlice(self.allocator, kind.nixTypeName());
    try fingerprint.append(self.allocator, '\n');

    switch (kind) {
        .regular => {
            const contents = try self.files.readFile(path);
            try fingerprint.appendSlice(self.allocator, contents);
            try fingerprint.append(self.allocator, '\n');
        },
        .directory => {
            const entries = try self.files.readDir(path);
            const sorted = try self.allocator.dupe(file_cache.FileCache.DirEntry, entries);
            defer self.allocator.free(sorted);
            std.mem.sort(file_cache.FileCache.DirEntry, sorted, {}, dirEntryNameLessThan);

            for (sorted) |entry| {
                const child_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                defer self.allocator.free(child_path);
                try appendPathFingerprint(self, child_path, fingerprint);
            }
        },
        .symlink, .unknown => {},
    }
}

fn appendFilteredTreeFingerprint(
    self: anytype,
    pred: Value,
    dir_path: []const u8,
    fingerprint: *std.ArrayListUnmanaged(u8),
) !void {
    const entries = try self.files.readDir(dir_path);
    const sorted = try self.allocator.dupe(file_cache.FileCache.DirEntry, entries);
    defer self.allocator.free(sorted);
    std.mem.sort(file_cache.FileCache.DirEntry, sorted, {}, dirEntryNameLessThan);

    for (sorted) |entry| {
        const child_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
        defer self.allocator.free(child_path);

        if (!try filterSourceAccepts(self, pred, child_path, entry.kind)) continue;
        try fingerprint.appendSlice(self.allocator, child_path);
        try fingerprint.append(self.allocator, 0);
        try fingerprint.appendSlice(self.allocator, entry.kind.nixTypeName());
        try fingerprint.append(self.allocator, '\n');

        if (entry.kind == .directory) {
            try appendFilteredTreeFingerprint(self, pred, child_path, fingerprint);
        }
    }
}

fn filterSourceAccepts(self: anytype, pred: Value, path: []const u8, kind: file_cache.FileCache.FileKind) !bool {
    const path_value = Value.string(try self.intern.intern(path));
    const kind_value = Value.string(try self.intern.intern(kind.nixTypeName()));
    const partial = try self.callValue(pred, path_value);
    const result = try self.forceValue(try self.callValue(partial, kind_value));
    if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
    return result.discriminant == .bool_true;
}

fn dirEntryNameLessThan(_: void, left: file_cache.FileCache.DirEntry, right: file_cache.FileCache.DirEntry) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn storeLikePath(self: anytype, name: []const u8, fingerprint: []const u8) !InternId {
    const digest = try nix_hash.hashBytes(self.allocator, "sha256", fingerprint);
    defer self.allocator.free(digest);

    const clean_name = try self.allocator.alloc(u8, name.len);
    defer self.allocator.free(clean_name);
    for (name, clean_name) |c, *out| {
        out.* = if (c == '/' or c == 0 or std.ascii.isWhitespace(c)) '-' else c;
    }

    const hash_len = @min(@as(usize, 32), digest.len);
    const path = try std.fmt.allocPrint(self.allocator, "/nix/store/{s}-{s}", .{ digest[0..hash_len], clean_name });
    defer self.allocator.free(path);
    return self.intern.intern(path);
}

fn builtinPlaceholder(self: anytype, arg: Value) !Value {
    const output = try stringArg(self, arg);
    const text = try std.fmt.allocPrint(self.allocator, "/nix/store/placeholder-{s}", .{output});
    defer self.allocator.free(text);
    return Value.string(try self.intern.intern(text));
}

fn tryEvalResult(self: anytype, success: bool, value: Value) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("success"),
            .value = Value.boolVal(success),
        },
        .{
            .name = try self.intern.intern("value"),
            .value = value,
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

const DerivationMode = enum { lazy, strict };

fn builtinDerivation(self: anytype, arg: Value, mode: DerivationMode) !Value {
    const attrs = try self.forceValue(arg);
    if (attrs.discriminant != .attrs) return error.TypeError;

    if (mode == .lazy) return buildLazyDerivationValue(self, attrs.asObjectId());
    return buildForcedDerivationValue(self, attrs.asObjectId(), .strict);
}

fn builtinDerivationLazyAttr(self: anytype, attrs_arg: Value, name_arg: Value) !Value {
    const attrs = try self.forceValue(attrs_arg);
    const name = try self.forceValue(name_arg);
    if (attrs.discriminant != .attrs or !isPlainString(name)) return error.TypeError;

    const name_id = try stringTextInternId(self, name);
    const value = try buildForcedDerivationValue(self, attrs.asObjectId(), .lazy);
    return self.heap.getAttrValue(value.asObjectId(), name_id);
}

fn buildLazyDerivationValue(self: anytype, attrs_id: ObjectId) !Value {
    const output_names = try derivationOutputNames(self, attrs_id);
    defer self.allocator.free(output_names.names);

    const outputs = try self.allocator.alloc(derivation.Output, output_names.names.len);
    defer self.allocator.free(outputs);
    for (output_names.names, outputs) |output_name, *output| {
        output.* = .{ .name = output_name, .out_path = output_name };
    }

    const original_attrs = try self.heap.getAttrs(attrs_id);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    for (original_attrs) |entry| {
        if (derivation.isSyntheticName(self.intern, self.intern.get(entry.name), outputs)) continue;
        try entries.append(self.allocator, entry);
    }

    try entries.append(self.allocator, .{
        .name = try self.intern.intern("type"),
        .value = Value.string(try self.intern.intern("derivation")),
    });
    try entries.append(self.allocator, .{
        .name = try self.intern.intern("outputName"),
        .value = Value.string(output_names.names[0]),
    });
    if (output_names.explicit) {
        try entries.append(self.allocator, .{
            .name = try self.intern.intern("outputs"),
            .value = Value.list(try lazyOutputNamesList(self, output_names.names)),
        });
    }
    try entries.append(self.allocator, .{
        .name = try self.intern.intern("drvAttrs"),
        .value = Value.attrs(try self.heap.addAttrs(original_attrs)),
    });

    try appendLazyDerivationAttr(self, &entries, attrs_id, "drvPath");
    try appendLazyDerivationAttr(self, &entries, attrs_id, "outPath");
    for (output_names.names) |output_name| {
        try appendLazyDerivationAttrId(self, &entries, attrs_id, output_name);
    }
    try appendLazyDerivationAttr(self, &entries, attrs_id, "all");

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn lazyOutputNamesList(self: anytype, names: []const InternId) !ObjectId {
    const values = try self.allocator.alloc(Value, names.len);
    defer self.allocator.free(values);
    for (names, values) |name, *value| value.* = Value.string(name);
    return self.heap.addList(values);
}

fn appendLazyDerivationAttr(
    self: anytype,
    entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry),
    attrs_id: ObjectId,
    name: []const u8,
) !void {
    try appendLazyDerivationAttrId(self, entries, attrs_id, try self.intern.intern(name));
}

fn appendLazyDerivationAttrId(
    self: anytype,
    entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry),
    attrs_id: ObjectId,
    name: InternId,
) !void {
    const args = [_]Value{ Value.attrs(attrs_id), Value.string(name) };
    try entries.append(self.allocator, .{
        .name = name,
        .value = try makeBuiltinThunk(self, .derivationLazyAttr, &args),
    });
}

const FingerprintSeenKind = enum { list, attrs, context_string };

const FingerprintSeen = struct {
    kind: FingerprintSeenKind,
    id: ObjectId,
};

fn appendDerivationFingerprint(
    self: anytype,
    attrs_id: ObjectId,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    var seen: std.ArrayListUnmanaged(FingerprintSeen) = .empty;
    defer seen.deinit(self.allocator);

    const sorted = try sortedAttrEntries(self, Value.attrs(attrs_id));
    defer self.allocator.free(sorted);

    try out.appendSlice(self.allocator, "derivation{");
    for (sorted) |entry| {
        const attr_name = self.intern.get(entry.name);
        try appendFingerprintString(self, "name", attr_name, out);
        if (strictDerivationFingerprintAttr(attr_name)) {
            appendFingerprintValue(self, entry.value, out, &seen) catch |err| switch (err) {
                error.MissingAttribute => try out.appendSlice(self.allocator, "missing;"),
                else => return err,
            };
        } else {
            try out.appendSlice(self.allocator, "opaque;");
        }
    }
    try out.appendSlice(self.allocator, "};");
}

fn appendFingerprintValue(
    self: anytype,
    value: Value,
    out: *std.ArrayListUnmanaged(u8),
    seen: *std.ArrayListUnmanaged(FingerprintSeen),
) anyerror!void {
    const forced = try self.forceValue(value);
    switch (forced.discriminant) {
        .null => try out.appendSlice(self.allocator, "null;"),
        .bool_false => try out.appendSlice(self.allocator, "bool:false;"),
        .bool_true => try out.appendSlice(self.allocator, "bool:true;"),
        .int => try appendFingerprintFmt(self, out, "int:{};", .{forced.asInt()}),
        .float => try appendFingerprintFmt(self, out, "float:{d};", .{forced.asFloat()}),
        .string => try appendFingerprintString(self, "string", self.intern.get(forced.asInternId()), out),
        .path => try appendFingerprintString(self, "path", self.intern.get(forced.asInternId()), out),
        .string_context => try appendFingerprintContextString(self, forced.asObjectId(), out, seen),
        .list => try appendFingerprintList(self, forced.asObjectId(), out, seen),
        .attrs => {
            if (try fingerprintAttrsOutPathValue(self, forced)) |string_value| {
                try appendFingerprintValue(self, string_value, out, seen);
            } else {
                try out.appendSlice(self.allocator, "attrs;");
            }
        },
        .closure, .builtin, .builtin_closure => try out.appendSlice(self.allocator, "function;"),
        .thunk, .cell => unreachable,
    }
}

fn fingerprintAttrsOutPathValue(self: anytype, attrs: Value) !?Value {
    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    return try coerceToStringValue(self, out_path);
}

fn appendFingerprintString(
    self: anytype,
    tag: []const u8,
    text: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    try out.appendSlice(self.allocator, tag);
    try out.append(self.allocator, ':');
    try appendFingerprintFmt(self, out, "{}:", .{text.len});
    try out.appendSlice(self.allocator, text);
    try out.append(self.allocator, ';');
}

fn appendFingerprintFmt(
    self: anytype,
    out: *std.ArrayListUnmanaged(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(text);
    try out.appendSlice(self.allocator, text);
}

fn appendFingerprintContextString(
    self: anytype,
    id: ObjectId,
    out: *std.ArrayListUnmanaged(u8),
    seen: *std.ArrayListUnmanaged(FingerprintSeen),
) !void {
    if (!try enterFingerprintObject(self, seen, .context_string, id)) return error.RecursiveThunk;
    defer _ = seen.pop();

    const string = try self.heap.getContextString(id);
    try appendFingerprintString(self, "context-string", self.intern.get(string.text), out);
    try appendFingerprintEntries(self, string.context, out, seen);
}

fn appendFingerprintList(
    self: anytype,
    id: ObjectId,
    out: *std.ArrayListUnmanaged(u8),
    seen: *std.ArrayListUnmanaged(FingerprintSeen),
) !void {
    if (!try enterFingerprintObject(self, seen, .list, id)) return error.RecursiveThunk;
    defer _ = seen.pop();

    try out.appendSlice(self.allocator, "list[");
    for (try self.heap.getList(id)) |item| try appendFingerprintValue(self, item, out, seen);
    try out.appendSlice(self.allocator, "];");
}

fn appendFingerprintAttrs(
    self: anytype,
    id: ObjectId,
    out: *std.ArrayListUnmanaged(u8),
    seen: *std.ArrayListUnmanaged(FingerprintSeen),
) !void {
    if (!try enterFingerprintObject(self, seen, .attrs, id)) return error.RecursiveThunk;
    defer _ = seen.pop();

    const sorted = try sortedAttrEntries(self, Value.attrs(id));
    defer self.allocator.free(sorted);
    try appendFingerprintEntries(self, sorted, out, seen);
}

fn appendFingerprintEntries(
    self: anytype,
    entries: []const heap_mod.AttrEntry,
    out: *std.ArrayListUnmanaged(u8),
    seen: *std.ArrayListUnmanaged(FingerprintSeen),
) !void {
    try out.appendSlice(self.allocator, "attrs{");
    for (entries) |entry| {
        const attr_name = self.intern.get(entry.name);
        try appendFingerprintString(self, "name", attr_name, out);
        appendFingerprintValue(self, entry.value, out, seen) catch |err| switch (err) {
            error.MissingAttribute => try out.appendSlice(self.allocator, "missing;"),
            error.TypeError => if (strictDerivationFingerprintAttr(attr_name))
                return err
            else
                try out.appendSlice(self.allocator, "opaque;"),
            else => return err,
        };
    }
    try out.appendSlice(self.allocator, "};");
}

fn strictDerivationFingerprintAttr(name: []const u8) bool {
    const strict = [_][]const u8{
        "args",
        "builder",
        "name",
        "outputHash",
        "outputHashAlgo",
        "outputHashMode",
        "outputs",
        "system",
    };
    for (strict) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn enterFingerprintObject(
    self: anytype,
    seen: *std.ArrayListUnmanaged(FingerprintSeen),
    kind: FingerprintSeenKind,
    id: ObjectId,
) !bool {
    for (seen.items) |item| {
        if (item.kind == kind and item.id == id) return false;
    }
    try seen.append(self.allocator, .{ .kind = kind, .id = id });
    return true;
}

fn buildForcedDerivationValue(self: anytype, attrs_id: ObjectId, mode: DerivationMode) !Value {
    const name_id = try self.intern.intern("name");
    const name_value = try self.forceValue(try self.heap.getAttrValue(attrs_id, name_id));
    if (!isPlainString(name_value)) return error.TypeError;
    const drv_name_id = try stringTextInternId(self, name_value);

    var fingerprint: std.ArrayListUnmanaged(u8) = .empty;
    defer fingerprint.deinit(self.allocator);
    try appendDerivationFingerprint(self, attrs_id, &fingerprint);

    const output_names = try derivationOutputNames(self, attrs_id);
    defer self.allocator.free(output_names.names);

    const outputs = try self.allocator.alloc(derivation.Output, output_names.names.len);
    defer self.allocator.free(outputs);
    for (output_names.names, outputs) |output_name, *output| {
        output.* = .{
            .name = output_name,
            .out_path = try derivation.storePath(self.allocator, self.intern, self.intern.get(drv_name_id), self.intern.get(output_name), fingerprint.items),
        };
    }

    const spec: derivation.Spec = .{
        .drv_path = try derivation.drvPath(self.allocator, self.intern, self.intern.get(drv_name_id), fingerprint.items),
        .default_output = output_names.names[0],
        .outputs = outputs,
        .explicit_outputs = output_names.explicit,
        .original_attrs = try self.heap.getAttrs(attrs_id),
    };
    return switch (mode) {
        .lazy => derivation.buildValue(self.allocator, self.intern, self.heap, spec),
        .strict => derivation.buildStrictValue(self.allocator, self.intern, self.heap, spec),
    };
}

const DerivationOutputNames = struct {
    names: []InternId,
    explicit: bool,
};

fn derivationOutputNames(self: anytype, attrs_id: ObjectId) !DerivationOutputNames {
    const outputs_id = try self.intern.intern("outputs");
    const outputs_value = self.heap.getAttrValue(attrs_id, outputs_id) catch |err| switch (err) {
        error.MissingAttribute => {
            const names = try self.allocator.alloc(InternId, 1);
            names[0] = try self.intern.intern("out");
            return .{ .names = names, .explicit = false };
        },
        else => return err,
    };

    const outputs_list = try self.forceValue(outputs_value);
    if (outputs_list.discriminant != .list) return error.TypeError;
    const items = try self.heap.getList(outputs_list.asObjectId());
    if (items.len == 0) return error.InvalidDerivationOutput;

    const names = try self.allocator.alloc(InternId, items.len);
    errdefer self.allocator.free(names);
    for (items, names) |item, *name| {
        const value = try self.forceValue(item);
        if (!isPlainString(value)) return error.TypeError;
        name.* = try stringTextInternId(self, value);
        if (self.intern.get(name.*).len == 0) return error.InvalidDerivationOutput;
    }
    return .{ .names = names, .explicit = true };
}

fn builtinStorePath(self: anytype, arg: Value) !Value {
    const path = try pathArg(self, arg);
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn builtinPath(self: anytype, arg: Value) !Value {
    const attrs = try self.forceValue(arg);
    if (attrs.discriminant != .attrs) return error.TypeError;

    const path_id = try self.intern.intern("path");
    const path_value = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), path_id));
    const path = switch (path_value.discriminant) {
        .path, .string, .string_context => self.intern.get(try stringTextInternId(self, path_value)),
        else => return error.TypeError,
    };
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;

    const name_id = try self.intern.intern("name");
    const name_value = self.heap.getAttrValue(attrs.asObjectId(), name_id) catch |err| switch (err) {
        error.MissingAttribute => Value.null_val,
        else => return err,
    };
    var store_name = path_ops.baseName(path);
    if (name_value.discriminant != .null) {
        const name = try self.forceValue(name_value);
        if (!isPlainString(name)) return error.TypeError;
        store_name = self.intern.get(try stringTextInternId(self, name));
    }

    var fingerprint: std.ArrayListUnmanaged(u8) = .empty;
    defer fingerprint.deinit(self.allocator);
    try fingerprint.appendSlice(self.allocator, "path\n");
    try appendPathFingerprint(self, path, &fingerprint);

    return contextStringWithPath(self, try storeLikePath(self, store_name, fingerprint.items));
}

fn builtinSort(self: anytype, cmp_arg: Value, list_arg: Value) !Value {
    const cmp = try self.forceValue(cmp_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const sorted = try self.allocator.dupe(Value, items);
    defer self.allocator.free(sorted);

    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        var j = i;
        while (j > 0 and try callComparator(self, cmp, sorted[j], sorted[j - 1])) : (j -= 1) {
            std.mem.swap(Value, &sorted[j], &sorted[j - 1]);
        }
    }

    return Value.list(try self.heap.addList(sorted));
}

fn builtinPartition(self: anytype, pred_arg: Value, list_arg: Value) !Value {
    const pred = try self.forceValue(pred_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    var right: std.ArrayListUnmanaged(Value) = .empty;
    defer right.deinit(self.allocator);
    var wrong: std.ArrayListUnmanaged(Value) = .empty;
    defer wrong.deinit(self.allocator);

    for (try self.heap.getList(list.asObjectId())) |item| {
        const result = try self.forceValue(try self.callValue(pred, item));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        if (result.discriminant == .bool_true) {
            try right.append(self.allocator, item);
        } else {
            try wrong.append(self.allocator, item);
        }
    }

    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("right"), .value = Value.list(try self.heap.addList(right.items)) },
        .{ .name = try self.intern.intern("wrong"), .value = Value.list(try self.heap.addList(wrong.items)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn builtinGroupBy(self: anytype, fn_arg: Value, list_arg: Value) !Value {
    const func = try self.forceValue(fn_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    const Group = struct {
        name: InternId,
        items: std.ArrayListUnmanaged(Value) = .empty,
    };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer {
        for (groups.items) |*group| group.items.deinit(self.allocator);
        groups.deinit(self.allocator);
    }

    for (try self.heap.getList(list.asObjectId())) |item| {
        const key = try self.forceValue(try self.callValue(func, item));
        if (!isPlainString(key)) return error.TypeError;
        const key_id = try stringTextInternId(self, key);
        const index = groupIndex(groups.items, key_id) orelse blk: {
            try groups.append(self.allocator, .{ .name = key_id });
            break :blk groups.items.len - 1;
        };
        try groups.items[index].items.append(self.allocator, item);
    }

    const entries = try self.allocator.alloc(heap_mod.AttrEntry, groups.items.len);
    defer self.allocator.free(entries);
    for (groups.items, entries) |group, *entry| {
        entry.* = .{
            .name = group.name,
            .value = Value.list(try self.heap.addList(group.items.items)),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

fn builtinGenericClosure(self: anytype, arg: Value) !Value {
    const attrs = try self.forceValue(arg);
    if (attrs.discriminant != .attrs) return error.TypeError;

    const start_set = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("startSet")));
    const operator = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("operator")));
    if (start_set.discriminant != .list) return error.TypeError;

    var result: std.ArrayListUnmanaged(Value) = .empty;
    defer result.deinit(self.allocator);
    var keys: std.ArrayListUnmanaged(Value) = .empty;
    defer keys.deinit(self.allocator);

    for (try self.heap.getList(start_set.asObjectId())) |item| {
        try genericClosureAppend(self, item, &result, &keys);
    }

    var index: usize = 0;
    while (index < result.items.len) : (index += 1) {
        const produced = try self.forceValue(try self.callValue(operator, result.items[index]));
        if (produced.discriminant != .list) return error.TypeError;
        for (try self.heap.getList(produced.asObjectId())) |item| {
            try genericClosureAppend(self, item, &result, &keys);
        }
    }

    return Value.list(try self.heap.addList(result.items));
}

fn builtinFunctionArgs(self: anytype, arg: Value) !Value {
    const func = try self.forceValue(arg);
    if (func.discriminant == .builtin or func.discriminant == .builtin_closure) {
        return Value.attrs(try self.heap.addAttrs(&.{}));
    }
    if (func.discriminant != .closure) return error.TypeError;

    const closure = try self.heap.getClosure(func.asObjectId());
    const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
    return Value.attrs(try self.heap.addAttrs(ch.function_args));
}

fn builtinUnsafeGetAttrPos(self: anytype, name_arg: Value, attrs_arg: Value) !Value {
    const name = try self.forceValue(name_arg);
    const attrs = try self.forceValue(attrs_arg);
    if (!isPlainString(name) or attrs.discriminant != .attrs) return error.TypeError;
    const object_id = attrs.asObjectId();
    const name_id = try stringTextInternId(self, name);
    _ = self.heap.getAttrValue(object_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return Value.null_val,
        else => return err,
    };

    const pos = self.heap.getAttrPos(object_id, name_id) orelse return Value.null_val;
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("column"),
            .value = try makeBuiltinThunk(self, .constantValue, &.{Value.int(@intCast(pos.column))}),
        },
        .{
            .name = try self.intern.intern("file"),
            .value = Value.string(pos.file),
        },
        .{
            .name = try self.intern.intern("line"),
            .value = try makeBuiltinThunk(self, .constantValue, &.{Value.int(@intCast(pos.line))}),
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn builtinFoldlStrict(self: anytype, op_arg: Value, nul_arg: Value, list_arg: Value) !Value {
    const op = try self.forceValue(op_arg);
    var acc = try self.forceValue(nul_arg);
    const list = try self.forceValue(list_arg);
    if (list.discriminant != .list) return error.TypeError;

    for (try self.heap.getList(list.asObjectId())) |item| {
        const partial = try self.callValue(op, acc);
        acc = try self.forceValue(try self.callValue(partial, item));
    }

    return acc;
}

fn builtinRemoveAttrs(self: anytype, attrs_arg: Value, names_arg: Value) !Value {
    const attrs = try self.forceValue(attrs_arg);
    const names = try self.forceValue(names_arg);
    if (attrs.discriminant != .attrs or names.discriminant != .list) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    const attr_entries = try self.heap.getAttrs(attrs.asObjectId());
    for (attr_entries) |entry| {
        if (!try stringListContainsIntern(self, names.asObjectId(), entry.name)) {
            try entries.append(self.allocator, entry);
        }
    }

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn builtinIntersectAttrs(self: anytype, left_arg: Value, right_arg: Value) !Value {
    const left = try self.forceValue(left_arg);
    const right = try self.forceValue(right_arg);
    if (left.discriminant != .attrs or right.discriminant != .attrs) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    const right_entries = try self.heap.getAttrs(right.asObjectId());
    for (right_entries) |entry| {
        _ = self.heap.getAttrValue(left.asObjectId(), entry.name) catch |err| switch (err) {
            error.MissingAttribute => continue,
            else => return err,
        };
        try entries.append(self.allocator, entry);
    }

    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn stringListContainsIntern(self: anytype, list_id: ObjectId, needle: InternId) !bool {
    const items = try self.heap.getList(list_id);
    for (items) |item| {
        const value = try self.forceValue(item);
        if (!isPlainString(value)) return error.TypeError;
        if (try stringTextInternId(self, value) == needle) return true;
    }
    return false;
}

fn stringArg(self: anytype, arg: Value) ![]const u8 {
    const value = try self.forceValue(arg);
    if (!isStringLike(value) or value.discriminant == .path) return error.TypeError;
    return self.intern.get(try stringTextInternId(self, value));
}

fn isStringLike(value: Value) bool {
    return value.discriminant == .string or value.discriminant == .path or value.discriminant == .string_context;
}

fn isPlainString(value: Value) bool {
    return value.discriminant == .string or value.discriminant == .string_context;
}

fn isCallable(self: anytype, value: Value) !bool {
    return switch (value.discriminant) {
        .closure, .builtin, .builtin_closure => true,
        .attrs => blk: {
            _ = self.heap.getAttrValue(value.asObjectId(), try self.intern.intern("__functor")) catch |err| switch (err) {
                error.MissingAttribute => break :blk false,
                else => return err,
            };
            break :blk true;
        },
        else => false,
    };
}

fn stringTextInternId(self: anytype, value: Value) !InternId {
    return switch (value.discriminant) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

fn contextEntriesForValue(self: anytype, value: Value) ![]const heap_mod.AttrEntry {
    return switch (value.discriminant) {
        .string => &.{},
        .path => try singleContextEntry(self, value.asInternId(), try pathContextValue(self)),
        .string_context => (try self.heap.getContextString(value.asObjectId())).context,
        else => error.TypeError,
    };
}

fn singleContextEntry(self: anytype, name: InternId, value: Value) ![]const heap_mod.AttrEntry {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, 1);
    entries[0] = .{ .name = name, .value = value };
    return entries;
}

fn appendContextEntry(self: anytype, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: InternId, value: Value) !void {
    for (context.items) |*entry| {
        if (entry.name == name) {
            entry.value = try mergeContextValues(self, entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

fn mergeContextValues(self: anytype, left: Value, right: Value) !Value {
    const left_forced = try self.forceValue(left);
    const right_forced = try self.forceValue(right);
    if (left_forced.discriminant == .attrs and right_forced.discriminant == .attrs) {
        return Value.attrs(try self.heap.addMergedAttrs(left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

fn pathContextValue(self: anytype) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn allOutputsContextValue(self: anytype) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("allOutputs"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn contextStringWithPath(self: anytype, text_id: InternId) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = text_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextString(text_id, &entries));
}

fn stringListArg(self: anytype, arg: Value) ![][]const u8 {
    const list = try self.forceValue(arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const strings = try self.allocator.alloc([]const u8, items.len);
    errdefer self.allocator.free(strings);
    for (items, strings) |item, *string| string.* = try stringArg(self, item);
    return strings;
}

fn stringListInternIdsArg(self: anytype, arg: Value) ![]InternId {
    const list = try self.forceValue(arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const ids = try self.allocator.alloc(InternId, items.len);
    errdefer self.allocator.free(ids);
    for (items, ids) |item, *id| {
        const value = try self.forceValue(item);
        if (!isPlainString(value)) return error.TypeError;
        id.* = try stringTextInternId(self, value);
    }
    return ids;
}

fn builtinToString(self: anytype, arg: Value) !Value {
    return coerceToStringValue(self, arg);
}

fn coerceToStringId(self: anytype, arg: Value) !InternId {
    return stringTextInternId(self, try coerceToStringValue(self, arg));
}

fn coerceToStringValue(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    switch (value.discriminant) {
        .string, .string_context => return value,
        .path => return contextStringWithPath(self, value.asInternId()),
        .int => {
            const s = try std.fmt.allocPrint(self.allocator, "{}", .{value.asInt()});
            defer self.allocator.free(s);
            return Value.string(try self.intern.intern(s));
        },
        .float => {
            const s = try std.fmt.allocPrint(self.allocator, "{d}", .{value.asFloat()});
            defer self.allocator.free(s);
            return Value.string(try self.intern.intern(s));
        },
        .bool_false, .null => return Value.string(try self.intern.intern("")),
        .bool_true => return Value.string(try self.intern.intern("1")),
        .list => return coerceListToStringValue(self, value.asObjectId()),
        .attrs => return coerceAttrsToStringValue(self, value),
        else => return error.TypeError,
    }
}

fn coerceListToStringId(self: anytype, list_id: ObjectId) !InternId {
    return stringTextInternId(self, try coerceListToStringValue(self, list_id));
}

fn coerceListToStringValue(self: anytype, list_id: ObjectId) !Value {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    for (try self.heap.getList(list_id), 0..) |item, i| {
        if (i > 0) try out.append(self.allocator, ' ');
        const item_value = try coerceToStringValue(self, item);
        const item_id = try stringTextInternId(self, item_value);
        try out.appendSlice(self.allocator, self.intern.get(item_id));
        for (try contextEntriesForValue(self, item_value)) |entry| {
            try appendContextEntry(self, &context, entry.name, entry.value);
        }
    }

    const text_id = try self.intern.intern(out.items);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

fn coerceAttrsToStringValue(self: anytype, attrs: Value) !Value {
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        const result = try self.callValue(try self.forceValue(to_string), attrs);
        return coerceToStringValue(self, result);
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return error.TypeError,
        else => return err,
    };
    return coerceToStringValue(self, out_path);
}
