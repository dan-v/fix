const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const source_paths = @import("derivation").source_path;

const closures = @import("closures.zig");
const force = @import("force.zig");
const trace = @import("trace.zig");

const VM = vm_mod.VM;

pub fn concatInternedString(self: *VM, a: InternId, b: InternId) !InternId {
    const s_a = self.intern.get(a);
    const s_b = self.intern.get(b);
    const buf = try self.allocator.alloc(u8, s_a.len + s_b.len);
    defer self.allocator.free(buf);

    @memcpy(buf[0..s_a.len], s_a);
    @memcpy(buf[s_a.len..], s_b);

    return self.intern.intern(buf);
}

pub fn stringLikeValue(self: *VM, value: Value) !Value {
    const forced = try force.forceValue(self, value);
    return switch (forced.kind()) {
        .string, .path, .string_context => forced,
        .attrs => try attrsStringLikeValue(self, forced),
        else => trace.typeErrorExpected(self, "string or path", forced),
    };
}

pub fn stringLikeInternId(self: *VM, value: Value) !InternId {
    return stringTextInternId(self, try stringLikeValue(self, value));
}

pub fn stringTextInternId(self: *VM, value: Value) !InternId {
    return switch (value.kind()) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

pub fn stringTextInternIdsEqual(self: *VM, left: Value, right: Value) !bool {
    if (!left.isContextString() and !right.isContextString()) {
        return left.asInternId() == right.asInternId();
    }
    return (try stringTextInternId(self, left)) == (try stringTextInternId(self, right));
}

pub fn isPlainString(value: Value) bool {
    return value.isString() or value.isContextString();
}

pub fn attrsStringLikeValue(self: *VM, attrs: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, attrs); // held across getAttrValue + callValue + recurse
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        return stringLikeValue(self, try closures.callValue(self, try force.forceValue(self, to_string), attrs));
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return trace.typeErrorExpected(self, "string or path", attrs),
        else => return err,
    };
    return stringLikeValue(self, out_path);
}

pub fn concatPathLike(self: *VM, left: Value, right: Value) !Value {
    const right_like = try stringLikeValue(self, right);
    const raw_text_id = try concatInternedString(self, left.asInternId(), try stringTextInternId(self, right_like));
    const raw_text = self.intern.get(raw_text_id);
    const text_id = if (std.fs.path.isAbsolute(raw_text)) text_id: {
        const normalized = try std.fs.path.resolve(self.allocator, &.{raw_text});
        defer self.allocator.free(normalized);
        break :text_id try self.intern.intern(normalized);
    } else raw_text_id;

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    if (right_like.isContextString()) {
        if (try hasStorePathContext(self, right_like)) return error.InvalidPathConcatenation;
        try appendStringContext(self, &context, right_like);
    }
    if (context.items.len == 0) return Value.path(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn concatStringLike(self: *VM, left: Value, right: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const left_like = try coerceLanguageStringValue(self, left);
    force.rootKeep(self, left_like); // held across the `right` coercion + appendStringContext forces
    const right_like = try coerceLanguageStringValue(self, right);
    force.rootKeep(self, right_like); // held across appendStringContext forces
    const text_id = try concatInternedString(self, try stringTextInternId(self, left_like), try stringTextInternId(self, right_like));

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    try appendStringContext(self, &context, left_like);
    try appendStringContext(self, &context, right_like);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn coerceLanguageStringValue(self: *VM, value: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const forced = try force.forceValue(self, value);
    force.rootKeep(self, forced); // held across getAttrValue + callValue + recurse
    return switch (forced.kind()) {
        .string, .string_context => forced,
        .path => try sourcePathStringValue(self, forced.asInternId()),
        .attrs => blk: {
            const to_string_id = try self.intern.intern("__toString");
            if (self.heap.getAttrValue(forced.asObjectId(), to_string_id)) |to_string| {
                break :blk try coerceLanguageStringValue(self, try closures.callValue(self, try force.forceValue(self, to_string), forced));
            } else |err| switch (err) {
                error.MissingAttribute => {},
                else => return err,
            }

            const out_path_id = try self.intern.intern("outPath");
            const out_path = self.heap.getAttrValue(forced.asObjectId(), out_path_id) catch |err| switch (err) {
                error.MissingAttribute => return trace.typeErrorExpected(self, "string or path", forced),
                else => return err,
            };
            break :blk try coerceLanguageStringValue(self, out_path);
        },
        else => trace.typeErrorExpected(self, "string or path", forced),
    };
}

pub fn sourcePathStringValue(self: *VM, path_id: InternId) !Value {
    const path = self.intern.get(path_id);
    if (!std.fs.path.isAbsolute(path)) {
        const entries = [_]heap_mod.AttrEntry{
            .{ .name = path_id, .value = try pathContextValue(self) },
        };
        return Value.contextString(try self.heap.addContextString(path_id, &entries));
    }
    if (!try self.files.pathExists(path)) return error.FileNotFound;
    const store_path = try source_paths.storePathForSource(self.allocator, self.files, self.derivations.store_dir, path);
    defer self.allocator.free(store_path);
    const store_path_id = try self.intern.intern(store_path);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = store_path_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextString(store_path_id, &entries));
}

pub fn appendStringContext(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), value: Value) !void {
    switch (value.kind()) {
        .string => {},
        .path => {
            const path = self.intern.get(value.asInternId());
            if (!try self.files.pathExists(path)) return error.FileNotFound;
            try appendContextEntry(self, context, value.asInternId(), try pathContextValue(self));
        },
        .string_context => {
            const gc_roots = force.rootsBegin(self);
            defer force.rootsEnd(self, gc_roots);
            force.rootKeep(self, value); // owns string.context slice, held across appendContextEntry forces
            const string = try self.heap.getContextString(value.asObjectId());
            for (string.context) |entry| try appendContextEntry(self, context, entry.name, entry.value);
        },
        else => return error.TypeError,
    }
}

pub fn hasStorePathContext(self: *VM, value: Value) !bool {
    if (!value.isContextString()) return false;
    const string = try self.heap.getContextString(value.asObjectId());
    for (string.context) |entry| {
        if (std.mem.startsWith(u8, self.intern.get(entry.name), "/nix/store/")) return true;
    }
    return false;
}

pub fn appendContextEntry(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: InternId, value: Value) !void {
    for (context.items) |*entry| {
        if (entry.name == name) {
            entry.value = try mergeContextValues(self, entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

pub fn mergeContextValues(self: *VM, left: Value, right: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const left_forced = try force.forceValue(self, left);
    force.rootKeep(self, left_forced); // held across the `right` force + mergeContextAttrs
    const right_forced = try force.forceValue(self, right);
    if (left_forced.isAttrs() and right_forced.isAttrs()) {
        return Value.attrs(try mergeContextAttrs(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

pub fn mergeContextAttrs(self: *VM, left_id: ObjectId, right_id: ObjectId) !ObjectId {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, Value.attrs(left_id)); // owns `left` slice, held across mergeContextAttrValue forces
    force.rootKeep(self, Value.attrs(right_id)); // owns `right` slice
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

    return self.heap.addAttrsSorted(merged.items);
}

pub fn mergeContextAttrValue(self: *VM, name: InternId, left: Value, right: Value) !Value {
    if (name == try self.intern.intern("outputs")) return mergeContextOutputs(self, left, right);
    return right;
}

pub fn mergeContextOutputs(self: *VM, left: Value, right: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const left_list = try force.forceValue(self, left);
    force.rootKeep(self, left_list); // owns getList slice, held across appendUniqueContextOutput forces
    const right_list = try force.forceValue(self, right);
    force.rootKeep(self, right_list); // owns getList slice, held across appendUniqueContextOutput forces
    if (!left_list.isList() or !right_list.isList()) return error.TypeError;

    var outputs: std.ArrayListUnmanaged(Value) = .empty;
    defer outputs.deinit(self.allocator);

    for (try self.heap.getList(left_list.asObjectId())) |item| try appendUniqueContextOutput(self, &outputs, item);
    for (try self.heap.getList(right_list.asObjectId())) |item| try appendUniqueContextOutput(self, &outputs, item);

    return Value.list(try self.heap.addList(outputs.items));
}

pub fn appendUniqueContextOutput(self: *VM, outputs: *std.ArrayListUnmanaged(Value), item: Value) !void {
    const value = try force.forceValue(self, item);
    if (!isPlainString(value)) return error.TypeError;
    const text = try stringTextInternId(self, value);
    for (outputs.items) |existing| {
        if (existing.asInternId() == text) return;
    }
    try outputs.append(self.allocator, Value.string(text));
}

pub fn pathContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}
