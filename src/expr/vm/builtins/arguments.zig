//! Shared attrset argument decoding for builtins.

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const ObjectId = @import("runtime").types.ObjectId;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");

pub fn appendStringAttr(self: *VM, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: []const u8, value: []const u8) !void {
    try entries.append(self.allocator, .{
        .name = try self.intern.intern(name),
        .value = Value.string(try self.intern.intern(value)),
    });
}

pub fn dupPathAttr(self: *VM, attrs_id: ObjectId, name: []const u8) ![]u8 {
    const name_id = try self.intern.intern(name);
    const value = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs_id, name_id));
    return switch (value.kind()) {
        .path, .string, .string_context => self.allocator.dupe(u8, self.intern.get(try strings.stringTextInternId(self, value))),
        else => error.TypeError,
    };
}

pub fn optionalStringAttr(self: *VM, attrs_id: ObjectId, name: []const u8) !?[]u8 {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    const forced = try vm_force.forceValue(self, value);
    if (!strings.isPlainString(forced)) return error.TypeError;
    return try self.allocator.dupe(u8, self.intern.get(try strings.stringTextInternId(self, forced)));
}

pub fn requiredStringAttr(self: *VM, attrs_id: ObjectId, name: []const u8) ![]u8 {
    return try optionalStringAttr(self, attrs_id, name) orelse error.MissingAttribute;
}

pub fn optionalBoolAttr(self: *VM, attrs_id: ObjectId, name: []const u8) !?bool {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    const forced = try vm_force.forceValue(self, value);
    if (!forced.isBool()) return error.TypeError;
    return forced.asBool();
}
