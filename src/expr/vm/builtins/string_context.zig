//! Nix string-context builtins: getContext, hasContext, appendContext, and
//! the unsafeDiscard*/addDrvOutputDependencies context manipulators, plus the
//! context-entry helpers those and other builtin families share.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const context_merge = @import("../context_merge.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");

/// The context-merge algorithm now lives in `vm/context_merge.zig`. Re-exported
/// here so the many `string_context.appendContextEntry` call sites (and this
/// file's own builtins) share the one canonical, GC-safe implementation.
pub const appendContextEntry = context_merge.appendContextEntry;

pub fn builtinGetContext(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    // getContext does not coerce — a path or derivation is a type error (unlike
    // string concatenation, which coerces them).
    if (value.kind() != .string and value.kind() != .string_context and value.kind() != .heap_string) {
        return vm_trace.typeErrorExpected(self, "a string", value);
    }
    return Value.attrs(try self.heap.addAttrs(try contextEntriesForValue(self, value)));
}

pub fn builtinHasContext(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal((try contextEntriesForValue(self, value)).len != 0);
}

pub fn builtinAppendContext(self: *VM, string_arg: Value, context_arg: Value) !Value {
    const string_value = try vm_force.forceValue(self, string_arg);
    if (!strings.isStringLike(string_value)) return error.TypeError;
    const context_value = try vm_force.forceValue(self, context_arg);
    if (!context_value.isAttrs()) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, string_value)) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);
    for (try self.heap.materializeAttrs(context_value.asObjectId())) |entry| try appendContextEntry(self, &entries, entry.name, entry.value);

    if (entries.items.len == 0) return Value.string(try strings.stringNameId(self, string_value));
    return Value.contextString(try self.heap.addContextString(try strings.stringNameId(self, string_value), entries.items));
}

pub fn builtinUnsafeDiscardStringContext(self: *VM, arg: Value) !Value {
    // Nix coerces the argument to a string first (paths, derivations, and
    // `__toString` attrsets are accepted), then drops the context.
    const value = try strings.coerceStringContextValue(self, arg);
    // A plain heap string has no context to discard; hand it back rather
    // than interning it.
    if (value.isHeapString()) return value;
    return Value.string(try strings.stringTextInternId(self, value));
}

pub fn builtinUnsafeDiscardOutputDependency(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return error.TypeError;
    const text_id = try strings.stringNameId(self, value);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (try contextEntriesForValue(self, value)) |entry| {
        try appendContextEntry(self, &entries, entry.name, try pathContextValue(self));
    }
    if (entries.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

pub fn builtinAddDrvOutputDependencies(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return vm_trace.typeErrorExpected(self, "a string", value);
    const text_id = try strings.stringNameId(self, value);

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
    try context_merge.appendContextEntry(self, &entries, entry.name, try allOutputsContextValue(self));
    return Value.contextString(try self.heap.addContextString(text_id, entries.items));
}

pub fn contextEntriesForValue(self: *VM, value: Value) ![]const heap_mod.AttrEntry {
    return switch (value.kind()) {
        .string, .heap_string => &.{},
        .path => try singleContextEntry(self, value.asInternId(), try pathContextValue(self)),
        .string_context => (try self.heap.getContextString(value.asObjectId())).context,
        else => error.TypeError,
    };
}

pub fn singleContextEntry(self: *VM, name: InternId, value: Value) ![]const heap_mod.AttrEntry {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, 1);
    entries[0] = .{ .name = name, .value = value };
    return entries;
}

pub fn pathContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn allOutputsContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("allOutputs"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn contextStringWithPath(self: *VM, text_id: InternId) !Value {
    return contextStringTextWithPath(self, text_id, text_id);
}

/// Like `contextStringWithPath`, but the string text (`text_id`) may differ
/// from the store path recorded in its context (`path_id`). A plain-eval fetch
/// uses this: its text is a readable download-cache path while its context
/// references the real fixed-output store path (so `builtins.getContext`
/// matches Nix even though there is no store to materialize the path).
pub fn contextStringTextWithPath(self: *VM, text_id: InternId, path_id: InternId) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = path_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextString(text_id, &entries));
}
