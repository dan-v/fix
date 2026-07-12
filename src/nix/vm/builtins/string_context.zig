//! Nix string-context builtins: getContext, hasContext, appendContext, and
//! the unsafeDiscard*/addDrvOutputDependencies context manipulators, plus the
//! context-entry helpers those and other builtin families share.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");

pub fn builtinGetContext(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    // getContext does not coerce — a path or derivation is a type error (unlike
    // string concatenation, which coerces them).
    if (value.kind() != .string and value.kind() != .string_context) {
        return vm_trace.typeErrorExpected(self, "a string", value);
    }
    return Value.attrs(try self.heap.addAttrs(try contextEntriesForValue(self, value)));
}

pub fn builtinHasContext(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal((try contextEntriesForValue(self, value)).len != 0);
}

pub fn builtinAppendContext(self: anytype, string_arg: Value, context_arg: Value) !Value {
    const string_value = try vm_force.forceValue(self, string_arg);
    if (!strings.isStringLike(string_value)) return error.TypeError;
    const context_value = try vm_force.forceValue(self, context_arg);
    if (!context_value.isAttrs()) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, string_value)) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);
    for (try self.heap.getAttrs(context_value.asObjectId())) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);

    if (entries.items.len == 0) return Value.string(try strings.stringTextInternId(self, string_value));
    return Value.contextString(try self.heap.addContextString(try strings.stringTextInternId(self, string_value), entries.items));
}

pub fn builtinUnsafeDiscardStringContext(self: anytype, arg: Value) !Value {
    // Nix coerces the argument to a string first (paths, derivations, and
    // `__toString` attrsets are accepted), then drops the context.
    const value = try strings.coerceStringContextValue(self, arg);
    return Value.string(try strings.stringTextInternId(self, value));
}

pub fn builtinUnsafeDiscardOutputDependency(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return error.TypeError;
    const text_id = try strings.stringTextInternId(self, value);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, value)) |entry| {
        try appendContextEntry(self, &entries, entry.name, try pathContextValue(self));
    }
    if (entries.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

pub fn builtinAddDrvOutputDependencies(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return vm_trace.typeErrorExpected(self, "a string", value);
    const text_id = try strings.stringTextInternId(self, value);

    // Nix requires the context to have exactly one element, which must be a
    // bare derivation (`.drv`), not one of its outputs.
    const ctx = try contextEntriesForValue(self, value);
    if (ctx.len != 1) {
        try vm_trace.setErrorMessage(self, "context of string must have exactly one element, but has a different number");
        return error.TypeError;
    }
    const entry = ctx[0];
    if (!std.mem.endsWith(u8, self.intern.get(entry.name), ".drv")) {
        try vm_trace.setErrorMessage(self, "addDrvOutputDependencies can only act on derivations");
        return error.TypeError;
    }
    // A `{ outputs = [...] }` marker means the element is a derivation OUTPUT,
    // which is rejected; `path`/`allOutputs` markers are the derivation itself.
    const marker = try vm_force.forceValue(self, entry.value);
    if (marker.isAttrs()) {
        const outputs_id = try self.intern.intern("outputs");
        if (self.heap.getAttrValue(marker.asObjectId(), outputs_id)) |_| {
            try vm_trace.setErrorMessage(self, "addDrvOutputDependencies can only act on derivations, not on a derivation output");
            return error.TypeError;
        } else |err| switch (err) {
            error.MissingAttribute => {},
            else => return err,
        }
    }

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try appendContextEntry(self, &entries, entry.name, try allOutputsContextValue(self));
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

pub fn contextEntriesForValue(self: anytype, value: Value) ![]const heap_mod.AttrEntry {
    return switch (value.kind()) {
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
            // GC: mergeContextValues forces; the already-accumulated entries in
            // `context` (caller-owned, not on the VM stack) plus the incoming
            // `value` must survive the walk.
            const gc_roots = vm_force.rootsBegin(self);
            defer vm_force.rootsEnd(self, gc_roots);
            for (context.items) |held| vm_force.rootKeep(self, held.value);
            vm_force.rootKeep(self, value);
            entry.value = try mergeContextValues(self, entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

pub fn mergeContextValues(self: anytype, left: Value, right: Value) !Value {
    // GC: `left` is held across the force of `right`, and both forced ids are
    // held across mergeContextAttrs (which forces). Root both across the walk.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, left);
    vm_force.rootKeep(self, right);
    const left_forced = try vm_force.forceValue(self, left);
    const right_forced = try vm_force.forceValue(self, right);
    if (left_forced.isAttrs() and right_forced.isAttrs()) {
        return Value.attrs(try mergeContextAttrs(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

pub fn mergeContextAttrs(self: anytype, left_id: ObjectId, right_id: ObjectId) !ObjectId {
    // GC: `left`/`right` are raw attr slices held across mergeContextAttrValue
    // -> mergeContextOutputs forces; keep their owner objects live.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.attrs(left_id));
    vm_force.rootKeep(self, Value.attrs(right_id));
    var left = try self.heap.getAttrs(left_id);
    var right = try self.heap.getAttrs(right_id);
    const left_len = left.len;
    const right_len = right.len;

    var merged = try std.ArrayListUnmanaged(heap_mod.AttrEntry).initCapacity(self.allocator, left_len + right_len);
    defer merged.deinit(self.allocator);

    var left_i: usize = 0;
    var right_i: usize = 0;
    while (left_i < left_len and right_i < right_len) {
        // gc: re-fetch — ranges may move across mergeContextAttrValue's force
        left = try self.heap.getAttrs(left_id);
        right = try self.heap.getAttrs(right_id);
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
    // gc: re-fetch — ranges may have moved across the loop's forces
    left = try self.heap.getAttrs(left_id);
    right = try self.heap.getAttrs(right_id);
    while (left_i < left_len) : (left_i += 1) {
        merged.appendAssumeCapacity(left[left_i]);
    }
    while (right_i < right_len) : (right_i += 1) {
        merged.appendAssumeCapacity(right[right_i]);
    }

    return self.heap.addAttrsSorted(merged.items);
}

pub fn mergeContextAttrValue(self: anytype, name: InternId, left: Value, right: Value) !Value {
    if (name == try self.intern.intern("outputs")) return mergeContextOutputs(self, left, right);
    return right;
}

pub fn mergeContextOutputs(self: anytype, left: Value, right: Value) !Value {
    // GC: `left`/`right` (and their forced list slices) are held across the
    // per-item forces in appendUniqueContextOutput; keep the lists live.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, left);
    vm_force.rootKeep(self, right);
    const left_list = try vm_force.forceValue(self, left);
    const right_list = try vm_force.forceValue(self, right);
    if (!left_list.isList() or !right_list.isList()) return error.TypeError;

    var outputs: std.ArrayListUnmanaged(Value) = .empty;
    defer outputs.deinit(self.allocator);

    // gc: re-fetch — ranges may move across appendUniqueContextOutput's force
    const left_id = left_list.asObjectId();
    const left_n = try self.heap.getListLen(left_id);
    var li: usize = 0;
    while (li < left_n) : (li += 1) try appendUniqueContextOutput(self, &outputs, try self.heap.getListItem(left_id, li));
    const right_id = right_list.asObjectId();
    const right_n = try self.heap.getListLen(right_id);
    var ri: usize = 0;
    while (ri < right_n) : (ri += 1) try appendUniqueContextOutput(self, &outputs, try self.heap.getListItem(right_id, ri));

    // Nix stores output names in a sorted set; sort so context identity
    // comparisons hold regardless of merge order.
    const Ctx = struct {
        intern: @TypeOf(self.intern),
        fn lt(ctx: @This(), a: Value, b: Value) bool {
            return std.mem.order(u8, ctx.intern.get(a.asInternId()), ctx.intern.get(b.asInternId())) == .lt;
        }
    };
    std.mem.sort(Value, outputs.items, Ctx{ .intern = self.intern }, Ctx.lt);
    return Value.list(try self.heap.addList(outputs.items));
}

pub fn appendUniqueContextOutput(self: anytype, outputs: *std.ArrayListUnmanaged(Value), item: Value) !void {
    const value = try vm_force.forceValue(self, item);
    if (!strings.isPlainString(value)) return error.TypeError;
    const text = try strings.stringTextInternId(self, value);
    for (outputs.items) |existing| {
        if (try strings.stringTextInternId(self, existing) == text) return;
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
