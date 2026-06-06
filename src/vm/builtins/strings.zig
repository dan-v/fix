const std = @import("std");
const types = @import("../../types.zig");
const Value = @import("../../value.zig").Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("../../heap.zig");
const source_paths = @import("../../runtime/source_path.zig");

pub fn firstReplacementIdAt(self: anytype, input: []const u8, needles: []const InternId) ?usize {
    for (needles, 0..) |needle_id, i| {
        if (std.mem.startsWith(u8, input, self.intern.get(needle_id))) return i;
    }
    return null;
}

pub fn pathArg(self: anytype, arg: Value) ![]const u8 {
    const value = try self.stringLikeValue(arg);
    return switch (value.discriminant) {
        .path, .string => self.intern.get(value.asInternId()),
        .string_context => self.intern.get((try self.heap.getContextString(value.asObjectId())).text),
        else => self.typeErrorExpected("path or string", value),
    };
}

pub fn builtinStringLength(self: anytype, arg: Value) !Value {
    return Value.int(@intCast(self.intern.get(try coerceStringContextId(self, arg)).len));
}

pub fn builtinConcatStringsSep(self: anytype, sep_arg: Value, list_arg: Value) !Value {
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

pub fn coerceStringContextId(self: anytype, arg: Value) !InternId {
    return stringTextInternId(self, try coerceStringContextValue(self, arg));
}

pub fn coerceStringContextValue(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return switch (value.discriminant) {
        .string, .string_context => value,
        .path => sourcePathStringValue(self, value.asInternId()),
        .attrs => coerceAttrsStringContextValue(self, value),
        else => error.TypeError,
    };
}

pub fn coerceAttrsStringContextValue(self: anytype, attrs: Value) !Value {
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

pub fn sourcePathStringValue(self: anytype, path_id: InternId) !Value {
    const path = self.intern.get(path_id);
    if (!std.fs.path.isAbsolute(path)) return contextStringWithPath(self, path_id);
    if (!try self.files.pathExists(path)) return error.FileNotFound;
    const store_path = try source_paths.storePathForSource(self.allocator, self.files, self.derivations.store_dir, path);
    defer self.allocator.free(store_path);
    return contextStringWithPath(self, try self.intern.intern(store_path));
}

pub fn builtinSubstring(self: anytype, start_arg: Value, len_arg: Value, string_arg: Value) !Value {
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

pub fn builtinReplaceStrings(self: anytype, from_arg: Value, to_arg: Value, string_arg: Value) !Value {
    const from_ids = try stringListInternIdsArg(self, from_arg);
    defer self.allocator.free(from_ids);
    const to_values = try stringListValuesArg(self, to_arg);
    defer self.allocator.free(to_values);
    const input_value = try self.forceValue(string_arg);
    if (from_ids.len != to_values.len or !isPlainString(input_value)) return error.TypeError;

    const input = self.intern.get(try stringTextInternId(self, input_value));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    for (try contextEntriesForValue(self, input_value)) |entry| {
        try appendContextEntry(self, &context, entry.name, entry.value);
    }

    var index: usize = 0;
    while (index < input.len) {
        if (firstReplacementIdAt(self, input[index..], from_ids)) |replacement_index| {
            const needle = self.intern.get(from_ids[replacement_index]);
            if (needle.len == 0) return error.TypeError;
            const replacement = to_values[replacement_index];
            try out.appendSlice(self.allocator, self.intern.get(try stringTextInternId(self, replacement)));
            for (try contextEntriesForValue(self, replacement)) |entry| {
                try appendContextEntry(self, &context, entry.name, entry.value);
            }
            index += needle.len;
        } else {
            try out.append(self.allocator, input[index]);
            index += 1;
        }
    }

    const text_id = try self.intern.intern(out.items);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn builtinThrow(self: anytype, message_arg: Value) !Value {
    try self.setErrorMessage(try stringArg(self, message_arg));
    return error.NixThrow;
}

pub fn builtinAbort(self: anytype, message_arg: Value) !Value {
    try self.setErrorMessage(try stringArg(self, message_arg));
    return error.NixAbort;
}

pub fn builtinTryEval(self: anytype, arg: Value) !Value {
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

pub fn builtinAddErrorContext(self: anytype, message_arg: Value, value_arg: Value) !Value {
    return self.forceValue(value_arg) catch |err| {
        const message = stringArg(self, message_arg) catch return err;
        self.pushErrorContext(message) catch return err;
        return err;
    };
}

pub fn builtinTrace(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try self.forceValue(message_arg);
    return self.forceValue(value_arg);
}

pub fn builtinTraceVerbose(self: anytype, message_arg: Value, value_arg: Value) !Value {
    _ = try self.forceValue(message_arg);
    return self.forceValue(value_arg);
}

pub fn builtinGetContext(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return Value.attrs(try self.heap.addAttrs(try contextEntriesForValue(self, value)));
}

pub fn builtinHasContext(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    return Value.boolVal((try contextEntriesForValue(self, value)).len != 0);
}

pub fn builtinAppendContext(self: anytype, string_arg: Value, context_arg: Value) !Value {
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

pub fn builtinUnsafeDiscardStringContext(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    if (!isStringLike(value)) return error.TypeError;
    return Value.string(try stringTextInternId(self, value));
}

pub fn builtinUnsafeDiscardOutputDependency(self: anytype, arg: Value) !Value {
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

pub fn builtinAddDrvOutputDependencies(self: anytype, arg: Value) !Value {
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

pub fn tryEvalResult(self: anytype, success: bool, value: Value) !Value {
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

pub fn stringArg(self: anytype, arg: Value) ![]const u8 {
    const value = try self.forceValue(arg);
    if (!isStringLike(value) or value.discriminant == .path) return error.TypeError;
    return self.intern.get(try stringTextInternId(self, value));
}

pub fn isStringLike(value: Value) bool {
    return value.discriminant == .string or value.discriminant == .path or value.discriminant == .string_context;
}

pub fn isPlainString(value: Value) bool {
    return value.discriminant == .string or value.discriminant == .string_context;
}

pub fn isCallable(self: anytype, value: Value) !bool {
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

pub fn stringTextInternId(self: anytype, value: Value) !InternId {
    return switch (value.discriminant) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

pub fn contextEntriesForValue(self: anytype, value: Value) ![]const heap_mod.AttrEntry {
    return switch (value.discriminant) {
        .string => &.{},
        .path => try singleContextEntry(self, value.asInternId(), try pathContextValue(self)),
        .string_context => (try self.heap.getContextString(value.asObjectId())).context,
        else => error.TypeError,
    };
}

pub fn singleContextEntry(self: anytype, name: InternId, value: Value) ![]const heap_mod.AttrEntry {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, 1);
    entries[0] = .{ .name = name, .value = value };
    return entries;
}

pub fn appendContextEntry(self: anytype, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: InternId, value: Value) !void {
    for (context.items) |*entry| {
        if (entry.name == name) {
            entry.value = try mergeContextValues(self, entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

pub fn mergeContextValues(self: anytype, left: Value, right: Value) !Value {
    const left_forced = try self.forceValue(left);
    const right_forced = try self.forceValue(right);
    if (left_forced.discriminant == .attrs and right_forced.discriminant == .attrs) {
        return Value.attrs(try mergeContextAttrs(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

pub fn mergeContextAttrs(self: anytype, left_id: ObjectId, right_id: ObjectId) !ObjectId {
    const left = try self.heap.getAttrs(left_id);
    const right = try self.heap.getAttrs(right_id);

    var merged = try std.ArrayListUnmanaged(heap_mod.AttrEntry).initCapacity(self.allocator, left.len + right.len);
    defer merged.deinit(self.allocator);

    var left_i: usize = 0;
    var right_i: usize = 0;
    while (left_i < left.len and right_i < right.len) {
        const l = left[left_i];
        const r = right[right_i];
        if (l.name < r.name) {
            merged.appendAssumeCapacity(l);
            left_i += 1;
        } else if (l.name > r.name) {
            merged.appendAssumeCapacity(r);
            right_i += 1;
        } else {
            const value = try mergeContextAttrValue(self, l.name, l.value, r.value);
            merged.appendAssumeCapacity(.{ .name = l.name, .value = value });
            left_i += 1;
            right_i += 1;
        }
    }
    while (left_i < left.len) : (left_i += 1) {
        merged.appendAssumeCapacity(left[left_i]);
    }
    while (right_i < right.len) : (right_i += 1) {
        merged.appendAssumeCapacity(right[right_i]);
    }

    return self.heap.addAttrs(merged.items);
}

pub fn mergeContextAttrValue(self: anytype, name: InternId, left: Value, right: Value) !Value {
    if (name == try self.intern.intern("outputs")) return mergeContextOutputs(self, left, right);
    return right;
}

pub fn mergeContextOutputs(self: anytype, left: Value, right: Value) !Value {
    const left_list = try self.forceValue(left);
    const right_list = try self.forceValue(right);
    if (left_list.discriminant != .list or right_list.discriminant != .list) return error.TypeError;

    var outputs: std.ArrayListUnmanaged(Value) = .empty;
    defer outputs.deinit(self.allocator);

    for (try self.heap.getList(left_list.asObjectId())) |item| try appendUniqueContextOutput(self, &outputs, item);
    for (try self.heap.getList(right_list.asObjectId())) |item| try appendUniqueContextOutput(self, &outputs, item);

    return Value.list(try self.heap.addList(outputs.items));
}

pub fn appendUniqueContextOutput(self: anytype, outputs: *std.ArrayListUnmanaged(Value), item: Value) !void {
    const value = try self.forceValue(item);
    if (!isPlainString(value)) return error.TypeError;
    const text = try stringTextInternId(self, value);
    for (outputs.items) |existing| {
        if (try stringTextInternId(self, existing) == text) return;
    }
    try outputs.append(self.allocator, Value.string(text));
}

pub fn pathContextValue(self: anytype) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn allOutputsContextValue(self: anytype) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("allOutputs"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn contextStringWithPath(self: anytype, text_id: InternId) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = text_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextString(text_id, &entries));
}

pub fn stringListArg(self: anytype, arg: Value) ![][]const u8 {
    const list = try self.forceValue(arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const strings = try self.allocator.alloc([]const u8, items.len);
    errdefer self.allocator.free(strings);
    for (items, strings) |item, *string| string.* = try stringArg(self, item);
    return strings;
}

pub fn stringListInternIdsArg(self: anytype, arg: Value) ![]InternId {
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

pub fn stringListValuesArg(self: anytype, arg: Value) ![]Value {
    const list = try self.forceValue(arg);
    if (list.discriminant != .list) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const values = try self.allocator.alloc(Value, items.len);
    errdefer self.allocator.free(values);
    for (items, values) |item, *dest| {
        const value = try self.forceValue(item);
        if (!isPlainString(value)) return error.TypeError;
        dest.* = value;
    }
    return values;
}

pub fn builtinToString(self: anytype, arg: Value) !Value {
    return coerceToStringValue(self, arg);
}

pub fn coerceToStringId(self: anytype, arg: Value) !InternId {
    return stringTextInternId(self, try coerceToStringValue(self, arg));
}

pub fn coerceToStringValue(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    switch (value.discriminant) {
        .string, .string_context => return value,
        .path => return Value.string(value.asInternId()),
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

pub fn coerceListToStringId(self: anytype, list_id: ObjectId) !InternId {
    return stringTextInternId(self, try coerceListToStringValue(self, list_id));
}

pub fn coerceListToStringValue(self: anytype, list_id: ObjectId) !Value {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    var first = true;
    var trailing_empty_list = false;
    for (try self.heap.getList(list_id)) |item| {
        const forced = try self.forceValue(item);
        if (try isEmptyListStringItem(self, forced)) {
            if (!first) trailing_empty_list = true;
            continue;
        }
        if (!first) try out.append(self.allocator, ' ');
        first = false;
        trailing_empty_list = false;
        const item_value = try coerceToStringValue(self, forced);
        const item_id = try stringTextInternId(self, item_value);
        try out.appendSlice(self.allocator, self.intern.get(item_id));
        for (try contextEntriesForValue(self, item_value)) |entry| {
            try appendContextEntry(self, &context, entry.name, entry.value);
        }
    }
    if (trailing_empty_list) try out.append(self.allocator, ' ');

    const text_id = try self.intern.intern(out.items);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn isEmptyListStringItem(self: anytype, value: Value) !bool {
    return value.discriminant == .list and (try self.heap.getList(value.asObjectId())).len == 0;
}

pub fn coerceAttrsToStringValue(self: anytype, attrs: Value) !Value {
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

pub fn coerceDerivationStringValue(self: anytype, arg: Value) !Value {
    const value = try self.forceValue(arg);
    switch (value.discriminant) {
        .string, .string_context => return value,
        .path => return sourcePathStringValue(self, value.asInternId()),
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
        .list => return coerceDerivationListToStringValue(self, value.asObjectId()),
        .attrs => return coerceDerivationAttrsToStringValue(self, value),
        else => return error.TypeError,
    }
}

pub fn coerceDerivationListToStringValue(self: anytype, list_id: ObjectId) !Value {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    var first = true;
    var trailing_empty_list = false;
    for (try self.heap.getList(list_id)) |item| {
        const forced = try self.forceValue(item);
        if (try isEmptyListStringItem(self, forced)) {
            if (!first) trailing_empty_list = true;
            continue;
        }
        if (!first) try out.append(self.allocator, ' ');
        first = false;
        trailing_empty_list = false;
        const item_value = try coerceDerivationStringValue(self, forced);
        const item_id = try stringTextInternId(self, item_value);
        try out.appendSlice(self.allocator, self.intern.get(item_id));
        for (try contextEntriesForValue(self, item_value)) |entry| {
            try appendContextEntry(self, &context, entry.name, entry.value);
        }
    }
    if (trailing_empty_list) try out.append(self.allocator, ' ');

    const text_id = try self.intern.intern(out.items);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn coerceDerivationAttrsToStringValue(self: anytype, attrs: Value) !Value {
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        const result = try self.callValue(try self.forceValue(to_string), attrs);
        return coerceDerivationStringValue(self, result);
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return error.TypeError,
        else => return err,
    };
    return coerceDerivationStringValue(self, out_path);
}
