//! Persistent REPL bindings and their evaluator-rooted scope value.

const std = @import("std");
const expr = @import("expr");
const Value = @import("runtime").Value;

pub const Bindings = struct {
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,
    value: ?Value = null,

    pub fn deinit(self: *Bindings, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.map.deinit(allocator);
        self.* = .{};
    }

    pub fn bind(
        self: *Bindings,
        allocator: std.mem.Allocator,
        engine: *expr.Engine,
        name: []const u8,
        value: Value,
    ) !void {
        try self.apply(allocator, engine, &.{.{ .name = name, .value = value }});
    }

    /// Apply updates transactionally. Owned keys, map capacity, candidate
    /// scope, and evaluator roots are all staged before the live map changes;
    /// after the root swap, commit is allocation-free.
    pub fn apply(
        self: *Bindings,
        allocator: std.mem.Allocator,
        engine: *expr.Engine,
        updates: []const expr.Engine.ScopeBinding,
    ) !void {
        if (updates.len == 0) return;

        var update_values: std.StringHashMapUnmanaged(Value) = .empty;
        defer update_values.deinit(allocator);
        try update_values.ensureTotalCapacity(allocator, @intCast(updates.len));
        for (updates) |update| {
            const gop = update_values.getOrPutAssumeCapacity(update.name);
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = update.value;
        }

        var new_count: usize = 0;
        for (updates) |update| {
            if (!self.map.contains(update.name)) new_count += 1;
        }
        try self.map.ensureUnusedCapacity(allocator, new_count);

        const OwnedBinding = struct { name: []u8, value: Value };
        var new_bindings: std.ArrayListUnmanaged(OwnedBinding) = .empty;
        defer new_bindings.deinit(allocator);
        try new_bindings.ensureTotalCapacity(allocator, new_count);
        var keys_committed = false;
        defer if (!keys_committed) {
            for (new_bindings.items) |binding| allocator.free(binding.name);
        };
        for (updates) |update| {
            if (self.map.contains(update.name)) continue;
            new_bindings.appendAssumeCapacity(.{
                .name = try allocator.dupe(u8, update.name),
                .value = update.value,
            });
        }

        var candidate: std.ArrayListUnmanaged(expr.Engine.ScopeBinding) = .empty;
        defer candidate.deinit(allocator);
        try candidate.ensureTotalCapacity(allocator, self.map.count() + new_count);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            candidate.appendAssumeCapacity(.{
                .name = entry.key_ptr.*,
                .value = update_values.get(entry.key_ptr.*) orelse entry.value_ptr.*,
            });
        }
        for (new_bindings.items) |binding|
            candidate.appendAssumeCapacity(.{ .name = binding.name, .value = binding.value });

        const replacement = try engine.replaceExternalScope(candidate.items);

        for (updates) |update| {
            if (self.map.getPtr(update.name)) |existing| existing.* = update.value;
        }
        for (new_bindings.items) |binding| {
            const gop = self.map.getOrPutAssumeCapacity(binding.name);
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = binding.value;
        }
        keys_committed = true;
        self.value = replacement;
    }
};
