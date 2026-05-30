//! Built-in function registry.
//!
//! Nix builtins like `import`, `map`, `toString`, etc. are registered here.
//! Each builtin has a name (for lookup) and a C-compatible function pointer.
//!
//! Builtin functions receive:
//!   - the global evaluator state (for allocation, interning)
//!   - argument count
//!   - arguments as a Value slice
//! and return a Value or error.

const std = @import("std");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const InternId = types.InternId;

pub const BuiltinFn = *const fn (state: *anyopaque, argc: u8, args: [*]const Value) anyerror!Value;

pub const BuiltinDef = struct {
    name: []const u8,
    name_id: InternId,
    arity: u8,
    func: BuiltinFn,
};

pub const BuiltinRegistry = struct {
    allocator: std.mem.Allocator,
    builtins: std.ArrayListUnmanaged(BuiltinDef),
    /// Map from interned name to builtin index.
    by_name: std.AutoArrayHashMapUnmanaged(InternId, u16),

    pub fn init(allocator: std.mem.Allocator) !BuiltinRegistry {
        return .{
            .allocator = allocator,
            .builtins = .empty,
            .by_name = .empty,
        };
    }

    pub fn deinit(self: *BuiltinRegistry) void {
        self.builtins.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
    }

    pub fn register(self: *BuiltinRegistry, def: BuiltinDef) !void {
        try self.by_name.put(self.allocator, def.name_id, @intCast(self.builtins.items.len));
        try self.builtins.append(self.allocator, def);
    }

    pub fn lookup(self: *const BuiltinRegistry, name: InternId) ?u16 {
        return self.by_name.get(name);
    }

    pub fn get(self: *const BuiltinRegistry, idx: u16) BuiltinDef {
        return self.builtins.items[idx];
    }
};

// ---- placeholder builtins ----

fn builtin_add(state: *anyopaque, argc: u8, args: [*]const Value) anyerror!Value {
    _ = state;
    _ = argc;
    const a = args[0];
    const b = args[1];
    if (a.isInt() and b.isInt()) {
        return Value.int(a.asInt() + b.asInt());
    }
    return error.TypeError;
}

fn builtin_toString(state: *anyopaque, argc: u8, args: [*]const Value) anyerror!Value {
    _ = state;
    _ = argc;
    _ = args;
    return error.Todo;
}

pub fn registerDefaults(registry: *BuiltinRegistry) !void {
    try registry.register(.{
        .name = "add",
        .name_id = 0, // caller must intern first
        .arity = 2,
        .func = builtin_add,
    });
    try registry.register(.{
        .name = "toString",
        .name_id = 0, // caller must intern first
        .arity = 1,
        .func = builtin_toString,
    });
}