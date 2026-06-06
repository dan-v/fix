const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const types = @import("../types.zig");
const emit = @import("emit.zig");

const Compiler = compiler_mod.Compiler;
const Capture = compiler_mod.Capture;
const WithScope = compiler_mod.WithScope;
const with_capture_name = compiler_mod.with_capture_name;
const InternId = types.InternId;

pub fn beginScope(self: *Compiler) void {
    self.scope_depth += 1;
}

pub fn endScope(self: *Compiler) void {
    self.scope_depth -= 1;
    // Pop locals defined in this scope.
    while (self.locals.items.len > 0) {
        const local = self.locals.items[self.locals.items.len - 1];
        if (local.depth <= self.scope_depth) break;
        _ = self.locals.pop();
    }
}

pub fn declareLocal(self: *Compiler, name: []const u8, name_id: InternId) !u16 {
    if (self.slot_count == std.math.maxInt(u16)) return error.TooManyLocals;
    const slot = self.slot_count;
    self.slot_count += 1;
    errdefer self.slot_count -= 1;
    try self.locals.append(self.allocator, .{
        .name = name,
        .name_id = name_id,
        .depth = self.scope_depth,
        .slot = slot,
    });
    return slot;
}

pub fn resolveLocal(self: *const Compiler, name: []const u8) ?u16 {
    var i: usize = self.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = self.locals.items[i];
        if (self.skip_local_slot) |skip| {
            if (local.slot == skip) continue;
        }
        if (std.mem.eql(u8, local.name, name)) {
            return local.slot;
        }
    }
    return null;
}

pub fn resolveLocalId(self: *const Compiler, name_id: InternId) ?u16 {
    var i: usize = self.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = self.locals.items[i];
        if (self.skip_local_slot) |skip| {
            if (local.slot == skip) continue;
        }
        if (local.name_id == name_id) return local.slot;
    }
    return null;
}

pub fn resolveCapture(self: *Compiler, name: []const u8) !?u16 {
    const parent = self.parent orelse return null;
    if (resolveLocal(parent, name)) |parent_slot| {
        return try addCapture(self, name, .local, parent_slot);
    }
    if (try resolveCapture(parent, name)) |parent_upvalue| {
        return try addCapture(self, name, .upvalue, parent_upvalue);
    }
    return null;
}

pub fn addCapture(self: *Compiler, name: []const u8, kind: Capture.Kind, capture_index: u16) !u16 {
    for (self.captures.items, 0..) |capture, existing_index| {
        if (capture.kind == kind and capture.index == capture_index and std.mem.eql(u8, capture.name, name)) {
            return @intCast(existing_index);
        }
    }

    if (self.captures.items.len > std.math.maxInt(u16)) return error.TooManyCaptures;
    try self.captures.append(self.allocator, .{
        .name = name,
        .kind = kind,
        .index = capture_index,
    });
    return @intCast(self.captures.items.len - 1);
}

pub fn emitWithLookup(self: *Compiler, name: []const u8) !bool {
    var scopes: std.ArrayListUnmanaged(WithScope) = .empty;
    defer scopes.deinit(self.allocator);

    try collectWithScopes(self, &scopes);
    if (scopes.items.len == 0) return false;
    if (scopes.items.len > std.math.maxInt(u8)) return error.TooManyWithScopes;

    for (scopes.items) |scope| {
        switch (scope.kind) {
            .local => try emit.emitCaptureLocal(self, scope.index),
            .upvalue => try emit.emitOpU16(self, .capture_upvalue, scope.index),
        }
    }

    const name_id = try self.intern.intern(name);
    try emit.emitInternOp(self, .lookup_with, .lookup_with_long, name_id);
    try self.builder.writeByte(self.allocator, @intCast(scopes.items.len));
    return true;
}

pub fn collectWithScopes(self: *Compiler, scopes: *std.ArrayListUnmanaged(WithScope)) !void {
    var i: usize = self.with_scopes.items.len;
    while (i > 0) {
        i -= 1;
        try scopes.append(self.allocator, self.with_scopes.items[i]);
    }

    const parent = self.parent orelse return;
    var parent_scopes: std.ArrayListUnmanaged(WithScope) = .empty;
    defer parent_scopes.deinit(self.allocator);

    try collectWithScopes(parent, &parent_scopes);
    for (parent_scopes.items) |scope| {
        const capture_slot = try addCapture(self, with_capture_name, scope.kind, scope.index);
        try scopes.append(self.allocator, .{ .kind = .upvalue, .index = capture_slot });
    }
}
