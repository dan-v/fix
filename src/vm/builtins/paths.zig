const std = @import("std");
const Value = @import("runtime").value.Value;
const file_cache = @import("runtime").file_cache;
const derivation = @import("derivation");
const nar = @import("runtime").nar;
const source_paths = @import("derivation").source_path;
const path_ops = @import("runtime").paths;
const nix_hash = @import("runtime").hash;
const strings = @import("strings.zig");
const string_context = @import("string_context.zig");
const fetch = @import("fetch.zig");
const vm_force = @import("../force.zig");

const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;
const isPlainString = strings.isPlainString;
const contextStringWithPath = string_context.contextStringWithPath;
const filterSourceAccepts = fetch.filterSourceAccepts;

pub fn builtinBaseNameOf(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    const path = switch (value.kind()) {
        .path, .string, .string_context => self.intern.get(try stringTextInternId(self, value)),
        else => return error.TypeError,
    };
    return Value.string(try self.intern.intern(path_ops.baseName(path)));
}

pub fn builtinDirOf(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    const path = switch (value.kind()) {
        .path, .string, .string_context => self.intern.get(try stringTextInternId(self, value)),
        else => return error.TypeError,
    };
    const dir = try self.intern.intern(path_ops.dirOf(path));
    return switch (value.kind()) {
        .path => Value.path(dir),
        .string, .string_context => Value.string(dir),
        else => unreachable,
    };
}

pub fn builtinPlaceholder(self: anytype, arg: Value) !Value {
    const output = try stringArg(self, arg);
    const fingerprint = try std.fmt.allocPrint(self.allocator, "nix-output:{s}", .{output});
    defer self.allocator.free(fingerprint);
    const hash = try nix_hash.hashBytesNixBase32(self.allocator, "sha256", fingerprint);
    defer self.allocator.free(hash);
    const text = try std.fmt.allocPrint(self.allocator, "/{s}", .{hash});
    defer self.allocator.free(text);
    return Value.string(try self.intern.intern(text));
}

pub fn builtinStorePath(self: anytype, arg: Value) !Value {
    const path = try strings.pathArg(self, arg);
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    return contextStringWithPath(self, try self.intern.intern(path));
}

pub fn builtinPath(self: anytype, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;
    const attrs_id = attrs.asObjectId();

    const path_id = try self.intern.intern("path");
    const path_value = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs_id, path_id));
    const path = switch (path_value.kind()) {
        .path, .string, .string_context => self.intern.get(try stringTextInternId(self, path_value)),
        else => return error.TypeError,
    };
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;

    const name_id = try self.intern.intern("name");
    const name_value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => Value.null_val,
        else => return err,
    };
    var store_name = path_ops.baseName(path);
    if (!name_value.isNull()) {
        const name = try vm_force.forceValue(self, name_value);
        if (!isPlainString(name)) return error.TypeError;
        store_name = self.intern.get(try stringTextInternId(self, name));
    }

    const filter_id = try self.intern.intern("filter");
    const filter_value = self.heap.getAttrValue(attrs_id, filter_id) catch |err| switch (err) {
        error.MissingAttribute => Value.null_val,
        else => return err,
    };

    const store_path = if (filter_value.isNull())
        try source_paths.storePathForSourceName(self.allocator, self.files, self.derivations.store_dir, path, store_name)
    else filtered: {
        const pred = try vm_force.forceValue(self, filter_value);
        const Context = struct {
            vm: @TypeOf(self),
            pred: Value,

            fn accept(context: *anyopaque, candidate: []const u8, kind: file_cache.FileCache.FileKind) anyerror!bool {
                const ctx: *@This() = @ptrCast(@alignCast(context));
                return filterSourceAccepts(ctx.vm, ctx.pred, candidate, kind);
            }
        };
        var context: Context = .{ .vm = self, .pred = pred };
        const hash = try nar.hashPathFiltered(self.allocator, self.files, path, .{
            .context = &context,
            .accept = Context.accept,
        });
        defer self.allocator.free(hash);
        break :filtered try derivation.sourcePath(self.allocator, self.derivations.store_dir, store_name, hash);
    };
    defer self.allocator.free(store_path);
    return contextStringWithPath(self, try self.intern.intern(store_path));
}

const std_testing = std.testing;
const renderForTest = @import("../../eval/test_helpers.zig").renderForTest;

test "baseNameOf and dirOf reject non-path non-string arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.baseNameOf 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.dirOf 1"));
}

test "baseNameOf and dirOf preserve the string-ness of their argument" {
    const base_of_path_type = try renderForTest("builtins.typeOf (builtins.baseNameOf /foo/bar)");
    defer std_testing.allocator.free(base_of_path_type);
    try std_testing.expectEqualStrings("\"string\"", base_of_path_type);

    const dir_of_path_type = try renderForTest("builtins.typeOf (builtins.dirOf /foo/bar)");
    defer std_testing.allocator.free(dir_of_path_type);
    try std_testing.expectEqualStrings("\"path\"", dir_of_path_type);

    const dir_of_string_type = try renderForTest("builtins.typeOf (builtins.dirOf \"foo/bar\")");
    defer std_testing.allocator.free(dir_of_string_type);
    try std_testing.expectEqualStrings("\"string\"", dir_of_string_type);
}

test "storePath rejects relative paths" {
    try std_testing.expectError(error.RelativePath, renderForTest("builtins.storePath \"relative/path\""));
}

test "path builtin rejects a relative path attribute" {
    try std_testing.expectError(error.RelativePath, renderForTest("builtins.path { path = \"relative/path\"; }"));
}

test "path builtin rejects a non-string name attribute" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.path { path = /.; name = 1; }"));
}

test "placeholder hashes distinct output names to distinct values" {
    const out = try renderForTest("builtins.placeholder \"out\"");
    defer std_testing.allocator.free(out);
    const dev = try renderForTest("builtins.placeholder \"dev\"");
    defer std_testing.allocator.free(dev);
    try std_testing.expect(!std.mem.eql(u8, out, dev));

    // Deterministic given the same input.
    const out_again = try renderForTest("builtins.placeholder \"out\"");
    defer std_testing.allocator.free(out_again);
    try std_testing.expectEqualStrings(out, out_again);
}
