const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const source_paths = @import("derivation").source_path;
const string_context = @import("string_context.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

pub fn firstReplacementIdAt(self: anytype, input: []const u8, needles: []const InternId) ?usize {
    for (needles, 0..) |needle_id, i| {
        if (std.mem.startsWith(u8, input, self.intern.get(needle_id))) return i;
    }
    return null;
}

pub fn pathArg(self: anytype, arg: Value) ![]const u8 {
    const value = try vm_strings.stringLikeValue(self, arg);
    return switch (value.kind()) {
        .path, .string => self.intern.get(value.asInternId()),
        .string_context => self.intern.get((try self.heap.getContextString(value.asObjectId())).text),
        else => vm_trace.typeErrorExpected(self, "path or string", value),
    };
}

pub fn builtinStringLength(self: anytype, arg: Value) !Value {
    return Value.int(@intCast(self.intern.get(try coerceStringContextId(self, arg)).len));
}

pub fn builtinConcatStringsSep(self: anytype, sep_arg: Value, list_arg: Value) !Value {
    const sep_value = try vm_force.forceValue(self, sep_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!isPlainString(sep_value) or !list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.fanOutListShallow(self, list_id, items);
    const item_values = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(item_values);
    for (items, item_values) |item, *value| value.* = try coerceStringContextValue(self, item);

    const sep = self.intern.get(try stringTextInternId(self, sep_value));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);

    for (item_values, 0..) |item_value, i| {
        if (i > 0) try out.appendSlice(self.allocator, sep);
        const item_id = try stringTextInternId(self, item_value);
        try out.appendSlice(self.allocator, self.intern.get(item_id));
        for (try string_context.contextEntriesForValue(self, item_value)) |entry| {
            try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
        }
    }

    const text_id = try self.intern.intern(out.items);
    if (ctx.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx.items));
}

pub fn coerceStringContextId(self: anytype, arg: Value) !InternId {
    return stringTextInternId(self, try coerceStringContextValue(self, arg));
}

pub fn coerceStringContextValue(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return switch (value.kind()) {
        .string, .string_context => value,
        .path => sourcePathStringValue(self, value.asInternId()),
        .attrs => coerceAttrsStringContextValue(self, value),
        else => error.TypeError,
    };
}

pub fn coerceAttrsStringContextValue(self: anytype, attrs: Value) !Value {
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        const result = try vm_closures.callValue(self, try vm_force.forceValue(self, to_string), attrs);
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
    if (!std.fs.path.isAbsolute(path)) return string_context.contextStringWithPath(self, path_id);
    if (!try self.files.pathExists(path)) return error.FileNotFound;
    const store_path = try source_paths.storePathForSource(self.allocator, self.files, self.derivations.store_dir, path);
    defer self.allocator.free(store_path);
    return string_context.contextStringWithPath(self, try self.intern.intern(store_path));
}

pub fn builtinSubstring(self: anytype, start_arg: Value, len_arg: Value, string_arg: Value) !Value {
    const start_value = try vm_force.forceValue(self, start_arg);
    const len_value = try vm_force.forceValue(self, len_arg);
    if (!int_mod.isAnyInt(start_value) or !int_mod.isAnyInt(len_value)) return error.TypeError;
    const start_i = int_mod.get(start_value, self.heap);
    const len_i = int_mod.get(len_value, self.heap);
    if (start_i < 0) return error.TypeError;

    const string_value = try coerceStringContextValue(self, string_arg);
    const string = self.intern.get(try stringTextInternId(self, string_value));
    if (start_i > std.math.maxInt(usize)) return Value.string(try self.intern.intern(""));
    const start: usize = @intCast(start_i);
    if (start >= string.len) return Value.string(try self.intern.intern(""));
    const available = string.len - start;
    const requested_len: usize = if (len_i < 0)
        available
    else if (len_i > std.math.maxInt(usize))
        available
    else
        @intCast(len_i);
    const end = start + @min(available, requested_len);
    const text_id = try self.intern.intern(string[start..end]);
    const ctx = try string_context.contextEntriesForValue(self, string_value);
    if (ctx.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx));
}

pub fn builtinReplaceStrings(self: anytype, from_arg: Value, to_arg: Value, string_arg: Value) !Value {
    const from_ids = try stringListInternIdsArg(self, from_arg);
    defer self.allocator.free(from_ids);
    const to_values = try stringListValuesArg(self, to_arg);
    defer self.allocator.free(to_values);
    const input_value = try vm_force.forceValue(self, string_arg);
    if (from_ids.len != to_values.len or !isPlainString(input_value)) return error.TypeError;

    const input = self.intern.get(try stringTextInternId(self, input_value));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);

    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);
    for (try string_context.contextEntriesForValue(self, input_value)) |entry| {
        try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
    }

    var index: usize = 0;
    while (index < input.len) {
        if (firstReplacementIdAt(self, input[index..], from_ids)) |replacement_index| {
            const needle = self.intern.get(from_ids[replacement_index]);
            if (needle.len == 0) return error.TypeError;
            const replacement = to_values[replacement_index];
            try out.appendSlice(self.allocator, self.intern.get(try stringTextInternId(self, replacement)));
            for (try string_context.contextEntriesForValue(self, replacement)) |entry| {
                try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
            }
            index += needle.len;
        } else {
            try out.append(self.allocator, input[index]);
            index += 1;
        }
    }

    const text_id = try self.intern.intern(out.items);
    if (ctx.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx.items));
}

pub fn stringArg(self: anytype, arg: Value) ![]const u8 {
    const value = try vm_force.forceValue(self, arg);
    if (!isStringLike(value) or value.isPath()) return error.TypeError;
    return self.intern.get(try stringTextInternId(self, value));
}

pub fn isStringLike(value: Value) bool {
    return value.isString() or value.isPath() or value.isContextString();
}

pub fn isPlainString(value: Value) bool {
    return value.isString() or value.isContextString();
}

pub fn isCallable(self: anytype, value: Value) !bool {
    return switch (value.kind()) {
        .closure, .builtin, .builtin_closure, .partial_app => true,
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
    return switch (value.kind()) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

pub fn stringListArg(self: anytype, arg: Value) ![][]const u8 {
    const list = try vm_force.forceValue(self, arg);
    if (!list.isList()) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const out = try self.allocator.alloc([]const u8, items.len);
    errdefer self.allocator.free(out);
    for (items, out) |item, *string| string.* = try stringArg(self, item);
    return out;
}

pub fn stringListInternIdsArg(self: anytype, arg: Value) ![]InternId {
    const list = try vm_force.forceValue(self, arg);
    if (!list.isList()) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const ids = try self.allocator.alloc(InternId, items.len);
    errdefer self.allocator.free(ids);
    for (items, ids) |item, *id| {
        const value = try vm_force.forceValue(self, item);
        if (!isPlainString(value)) return error.TypeError;
        id.* = try stringTextInternId(self, value);
    }
    return ids;
}

pub fn stringListValuesArg(self: anytype, arg: Value) ![]Value {
    const list = try vm_force.forceValue(self, arg);
    if (!list.isList()) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const values = try self.allocator.alloc(Value, items.len);
    errdefer self.allocator.free(values);
    for (items, values) |item, *dest| {
        const value = try vm_force.forceValue(self, item);
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
    const value = try vm_force.forceValue(self, arg);
    switch (value.kind()) {
        .string, .string_context => return value,
        .path => return Value.string(value.asInternId()),
        .int, .boxed_int => {
            const s = try std.fmt.allocPrint(self.allocator, "{}", .{int_mod.get(value, self.heap)});
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
    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);

    var first = true;
    var trailing_empty_list = false;
    for (try self.heap.getList(list_id)) |item| {
        const forced = try vm_force.forceValue(self, item);
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
        for (try string_context.contextEntriesForValue(self, item_value)) |entry| {
            try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
        }
    }
    if (trailing_empty_list) try out.append(self.allocator, ' ');

    const text_id = try self.intern.intern(out.items);
    if (ctx.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx.items));
}

pub fn isEmptyListStringItem(self: anytype, value: Value) !bool {
    return value.isList() and (try self.heap.getList(value.asObjectId())).len == 0;
}

pub fn coerceAttrsToStringValue(self: anytype, attrs: Value) !Value {
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        const result = try vm_closures.callValue(self, try vm_force.forceValue(self, to_string), attrs);
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
    const value = try vm_force.forceValue(self, arg);
    switch (value.kind()) {
        .string, .string_context => return value,
        .path => return sourcePathStringValue(self, value.asInternId()),
        .int, .boxed_int => {
            const s = try std.fmt.allocPrint(self.allocator, "{}", .{int_mod.get(value, self.heap)});
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
    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);

    var first = true;
    var trailing_empty_list = false;
    for (try self.heap.getList(list_id)) |item| {
        const forced = try vm_force.forceValue(self, item);
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
        for (try string_context.contextEntriesForValue(self, item_value)) |entry| {
            try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
        }
    }
    if (trailing_empty_list) try out.append(self.allocator, ' ');

    const text_id = try self.intern.intern(out.items);
    if (ctx.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx.items));
}

pub fn coerceDerivationAttrsToStringValue(self: anytype, attrs: Value) !Value {
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        const result = try vm_closures.callValue(self, try vm_force.forceValue(self, to_string), attrs);
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
