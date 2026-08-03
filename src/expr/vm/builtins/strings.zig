//! Nix string builtins: stringLength, substring, concatStringsSep,
//! replaceStrings, and toString, plus the string-coercion and string-argument
//! helpers (stringArg/pathArg/isPlainString/coerce*) shared across builtin
//! families.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const source_paths = @import("store").realization.source_path;
const string_context = @import("string_context.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");
const prof = @import("../../probe.zig").prof;
const prof_census = @import("../../probe.zig").prof_census;

pub fn firstReplacementIdAt(self: *VM, input: []const u8, needles: []const InternId) ?usize {
    for (needles, 0..) |needle_id, i| {
        if (std.mem.startsWith(u8, input, self.intern.get(needle_id))) return i;
    }
    return null;
}

pub fn pathArg(self: *VM, arg: Value) ![]const u8 {
    const value = try vm_strings.stringLikeValue(self, arg);
    return switch (value.kind()) {
        .path, .string => self.intern.get(value.asInternId()),
        .string_context => self.intern.get((try self.heap.getContextString(value.asObjectId())).text),
        else => vm_trace.typeErrorExpected(self, "path or string", value),
    };
}

pub fn builtinStringLength(self: *VM, arg: Value) !Value {
    return Value.int(@intCast(self.intern.get(try coerceStringContextId(self, arg)).len));
}

pub fn builtinConcatStringsSep(self: *VM, sep_arg: Value, list_arg: Value) !Value {
    const sep_value = try vm_force.forceValue(self, sep_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!isPlainString(sep_value) or !list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    const item_values = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(item_values);
    const item_text_ids = try self.allocator.alloc(InternId, items.len);
    defer self.allocator.free(item_text_ids);
    // GC: each coerced path/attr can be a fresh context string held only in
    // item_values. Root it immediately, before coercing the next item (which
    // may force user code and collect), and retain all items through context
    // merging below.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, sep_value);
    const sep = self.intern.get(try stringTextInternId(self, sep_value));
    var item_bytes: usize = 0;
    for (item_values, item_text_ids, 0..) |*value, *text_id, i| {
        value.* = try coerceStringContextValue(self, try self.heap.getListItem(list_id, i));
        vm_force.rootKeep(self, value.*);
        text_id.* = try stringTextInternId(self, value.*);
        item_bytes = try std.math.add(usize, item_bytes, self.intern.get(text_id.*).len);
    }

    const separator_bytes: usize = if (item_values.len > 1)
        try std.math.mul(usize, sep.len, item_values.len - 1)
    else
        0;
    const total = try std.math.add(usize, item_bytes, separator_bytes);
    const out = try self.allocator.alloc(u8, total);
    defer self.allocator.free(out);

    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);

    // Nix folds the separator's context into the result unconditionally, even
    // when the list has fewer than two elements.
    for (try string_context.contextEntriesForValue(self, sep_value)) |entry| {
        try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
    }

    var out_at: usize = 0;
    for (item_values, item_text_ids, 0..) |item_value, text_id, i| {
        if (i > 0) {
            @memcpy(out[out_at..][0..sep.len], sep);
            out_at += sep.len;
        }
        const text = self.intern.get(text_id);
        @memcpy(out[out_at..][0..text.len], text);
        out_at += text.len;
        for (try string_context.contextEntriesForValue(self, item_value)) |entry| {
            try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
        }
    }
    std.debug.assert(out_at == out.len);

    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(out.len, ctx.items.len != 0);
    const text_id = try self.intern.intern(out);
    if (ctx.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx.items));
}

pub fn coerceStringContextId(self: *VM, arg: Value) !InternId {
    return stringTextInternId(self, try coerceStringContextValue(self, arg));
}

pub fn coerceStringContextValue(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return switch (value.kind()) {
        .string, .string_context => value,
        .path => sourcePathStringValue(self, value.asInternId()),
        .attrs => coerceAttrsStringContextValue(self, value),
        else => error.TypeError,
    };
}

pub fn coerceAttrsStringContextValue(self: *VM, attrs: Value) !Value {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, attrs); // held across getAttrValue + callValue + coerce
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

pub fn sourcePathStringValue(self: *VM, path_id: InternId) !Value {
    const path = self.intern.get(path_id);
    if (!std.fs.path.isAbsolute(path)) return string_context.contextStringWithPath(self, path_id);
    if (!try self.files.pathExists(path)) return error.FileNotFound;
    const store_path = try source_paths.storePathForSource(self.allocator, self.realization, self.files, path);
    defer self.allocator.free(store_path);
    return string_context.contextStringWithPath(self, try self.intern.intern(store_path));
}

pub fn builtinSubstring(self: *VM, start_arg: Value, len_arg: Value, string_arg: Value) !Value {
    const start_value = try vm_force.forceValue(self, start_arg);
    const len_value = try vm_force.forceValue(self, len_arg);
    if (!int_mod.isAnyInt(start_value) or !int_mod.isAnyInt(len_value)) return error.TypeError;
    const start_i = int_mod.get(start_value, self.heap);
    const len_i = int_mod.get(len_value, self.heap);
    if (start_i < 0) return error.TypeError;

    const string_value = try coerceStringContextValue(self, string_arg);
    const string = self.intern.get(try stringTextInternId(self, string_value));
    // Nix always attaches the source string's context to the result — even for
    // an out-of-range slice that yields "".
    if (start_i > std.math.maxInt(usize)) return substringResult(self, "", string_value);
    const start: usize = @intCast(start_i);
    if (start >= string.len) return substringResult(self, "", string_value);
    const available = string.len - start;
    const requested_len: usize = if (len_i < 0)
        available
    else if (len_i > std.math.maxInt(usize))
        available
    else
        @intCast(len_i);
    const end = start + @min(available, requested_len);
    return substringResult(self, string[start..end], string_value);
}

fn substringResult(self: *VM, text: []const u8, source: Value) !Value {
    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(text.len, source.isContextString());
    const text_id = try self.intern.intern(text);
    const ctx = try string_context.contextEntriesForValue(self, source);
    if (ctx.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx));
}

pub fn builtinReplaceStrings(self: *VM, from_arg: Value, to_arg: Value, string_arg: Value) !Value {
    const from_ids = try stringListInternIdsArg(self, from_arg);
    defer self.allocator.free(from_ids);
    // `to` stays lazy: Nix forces `to[i]` only when `from[i]` actually matches,
    // so an unused replacement may be `throw`.
    const to_list = try vm_force.forceValue(self, to_arg);
    if (!to_list.isList()) return error.TypeError;
    const to_id = to_list.asObjectId();
    const input_value = try vm_force.forceValue(self, string_arg);
    if (from_ids.len != (try self.heap.getList(to_id)).len or !isPlainString(input_value)) return error.TypeError;

    const input = self.intern.get(try stringTextInternId(self, input_value));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);

    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);
    for (try string_context.contextEntriesForValue(self, input_value)) |entry| {
        try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
    }

    // Iterate one past the end so an empty needle can match at the final
    // position (`replaceStrings [""] ["X"] "abc"` → "XaXbXcX"), matching Nix.
    var index: usize = 0;
    while (index <= input.len) {
        if (firstReplacementIdAt(self, input[index..], from_ids)) |replacement_index| {
            // GC: `ctx` may hold merged context values (fresh young attrs from
            // a prior replacement's context collision) reachable only through
            // this Zig list; the `to[i]` force below can collect. Re-root them.
            const iter_roots = vm_force.rootsBegin(self);
            defer vm_force.rootsEnd(self, iter_roots);
            for (ctx.items) |e| vm_force.rootKeep(self, e.value);
            const needle = self.intern.get(from_ids[replacement_index]);
            const replacement = try vm_force.forceValue(self, try self.heap.getListItem(to_id, replacement_index));
            if (!isPlainString(replacement)) return error.TypeError;
            try out.appendSlice(self.allocator, self.intern.get(try stringTextInternId(self, replacement)));
            for (try string_context.contextEntriesForValue(self, replacement)) |entry| {
                try string_context.appendContextEntry(self, &ctx, entry.name, entry.value);
            }
            if (needle.len == 0) {
                // Empty match: emit the current char (if any) and advance one,
                // so the empty pattern interleaves rather than looping forever.
                if (index < input.len) try out.append(self.allocator, input[index]);
                index += 1;
            } else {
                index += needle.len;
            }
        } else {
            if (index < input.len) try out.append(self.allocator, input[index]);
            index += 1;
        }
    }

    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(out.items.len, ctx.items.len != 0);
    const text_id = try self.intern.intern(out.items);
    if (ctx.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, ctx.items));
}

pub fn stringArg(self: *VM, arg: Value) ![]const u8 {
    const value = try vm_force.forceValue(self, arg);
    if (!isStringLike(value) or value.isPath()) return vm_trace.typeErrorExpected(self, "a string", value);
    return self.intern.get(try stringTextInternId(self, value));
}

pub fn isStringLike(value: Value) bool {
    return value.isString() or value.isPath() or value.isContextString();
}

pub fn isPlainString(value: Value) bool {
    return value.isString() or value.isContextString();
}

pub fn isCallable(self: *VM, value: Value) !bool {
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

pub fn stringTextInternId(self: *VM, value: Value) !InternId {
    return switch (value.kind()) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

pub fn stringListArg(self: *VM, arg: Value) ![][]const u8 {
    const list = try vm_force.forceValue(self, arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    const out = try self.allocator.alloc([]const u8, items.len);
    errdefer self.allocator.free(out);
    for (out, 0..) |*string, i| string.* = try stringArg(self, try self.heap.getListItem(list_id, i));
    return out;
}

pub fn stringListInternIdsArg(self: *VM, arg: Value) ![]InternId {
    const list = try vm_force.forceValue(self, arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    const ids = try self.allocator.alloc(InternId, items.len);
    errdefer self.allocator.free(ids);
    for (ids, 0..) |*id, i| {
        const value = try vm_force.forceValue(self, try self.heap.getListItem(list_id, i));
        if (!isPlainString(value)) return error.TypeError;
        id.* = try stringTextInternId(self, value);
    }
    return ids;
}

pub fn builtinToString(self: *VM, arg: Value) !Value {
    return coerceToStringValue(self, arg);
}

pub fn coerceToStringId(self: *VM, arg: Value) !InternId {
    return stringTextInternId(self, try coerceToStringValue(self, arg));
}

pub fn coerceToStringValue(self: *VM, arg: Value) !Value {
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
            // Nix coerces a float with C++ `std::to_string` — fixed-point with
            // 6 fractional digits (`1.0` → "1.000000", `1.5e-6` → "0.000002"),
            // NOT the shortest `%g` form used to *print* a value.
            const s = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{value.asFloat()});
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

pub fn coerceListToStringId(self: *VM, list_id: ObjectId) !InternId {
    return stringTextInternId(self, try coerceListToStringValue(self, list_id));
}

pub fn coerceListToStringValue(self: *VM, list_id: ObjectId) !Value {
    // GC: `list_id` is a bare id and we force-walk the list (recursively for
    // nested lists/attrs); root the container across the walk.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.list(list_id));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);

    var first = true;
    var trailing_empty_list = false;
    const list_len = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < list_len) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        // GC: re-root the accumulated context values across each item's forces.
        const iter_roots = vm_force.rootsBegin(self);
        defer vm_force.rootsEnd(self, iter_roots);
        for (ctx.items) |e| vm_force.rootKeep(self, e.value);
        const forced = try vm_force.forceValue(self, item);
        if (try isEmptyListStringItem(self, forced)) {
            if (!first) trailing_empty_list = true;
            continue;
        }
        if (!first) try out.append(self.allocator, ' ');
        first = false;
        trailing_empty_list = false;
        const item_value = try coerceToStringValue(self, forced);
        // GC: `item_value` may be a FRESH context string (nested-list/attrs
        // coercion), reachable only through this Zig local — not the rooted
        // list arg. `appendContextEntry` below forces (context merge), which
        // can collect; root `item_value` so its context slice isn't swept
        // mid-iteration (w>1 UAF). Same discipline as concatStringsSep.
        vm_force.rootKeep(self, item_value);
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

pub fn isEmptyListStringItem(self: *VM, value: Value) !bool {
    return value.isList() and (try self.heap.getList(value.asObjectId())).len == 0;
}

pub fn coerceAttrsToStringValue(self: *VM, attrs: Value) !Value {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, attrs); // held across getAttrValue + callValue + coerce
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

pub fn coerceDerivationStringValue(self: *VM, arg: Value) !Value {
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
            // Nix coerces a float with C++ `std::to_string` — fixed-point with
            // 6 fractional digits (`1.0` → "1.000000", `1.5e-6` → "0.000002"),
            // NOT the shortest `%g` form used to *print* a value.
            const s = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{value.asFloat()});
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

pub fn coerceDerivationListToStringValue(self: *VM, list_id: ObjectId) !Value {
    // GC: root the (bare-id) list across the recursive force-walk.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.list(list_id));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var ctx: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer ctx.deinit(self.allocator);

    var first = true;
    var trailing_empty_list = false;
    const list_len = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < list_len) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        // GC: the `ctx` accumulator holds merged context values (new attrs) in
        // Zig memory across each later item's forces; re-root them per item.
        const iter_roots = vm_force.rootsBegin(self);
        defer vm_force.rootsEnd(self, iter_roots);
        for (ctx.items) |e| vm_force.rootKeep(self, e.value);
        const forced = try vm_force.forceValue(self, item);
        if (try isEmptyListStringItem(self, forced)) {
            if (!first) trailing_empty_list = true;
            continue;
        }
        if (!first) try out.append(self.allocator, ' ');
        first = false;
        trailing_empty_list = false;
        const item_value = try coerceDerivationStringValue(self, forced);
        // GC: `item_value` may be a FRESH context string (nested-list/attrs
        // coercion) held only in this Zig local — not the rooted list arg.
        // `appendContextEntry` forces (context merge) and can collect; root
        // `item_value` so its context slice survives (w>1 UAF on the drv
        // env-building hot path). Same discipline as concatStringsSep.
        vm_force.rootKeep(self, item_value);
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

pub fn coerceDerivationAttrsToStringValue(self: *VM, attrs: Value) !Value {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, attrs); // held across getAttrValue + callValue + coerce
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
