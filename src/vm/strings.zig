const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = @import("../opcode.zig");
const OpCode = opcode.OpCode;
const chunk = @import("../chunk.zig");
const Chunk = chunk.Chunk;
const thunk_mod = @import("../thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const heap_mod = @import("../heap.zig");
const Closure = heap_mod.Closure;
const numeric = @import("../runtime/numeric.zig");
const source_paths = @import("../runtime/source_path.zig");
const vm_builtins = @import("builtins.zig");
const diagnostic = @import("../diagnostic.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

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
    const forced = try self.forceValue(value);
    return switch (forced.discriminant) {
        .string, .path, .string_context => forced,
        .attrs => try self.attrsStringLikeValue(forced),
        else => self.typeErrorExpected("string or path", forced),
    };
}

pub fn stringLikeInternId(self: *VM, value: Value) !InternId {
    return self.stringTextInternId(try self.stringLikeValue(value));
}

pub fn stringTextInternId(self: *VM, value: Value) !InternId {
    return switch (value.discriminant) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

pub fn stringTextInternIdsEqual(self: *VM, left: Value, right: Value) !bool {
    if (left.discriminant != .string_context and right.discriminant != .string_context) {
        return left.asInternId() == right.asInternId();
    }
    return (try self.stringTextInternId(left)) == (try self.stringTextInternId(right));
}

pub fn isPlainString(value: Value) bool {
    return value.discriminant == .string or value.discriminant == .string_context;
}

pub fn attrsStringLikeValue(self: *VM, attrs: Value) !Value {
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        return self.stringLikeValue(try self.callValue(try self.forceValue(to_string), attrs));
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return self.typeErrorExpected("string or path", attrs),
        else => return err,
    };
    return self.stringLikeValue(out_path);
}

pub fn concatPathLike(self: *VM, left: Value, right: Value) !Value {
    const right_like = try self.stringLikeValue(right);
    const raw_text_id = try self.concatInternedString(left.asInternId(), try self.stringTextInternId(right_like));
    const raw_text = self.intern.get(raw_text_id);
    const text_id = if (std.fs.path.isAbsolute(raw_text)) text_id: {
        const normalized = try std.fs.path.resolve(self.allocator, &.{raw_text});
        defer self.allocator.free(normalized);
        break :text_id try self.intern.intern(normalized);
    } else raw_text_id;

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    if (right_like.discriminant == .string_context) {
        if (try self.hasStorePathContext(right_like)) return error.InvalidPathConcatenation;
        try self.appendStringContext(&context, right_like);
    }
    if (context.items.len == 0) return Value.path(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn concatStringLike(self: *VM, left: Value, right: Value) !Value {
    const left_like = try self.coerceLanguageStringValue(left);
    const right_like = try self.coerceLanguageStringValue(right);
    const text_id = try self.concatInternedString(try self.stringTextInternId(left_like), try self.stringTextInternId(right_like));

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    try self.appendStringContext(&context, left_like);
    try self.appendStringContext(&context, right_like);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn coerceLanguageStringValue(self: *VM, value: Value) !Value {
    const forced = try self.forceValue(value);
    return switch (forced.discriminant) {
        .string, .string_context => forced,
        .path => try self.sourcePathStringValue(forced.asInternId()),
        .attrs => blk: {
            const to_string_id = try self.intern.intern("__toString");
            if (self.heap.getAttrValue(forced.asObjectId(), to_string_id)) |to_string| {
                break :blk try self.coerceLanguageStringValue(try self.callValue(try self.forceValue(to_string), forced));
            } else |err| switch (err) {
                error.MissingAttribute => {},
                else => return err,
            }

            const out_path_id = try self.intern.intern("outPath");
            const out_path = self.heap.getAttrValue(forced.asObjectId(), out_path_id) catch |err| switch (err) {
                error.MissingAttribute => return self.typeErrorExpected("string or path", forced),
                else => return err,
            };
            break :blk try self.coerceLanguageStringValue(out_path);
        },
        else => self.typeErrorExpected("string or path", forced),
    };
}

pub fn sourcePathStringValue(self: *VM, path_id: InternId) !Value {
    const path = self.intern.get(path_id);
    if (!std.fs.path.isAbsolute(path)) {
        const entries = [_]heap_mod.AttrEntry{
            .{ .name = path_id, .value = try self.pathContextValue() },
        };
        return Value.contextString(try self.heap.addContextString(path_id, &entries));
    }
    if (!try self.files.pathExists(path)) return error.FileNotFound;
    const store_path = try source_paths.storePathForSource(self.allocator, self.files, self.derivations.store_dir, path);
    defer self.allocator.free(store_path);
    const store_path_id = try self.intern.intern(store_path);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = store_path_id, .value = try self.pathContextValue() },
    };
    return Value.contextString(try self.heap.addContextString(store_path_id, &entries));
}

pub fn appendStringContext(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), value: Value) !void {
    switch (value.discriminant) {
        .string => {},
        .path => {
            const path = self.intern.get(value.asInternId());
            if (!try self.files.pathExists(path)) return error.FileNotFound;
            try self.appendContextEntry(context, value.asInternId(), try self.pathContextValue());
        },
        .string_context => {
            const string = try self.heap.getContextString(value.asObjectId());
            for (string.context) |entry| try self.appendContextEntry(context, entry.name, entry.value);
        },
        else => return error.TypeError,
    }
}

pub fn hasStorePathContext(self: *VM, value: Value) !bool {
    if (value.discriminant != .string_context) return false;
    const string = try self.heap.getContextString(value.asObjectId());
    for (string.context) |entry| {
        if (std.mem.startsWith(u8, self.intern.get(entry.name), "/nix/store/")) return true;
    }
    return false;
}

pub fn appendContextEntry(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: InternId, value: Value) !void {
    for (context.items) |*entry| {
        if (entry.name == name) {
            entry.value = try self.mergeContextValues(entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

pub fn mergeContextValues(self: *VM, left: Value, right: Value) !Value {
    const left_forced = try self.forceValue(left);
    const right_forced = try self.forceValue(right);
    if (left_forced.discriminant == .attrs and right_forced.discriminant == .attrs) {
        return Value.attrs(try self.mergeContextAttrs(left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

pub fn mergeContextAttrs(self: *VM, left_id: ObjectId, right_id: ObjectId) !ObjectId {
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
            const value = try self.mergeContextAttrValue(l.name, l.value, r.value);
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

pub fn mergeContextAttrValue(self: *VM, name: InternId, left: Value, right: Value) !Value {
    if (name == try self.intern.intern("outputs")) return self.mergeContextOutputs(left, right);
    return right;
}

pub fn mergeContextOutputs(self: *VM, left: Value, right: Value) !Value {
    const left_list = try self.forceValue(left);
    const right_list = try self.forceValue(right);
    if (left_list.discriminant != .list or right_list.discriminant != .list) return error.TypeError;

    var outputs: std.ArrayListUnmanaged(Value) = .empty;
    defer outputs.deinit(self.allocator);

    for (try self.heap.getList(left_list.asObjectId())) |item| try self.appendUniqueContextOutput(&outputs, item);
    for (try self.heap.getList(right_list.asObjectId())) |item| try self.appendUniqueContextOutput(&outputs, item);

    return Value.list(try self.heap.addList(outputs.items));
}

pub fn appendUniqueContextOutput(self: *VM, outputs: *std.ArrayListUnmanaged(Value), item: Value) !void {
    const value = try self.forceValue(item);
    if (!isPlainString(value)) return error.TypeError;
    const text = try self.stringTextInternId(value);
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
