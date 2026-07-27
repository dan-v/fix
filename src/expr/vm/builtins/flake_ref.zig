//! Parse and render flake-reference values.

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const ObjectId = @import("runtime").types.ObjectId;
const heap_mod = @import("runtime").heap;
const flake_registry = @import("flake_registry.zig");
const arguments = @import("arguments.zig");
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");

const appendStringAttr = arguments.appendStringAttr;
const optionalStringAttr = arguments.optionalStringAttr;
const requiredStringAttr = arguments.requiredStringAttr;

/// A 40-char lowercase-hex git revision (as opposed to a branch/tag `ref`).
fn looksLikeGitRev(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |character| if (!std.ascii.isHex(character) or std.ascii.isUpper(character)) return false;
    return true;
}

pub fn parse(self: *VM, arg: Value) !Value {
    const ref = try strings.stringArg(self, arg);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    const query_index = std.mem.indexOfScalar(u8, ref, '?');
    const base = if (query_index) |index| ref[0..index] else ref;
    const query = if (query_index) |index| ref[index + 1 ..] else "";

    // Explicit `flake:<id>` is the same indirect reference as a bare id.
    if (std.mem.startsWith(u8, base, "flake:")) {
        const rest = base["flake:".len..];
        const full = if (query_index != null)
            try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ rest, query })
        else
            try self.allocator.dupe(u8, rest);
        defer self.allocator.free(full);
        return parse(self, Value.string(try self.intern.intern(full)));
    }

    inline for (.{ "github", "gitlab", "sourcehut" }) |forge| {
        if (std.mem.startsWith(u8, base, forge ++ ":")) {
            try appendStringAttr(self, &entries, "type", forge);
            var parts = std.mem.splitScalar(u8, base[forge.len + 1 ..], '/');
            const owner = parts.next() orelse return error.InvalidFlakeRef;
            const repo = parts.next() orelse return error.InvalidFlakeRef;
            try appendStringAttr(self, &entries, "owner", owner);
            try appendStringAttr(self, &entries, "repo", repo);
            if (parts.next()) |segment| if (segment.len != 0) {
                try appendStringAttr(self, &entries, if (looksLikeGitRev(segment)) "rev" else "ref", segment);
            };
            try appendQueryAttrs(self, &entries, query);
            return Value.attrs(try self.heap.addAttrs(entries.items));
        }
    }

    if (std.mem.startsWith(u8, base, "git+")) {
        try appendStringAttr(self, &entries, "type", "git");
        try appendStringAttr(self, &entries, "url", base["git+".len..]);
        try appendQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }
    if (std.mem.startsWith(u8, base, "git://") or std.mem.startsWith(u8, base, "ssh://")) {
        try appendStringAttr(self, &entries, "type", "git");
        try appendStringAttr(self, &entries, "url", base);
        try appendQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    if (std.mem.startsWith(u8, base, "tarball+")) {
        try appendStringAttr(self, &entries, "type", "tarball");
        try appendStringAttr(self, &entries, "url", base["tarball+".len..]);
        try appendQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }
    if (std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://")) {
        try appendStringAttr(self, &entries, "type", "tarball");
        try appendStringAttr(self, &entries, "url", base);
        try appendQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    if (std.mem.startsWith(u8, base, "path:")) {
        try appendStringAttr(self, &entries, "type", "path");
        try appendStringAttr(self, &entries, "path", base["path:".len..]);
        try appendQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }
    if (std.fs.path.isAbsolute(base)) {
        try appendStringAttr(self, &entries, "type", "path");
        try appendStringAttr(self, &entries, "path", base);
        try appendQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    if (try flake_registry.resolve(self, base)) |concrete| {
        defer self.allocator.free(concrete);
        const full = if (query_index != null)
            try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ concrete, query })
        else
            try self.allocator.dupe(u8, concrete);
        defer self.allocator.free(full);
        return parse(self, Value.string(try self.intern.intern(full)));
    }
    return error.InvalidFlakeRef;
}

pub fn render(self: *VM, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;
    const id = attrs.asObjectId();

    const type_value = try requiredStringAttr(self, id, "type");
    defer self.allocator.free(type_value);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);

    if (std.mem.eql(u8, type_value, "github") or std.mem.eql(u8, type_value, "gitlab") or std.mem.eql(u8, type_value, "sourcehut")) {
        const owner = try requiredStringAttr(self, id, "owner");
        defer self.allocator.free(owner);
        const repo = try requiredStringAttr(self, id, "repo");
        defer self.allocator.free(repo);
        const pin = (try optionalStringAttr(self, id, "rev")) orelse (try optionalStringAttr(self, id, "ref"));
        defer if (pin) |segment| self.allocator.free(segment);
        const head = if (pin) |segment|
            try std.fmt.allocPrint(self.allocator, "{s}:{s}/{s}/{s}", .{ type_value, owner, repo, segment })
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{s}/{s}", .{ type_value, owner, repo });
        defer self.allocator.free(head);
        try out.appendSlice(self.allocator, head);
        var first = true;
        try appendQueryStrings(self, id, &.{ "host", "dir", "narHash", "submodules" }, &out, &first);
        return Value.string(try self.intern.intern(out.items));
    }

    if (std.mem.eql(u8, type_value, "path")) {
        const path = try requiredStringAttr(self, id, "path");
        defer self.allocator.free(path);
        try out.appendSlice(self.allocator, "path:");
        try out.appendSlice(self.allocator, path);
        var first = true;
        try appendQueryStrings(self, id, &.{ "ref", "rev", "narHash", "dir" }, &out, &first);
        return Value.string(try self.intern.intern(out.items));
    }

    const url_type: ?struct { prefix: []const u8, bare_http: bool } =
        if (std.mem.eql(u8, type_value, "git")) .{ .prefix = "git+", .bare_http = false } else if (std.mem.eql(u8, type_value, "mercurial")) .{ .prefix = "hg+", .bare_http = false } else if (std.mem.eql(u8, type_value, "file")) .{ .prefix = "file+", .bare_http = false } else if (std.mem.eql(u8, type_value, "tarball")) .{ .prefix = "tarball+", .bare_http = true } else null;
    if (url_type) |kind| {
        const url = try requiredStringAttr(self, id, "url");
        defer self.allocator.free(url);
        const http = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
        if (!(kind.bare_http and http)) try out.appendSlice(self.allocator, kind.prefix);
        try out.appendSlice(self.allocator, url);
        var first = true;
        try appendQueryStrings(self, id, &.{ "ref", "rev", "narHash", "dir", "host", "submodules", "shallow" }, &out, &first);
        return Value.string(try self.intern.intern(out.items));
    }

    return error.InvalidFlakeRef;
}

fn appendQueryAttrs(self: *VM, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), query: []const u8) !void {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..separator];
        const value = part[separator + 1 ..];
        inline for (.{ "ref", "rev", "narHash", "dir", "host", "submodules", "shallow", "lastModified", "revCount" }) |known| {
            if (std.mem.eql(u8, key, known)) {
                try appendStringAttr(self, entries, key, value);
                break;
            }
        }
    }
}

fn appendQueryStrings(self: *VM, attrs_id: ObjectId, names: []const []const u8, out: *std.ArrayListUnmanaged(u8), first: *bool) !void {
    for (names) |name| try appendQueryString(self, attrs_id, name, out, first);
}

fn appendQueryString(self: *VM, attrs_id: ObjectId, name: []const u8, out: *std.ArrayListUnmanaged(u8), first: *bool) !void {
    const value = try optionalStringAttr(self, attrs_id, name) orelse return;
    defer self.allocator.free(value);
    try out.append(self.allocator, if (first.*) '?' else '&');
    first.* = false;
    try out.appendSlice(self.allocator, name);
    try out.append(self.allocator, '=');
    try out.appendSlice(self.allocator, value);
}
