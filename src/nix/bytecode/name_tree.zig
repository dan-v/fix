//! Qualified chunk names as a persistent tree, not strings.
//!
//! A chunk's name is its path through the binding hierarchy — `pkgs.hello`, not
//! the useless leaf `hello`. Building that path as a string per chunk (the old
//! `capture_names` sidecar) is expensive and single-threaded, so it was gated
//! off. Instead we store, per name, a `{ parent, segment }` node: the segment
//! is the leaf binding's interned id, the parent points at the enclosing name.
//! Siblings share the parent, so the whole naming hierarchy costs one small
//! node per *bound* chunk and no string is materialised until something renders
//! it (`writeQualified`, cold).
//!
//! The naming hierarchy is built top-down as the compiler descends (a parent's
//! node exists before its children), so — unlike the chunk registration graph,
//! which is bottom-up — a child can point at its parent node at creation. Nodes
//! are append-only and never mutated, so lock-free `appendAtomic` makes this
//! safe across the concurrent (deferred / speculative) compiles.

const std = @import("std");
const types = @import("runtime").types;
const InternTable = @import("runtime").intern.InternTable;
const segments = @import("base").segments;

/// A name is an index into the node store, biased by 1 so `0` means "no name"
/// (the root) without storing a sentinel node.
pub const NameId = u32;
pub const NAME_ROOT: NameId = 0;

pub const NameTree = struct {
    const Node = struct {
        parent: NameId,
        segment: types.InternId,
        /// A synthetic segment (λ, `(apply)`, node-tag) joins with `·` so the
        /// path never reads as a false attr path; a real binding joins with `.`.
        synthetic: bool,
    };
    const Store = segments.StableSegments(Node, .{ .first_segment_size = 64 }, @import("runtime").mem_tag.vma);

    nodes: Store = .empty,

    pub fn deinit(self: *NameTree, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }

    /// Intern a child name `parent`/`segment`. Returns its `NameId`. Lock-free.
    pub fn child(self: *NameTree, allocator: std.mem.Allocator, parent: NameId, segment: types.InternId, synthetic: bool) !NameId {
        const idx = try self.nodes.appendAtomic(allocator, .{ .parent = parent, .segment = segment, .synthetic = synthetic });
        return idx + 1; // bias: index 0 → NameId 1, keeping NameId 0 = root
    }

    pub fn isRoot(id: NameId) bool {
        return id == NAME_ROOT;
    }

    /// Write the fully-qualified path for `id` (nothing for the root). Segments
    /// join with `.` (real) or `·` (synthetic), matching the old string naming.
    pub fn writeQualified(self: *const NameTree, w: *std.Io.Writer, id: NameId, intern: *const InternTable) !void {
        try self.writeNode(w, id, intern);
    }

    fn writeNode(self: *const NameTree, w: *std.Io.Writer, id: NameId, intern: *const InternTable) !void {
        if (id == NAME_ROOT) return;
        if (id - 1 >= self.nodes.count()) return;
        const node = self.nodes.get(id - 1).*;
        try self.writeNode(w, node.parent, intern); // ancestors first
        // A leading separator before every segment except the root-most one.
        if (node.parent != NAME_ROOT) try w.writeAll(if (node.synthetic) "·" else ".");
        try w.writeAll(intern.get(node.segment));
    }

    /// Whether `id` names anything (has at least one segment).
    pub fn isNamed(self: *const NameTree, id: NameId) bool {
        return id != NAME_ROOT and id - 1 < self.nodes.count();
    }
};

test "name tree renders qualified paths and shares prefixes" {
    const testing = std.testing;
    var intern = try InternTable.init(testing.allocator);
    defer intern.deinit();
    var tree: NameTree = .{};
    defer tree.deinit(testing.allocator);

    const pkgs = try tree.child(testing.allocator, NAME_ROOT, try intern.intern("pkgs"), false);
    const hello = try tree.child(testing.allocator, pkgs, try intern.intern("hello"), false);
    const world = try tree.child(testing.allocator, pkgs, try intern.intern("world"), false);
    const over = try tree.child(testing.allocator, hello, try intern.intern("override"), false);

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try tree.writeQualified(&w, over, &intern);
    try testing.expectEqualStrings("pkgs.hello.override", buf[0..w.end]);

    w = .fixed(&buf);
    try tree.writeQualified(&w, world, &intern);
    try testing.expectEqualStrings("pkgs.world", buf[0..w.end]);

    w = .fixed(&buf);
    try tree.writeQualified(&w, NAME_ROOT, &intern);
    try testing.expectEqual(@as(usize, 0), w.end);
}
