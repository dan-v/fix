const std = @import("std");
const Value = @import("../../runtime/value.zig").Value;
const heap_mod = @import("../../runtime/heap.zig");
const path_ops = @import("../../runtime/paths.zig");
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");

const pathArg = strings.pathArg;
const stringTextInternId = strings.stringTextInternId;
const isPlainString = strings.isPlainString;

pub fn builtinPathExists(self: anytype, arg: Value) !Value {
    return Value.boolVal(try self.files.pathExists(try pathArg(self, arg)));
}

pub fn builtinReadFile(self: anytype, arg: Value) !Value {
    const contents = try self.files.readFile(try pathArg(self, arg));
    return Value.string(try self.intern.intern(contents));
}

pub fn builtinReadFileType(self: anytype, arg: Value) !Value {
    const kind = try self.files.fileType(try pathArg(self, arg));
    return Value.string(try self.intern.intern(kind.nixTypeName()));
}

pub fn builtinImport(self: anytype, arg: Value) !Value {
    const host = self.import_host orelse return error.ImportUnavailable;
    return host.import_value(host.context, try pathArg(self, arg));
}

pub fn builtinScopedImport(self: anytype, scope_arg: Value, path_arg: Value) !Value {
    const scope = try vm_force.forceValue(self, scope_arg);
    if (!scope.isAttrs()) return vm_trace.typeErrorExpected(self, "attrs", scope);
    const host = self.import_host orelse return error.ImportUnavailable;
    return host.scoped_import(host.context, scope, try pathArg(self, path_arg));
}

pub fn builtinReadDir(self: anytype, arg: Value) !Value {
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

pub fn builtinFindFile(self: anytype, search_path_arg: Value, name_arg: Value) !Value {
    const search_path = try vm_force.forceValue(self, search_path_arg);
    if (!search_path.isList()) return error.TypeError;
    const name = try pathArg(self, name_arg);

    const path_id = try self.intern.intern("path");
    const prefix_id = try self.intern.intern("prefix");
    for (try self.heap.getList(search_path.asObjectId())) |item| {
        const entry = try vm_force.forceValue(self, item);
        if (!entry.isAttrs()) return error.TypeError;

        const base_value = try vm_force.forceValue(self, try self.heap.getAttrValue(entry.asObjectId(), path_id));
        const base = switch (base_value.kind()) {
            .path, .string, .string_context => self.intern.get(try stringTextInternId(self, base_value)),
            else => return error.TypeError,
        };

        const prefix_value = self.heap.getAttrValue(entry.asObjectId(), prefix_id) catch |err| switch (err) {
            error.MissingAttribute => Value.string(try self.intern.intern("")),
            else => return err,
        };
        const prefix_forced = try vm_force.forceValue(self, prefix_value);
        if (!isPlainString(prefix_forced)) return error.TypeError;
        const prefix = self.intern.get(try stringTextInternId(self, prefix_forced));

        if (try findFileCandidate(self, base, prefix, name)) |candidate| {
            defer self.allocator.free(candidate);
            return Value.path(try self.intern.intern(candidate));
        }
    }
    return error.FileNotFound;
}

pub fn findFileCandidate(self: anytype, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
    const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
    const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
    errdefer self.allocator.free(candidate);
    if (try self.files.pathExists(candidate)) return candidate;
    self.allocator.free(candidate);
    return null;
}
