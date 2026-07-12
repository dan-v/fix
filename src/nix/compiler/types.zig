//! Shared compiler-internal data types: tracked locals, captures/upvalues,
//! `with`-scopes, the attr-entry views/groups used by attr-set lowering,
//! and container-value options.

const std = @import("std");
const ast = @import("syntax").ast;
const base_types = @import("runtime").types;

const InternId = base_types.InternId;
const Node = ast.Node;

/// A local variable tracked during compilation.
pub const Local = struct {
    name: []const u8,
    name_id: InternId,
    depth: u8,
    /// Index from frame base on the stack.
    slot: u16,
};

pub const Capture = struct {
    pub const Kind = enum { local, upvalue };

    name: []const u8,
    name_id: InternId,
    kind: Kind,
    index: u16,
};

pub const WithScope = struct {
    kind: Capture.Kind,
    index: u16,
};

pub const AttrEntryView = struct {
    path: []const Node.Atom,
    expr: *const Node,
    inherit_outer: bool = false,
    /// The outermost attr-path segment this view was desugared from, threaded
    /// through nested-set splits. Nix reports the *start* of an attr path as the
    /// position of every desugared segment, so `{ foo.bar = 1; }` gives `bar`
    /// the position of `foo`. Null for a top-level segment (use `path[0]`).
    origin: ?Node.Atom = null,
};

/// All entries sharing one attr-name root, bucketed into direct `leaves`
/// (path.len == 1) and nested `tails` (path.len > 1).
///
/// FOOTGUN: `leaf_count`/`tail_count` are dual-purpose across the two
/// passes of `attrEntryGroups`. Pass 1 uses them as running *counts* to
/// size the `leaves`/`tails` slices; they are then reset to 0 and reused
/// as fill *cursors* in pass 2. So they equal the true bucket size only
/// before the carve and again after the fill completes — never trust them
/// mid-build; read `leaves.len`/`tails.len` once the slices are populated.
pub const AttrEntryGroup = struct {
    first: Node.Atom,
    name: []const u8,
    name_id: InternId,
    leaf: ?AttrEntryView = null,
    duplicate_leaf: ?AttrEntryView = null,
    leaves: []AttrEntryView = &.{},
    leaf_count: usize = 0,
    first_nested: ?AttrEntryView = null,
    tails: []AttrEntryView = &.{},
    tail_count: usize = 0,
};

pub const AttrEntryGroups = struct {
    groups: []AttrEntryGroup = &.{},
    leaves: []AttrEntryView = &.{},
    tails: []AttrEntryView = &.{},

    pub fn deinit(self: *AttrEntryGroups, allocator: std.mem.Allocator) void {
        allocator.free(self.leaves);
        allocator.free(self.tails);
        for (self.groups) |group| allocator.free(group.name);
        allocator.free(self.groups);
        self.* = .{};
    }
};

pub const ContainerValueOptions = struct {
    raw_identifier: bool = false,
    /// When true and the value compiles to a thunk, emit the eager
    /// variant — runtime submits the thunk to the urgent scheduler
    /// queue at creation. Set by let-binding compile when the body's
    /// strictness signature includes this binding's name.
    eager: bool = false,
};

pub const with_capture_name = "\x00with";
