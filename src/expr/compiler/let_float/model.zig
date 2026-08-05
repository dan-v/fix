//! Scratch-lifetime rewrite plans and per-cluster overlays for let-float.
//!
//! Analysis results live in `let_analysis/model.zig`; this module deliberately owns
//! the optimizer-only state layered over them. Keeping the two separate makes
//! the analysis graph immutable after its walk and reusable by later policy.

const std = @import("std");
const ast = @import("syntax").ast;

const Node = ast.Node;

pub const Stats = struct {
    lets: std.atomic.Value(u64) = .init(0),
    bindings: std.atomic.Value(u64) = .init(0),
    dropped_dead: std.atomic.Value(u64) = .init(0),
    inlined_literal_uses: std.atomic.Value(u64) = .init(0),
    inlined_alias_uses: std.atomic.Value(u64) = .init(0),
    inlined_bindings: std.atomic.Value(u64) = .init(0),
    sunk_single_use: std.atomic.Value(u64) = .init(0),
    floated_branch: std.atomic.Value(u64) = .init(0),
    floated_cloned: std.atomic.Value(u64) = .init(0),
    flattened_lets: std.atomic.Value(u64) = .init(0),
    blocked_shadow: std.atomic.Value(u64) = .init(0),
    blocked_many: std.atomic.Value(u64) = .init(0),
    blocked_pinned: std.atomic.Value(u64) = .init(0),
    blocked_dynamic: std.atomic.Value(u64) = .init(0),
    blocked_recursive: std.atomic.Value(u64) = .init(0),
    cluster_hits: std.atomic.Value(u64) = .init(0),
    cluster_walks: std.atomic.Value(u64) = .init(0),
    prefix_members: std.atomic.Value(u64) = .init(0),
};

pub const Plan = struct {
    /// Per-binding: emit this group in the residual let?
    keep: []bool,
    /// Use-site rewrites: identifier node -> replacement expression.
    replacements: std.AutoHashMapUnmanaged(*const Node, *const Node),
    /// Branch-local floats: branch expression node -> original bindings to
    /// wrap around it as a synthetic inner let.
    wraps: std.AutoHashMapUnmanaged(*const Node, std.ArrayListUnmanaged(Node.Binding)),
    any_change: bool,
};

pub const ClusterOverlay = struct {
    /// Computed once even when branch cloning compiles the same cluster more
    /// than once.
    plan: ?Plan = null,
    /// Cached flat node for a merged directly-nested let spine.
    flat: ?*const Node = null,
};

pub const UnitState = struct {
    allocator: std.mem.Allocator,
    /// A cluster's outermost source node is its stable identity within one
    /// compile unit; all covered nested-let nodes share this overlay.
    overlays: std.AutoHashMapUnmanaged(*const Node, *ClusterOverlay) = .empty,

    pub fn init(allocator: std.mem.Allocator) UnitState {
        return .{ .allocator = allocator };
    }

    pub fn overlay(self: *UnitState, cluster_head: *const Node) !*ClusterOverlay {
        const gop = try self.overlays.getOrPut(self.allocator, cluster_head);
        if (!gop.found_existing) {
            const value = try self.allocator.create(ClusterOverlay);
            value.* = .{};
            gop.value_ptr.* = value;
        }
        return gop.value_ptr.*;
    }
};
