const std = @import("std");
const types = @import("../../types.zig");
const Value = @import("../../value.zig").Value;
const ObjectId = types.ObjectId;
const heap_mod = @import("../../heap.zig");
const version = @import("../../runtime/version.zig");
const regex = @import("../../runtime/regex.zig");
const toml = @import("../../runtime/toml.zig");
const ThunkState = @import("../../thunk.zig").ThunkState;
const collections = @import("collections.zig");
const strings = @import("strings.zig");

const appendContextEntry = strings.appendContextEntry;
const coerceAttrsToStringValue = strings.coerceAttrsToStringValue;
const coerceStringContextValue = strings.coerceStringContextValue;
const contextEntriesForValue = strings.contextEntriesForValue;
const isPlainString = strings.isPlainString;
const sourcePathStringValue = strings.sourcePathStringValue;
const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;
const sortedAttrEntries = collections.sortedAttrEntries;

pub fn builtinToJSON(self: anytype, arg: Value) !Value {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    try writeJsonValueWithPathMode(self, &out.writer, arg, .source, &context);
    const text = try out.toOwnedSlice();
    defer self.allocator.free(text);
    const text_id = try self.intern.intern(text);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn writeJsonValue(self: anytype, writer: *std.Io.Writer, value: Value) !void {
    try writeJsonValueWithPathMode(self, writer, value, .raw, null);
}

const JsonPathMode = enum { raw, source };

fn writeJsonValueWithPathMode(
    self: anytype,
    writer: *std.Io.Writer,
    value: Value,
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    var seen: std.ArrayListUnmanaged(SeenJsonObject) = .empty;
    defer seen.deinit(self.allocator);

    try writeJsonValueInner(self, writer, value, &seen, path_mode, context);
}

const SeenJsonKind = enum { list, attrs };

const SeenJsonObject = struct {
    kind: SeenJsonKind,
    id: ObjectId,
};

fn writeJsonValueInner(
    self: anytype,
    writer: *std.Io.Writer,
    value: Value,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) anyerror!void {
    const forced = try self.forceValue(value);
    switch (forced.discriminant) {
        .null => try writer.writeAll("null"),
        .bool_false => try writer.writeAll("false"),
        .bool_true => try writer.writeAll("true"),
        .int => try writer.print("{}", .{forced.asInt()}),
        .float => try writer.print("{d}", .{forced.asFloat()}),
        .string, .string_context => try writeJsonStringValue(self, writer, forced, context),
        .path => {
            switch (path_mode) {
                .raw => try std.json.Stringify.encodeJsonString(self.intern.get(forced.asInternId()), .{}, writer),
                .source => {
                    const string_value = try sourcePathStringValue(self, forced.asInternId());
                    try writeJsonStringValue(self, writer, string_value, context);
                },
            }
        },
        .list => try writeJsonList(self, writer, forced.asObjectId(), seen, path_mode, context),
        .attrs => {
            if (try jsonAttrsStringValue(self, forced, path_mode)) |string_value| {
                try writeJsonStringValue(self, writer, string_value, context);
            } else {
                try writeJsonAttrs(self, writer, forced.asObjectId(), seen, path_mode, context);
            }
        },
        .closure, .builtin, .builtin_closure => return error.TypeError,
        .thunk, .cell => unreachable,
    }
}

fn writeJsonStringValue(
    self: anytype,
    writer: *std.Io.Writer,
    value: Value,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    try std.json.Stringify.encodeJsonString(self.intern.get(try stringTextInternId(self, value)), .{}, writer);
    if (context) |entries| {
        for (try contextEntriesForValue(self, value)) |entry| {
            try appendContextEntry(self, entries, entry.name, entry.value);
        }
    }
}

fn jsonAttrsStringValue(self: anytype, attrs: Value, path_mode: JsonPathMode) !?Value {
    const attrs_id = attrs.asObjectId();

    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs_id, to_string_id)) |_| {
        return switch (path_mode) {
            .raw => try coerceAttrsToStringValue(self, attrs),
            .source => try coerceStringContextValue(self, attrs),
        };
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    if (self.heap.getAttrValue(attrs_id, out_path_id)) |_| {
        return switch (path_mode) {
            .raw => try coerceAttrsToStringValue(self, attrs),
            .source => try coerceStringContextValue(self, attrs),
        };
    } else |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    }
}

pub fn jsonAttrsSourceStringValue(self: anytype, attrs: Value) !?Value {
    return jsonAttrsStringValue(self, attrs, .source);
}

fn writeJsonList(
    self: anytype,
    writer: *std.Io.Writer,
    id: ObjectId,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    if (!try enterJsonObject(self, .list, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    try writer.writeByte('[');
    for (try self.heap.getList(id), 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonValueInner(self, writer, item, seen, path_mode, context);
    }
    try writer.writeByte(']');
}

fn writeJsonAttrs(
    self: anytype,
    writer: *std.Io.Writer,
    id: ObjectId,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    if (!try enterJsonObject(self, .attrs, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    const sorted = try sortedAttrEntries(self, Value.attrs(id));
    defer self.allocator.free(sorted);

    try writer.writeByte('{');
    for (sorted, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(self.intern.get(entry.name), .{}, writer);
        try writer.writeByte(':');
        try writeJsonValueInner(self, writer, entry.value, seen, path_mode, context);
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

pub fn builtinToXML(self: anytype, arg: Value) !Value {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    try self.forceDeep(arg);
    try writeXmlDocument(self, &out.writer, try self.forceValue(arg), &context);

    const text = try out.toOwnedSlice();
    defer self.allocator.free(text);
    const text_id = try self.intern.intern(text);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn writeLazyXmlValue(self: anytype, writer: *std.Io.Writer, value: Value) !void {
    try writeXmlDocument(self, writer, try self.forceValue(value), null);
}

fn writeXmlDocument(
    self: anytype,
    writer: *std.Io.Writer,
    value: Value,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    try writer.writeAll("<?xml version='1.0' encoding='utf-8'?>\n<expr>\n");
    try writeXmlValue(self, writer, value, 1, context);
    try writer.writeAll("</expr>\n");
}

fn writeXmlValue(
    self: anytype,
    writer: *std.Io.Writer,
    value: Value,
    depth: usize,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
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
            if (context) |entries| {
                for (try contextEntriesForValue(self, forced)) |entry| {
                    try appendContextEntry(self, entries, entry.name, entry.value);
                }
            }
        },
        .path => {
            try writer.writeAll("<path value=\"");
            try writeXmlEscaped(writer, self.intern.get(forced.asInternId()));
            try writer.writeAll("\" />\n");
        },
        .list => try writeXmlList(self, writer, forced.asObjectId(), depth, context),
        .attrs => try writeXmlAttrs(self, writer, forced.asObjectId(), depth, context),
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
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    try writer.writeAll("<list>\n");
    for (try self.heap.getList(id)) |item| try writeXmlValue(self, writer, item, depth + 1, context);
    try writeXmlIndent(writer, depth);
    try writer.writeAll("</list>\n");
}

fn writeXmlAttrs(
    self: anytype,
    writer: *std.Io.Writer,
    id: ObjectId,
    depth: usize,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    const sorted = try sortedAttrEntries(self, Value.attrs(id));
    defer self.allocator.free(sorted);

    try writer.writeAll("<attrs>\n");
    for (sorted) |entry| {
        try writeXmlIndent(writer, depth + 1);
        try writer.writeAll("<attr name=\"");
        try writeXmlEscaped(writer, self.intern.get(entry.name));
        try writer.writeAll("\">\n");
        try writeXmlValue(self, writer, entry.value, depth + 2, context);
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

pub fn builtinFromJSON(self: anytype, arg: Value) !Value {
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

pub fn builtinFromTOML(self: anytype, arg: Value) !Value {
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

pub fn builtinCompareVersions(self: anytype, left_arg: Value, right_arg: Value) !Value {
    const left_value = try self.forceValue(left_arg);
    const right_value = try self.forceValue(right_arg);
    if (!isPlainString(left_value) or !isPlainString(right_value)) return error.TypeError;
    const left = self.intern.get(try stringTextInternId(self, left_value));
    const right = self.intern.get(try stringTextInternId(self, right_value));
    return Value.int(try version.compareVersions(self.allocator, left, right));
}

pub fn builtinSplitVersion(self: anytype, arg: Value) !Value {
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

pub fn builtinMatch(self: anytype, regex_arg: Value, text_arg: Value) !Value {
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

pub fn builtinSplit(self: anytype, regex_arg: Value, text_arg: Value) !Value {
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

pub fn builtinParseDrvName(self: anytype, arg: Value) !Value {
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
