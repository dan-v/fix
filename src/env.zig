//! Environment — a chain of scopes for variable lookup.
//!
//! In Nix, environments arise from let-bindings, lambda parameters,
//! and with-expressions. This implementation is a flat stack-based approach
//! optimized for the tail-calling VM.

const std = @import("std");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;

/// A single scope frame within the environment.
pub const ScopeFrame = struct {
    /// Maps interned names → Value.
    /// Small scopes are stored inline; larger ones spill to a hashmap.
    bindings: std.AutoArrayHashMapUnmanaged(InternId, Value),
};

/// The environment is a stack of scope frames.
/// Var lookups walk from innermost to outermost.
pub const Env = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(ScopeFrame),

    pub fn init(allocator: std.mem.Allocator) !Env {
        return .{
            .allocator = allocator,
            .frames = .empty,
        };
    }

    pub fn deinit(self: *Env) void {
        for (self.frames.items) |*frame| {
            frame.bindings.deinit(self.allocator);
        }
        self.frames.deinit(self.allocator);
    }

    /// Push a new empty scope.
    pub fn pushScope(self: *Env) !void {
        try self.frames.append(self.allocator, .{
            .bindings = .empty,
        });
    }

    /// Pop the innermost scope, returning ownership of it.
    pub fn popScope(self: *Env) ScopeFrame {
        const frame = self.frames.pop().?;
        return frame;
    }

    /// Insert a binding in the current innermost scope.
    pub fn define(self: *Env, name: InternId, value: Value) !void {
        const frame = &self.frames.items[self.frames.items.len - 1];
        try frame.bindings.put(self.allocator, name, value);
    }

    /// Look up a name, walking scopes outward.
    pub fn lookup(self: *const Env, name: InternId) ?Value {
        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.frames.items[i].bindings.get(name)) |val| {
                return val;
            }
        }
        return null;
    }

    /// Number of active scope frames.
    pub fn depth(self: *const Env) usize {
        return self.frames.items.len;
    }
};