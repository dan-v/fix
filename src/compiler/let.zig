//! Lowers `let … in`: classifies each binding root
//! (unreferenced/literal/uncaptured/needs_cell) to skip binding cells and
//! dead bindings, then drives strictness-based eager elision (a
//! first-demanded, forward-ref-free binding is evaluated straight into its
//! slot with no thunk).

const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const types = @import("runtime").types;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");
const access = @import("access.zig");
const strictness = @import("strictness.zig");
const refs_mod = @import("refs.zig");
const lambda = @import("lambda.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const AttrEntryView = compiler_mod.AttrEntryView;
const InternId = types.InternId;

pub fn compileLetIn(self: *Compiler, node: *const Node) !void {
    try compileLetInBody(self, node, false);
}

pub fn compileLetInWithTailBody(self: *Compiler, node: *const Node) anyerror!void {
    try compileLetInBody(self, node, true);
}

fn compileLetInBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const let_in = node.data.let_in;

    scope.beginScope(self);

    // For each unique binding root, classify how it should be
    // compiled. Four kinds:
    //   .unreferenced      — nothing else in this let (or its body)
    //                        mentions the name; skip the binding
    //                        entirely. Nix is pure and lazy: if no
    //                        one forces the RHS, its side-effects
    //                        never fire, so omitting it is observably
    //                        equivalent.
    //   .literal           — RHS is a pure literal; eagerly bind value
    //                        directly into the slot (no cell).
    //   .uncaptured        — non-literal RHS, no earlier binding in
    //                        this let references the name; we can skip
    //                        the cell and just `set_local` the lazy
    //                        thunk value in pass 2. The body and any
    //                        later binding's RHS will see the bound
    //                        thunk and force normally.
    //   .needs_cell        — non-literal RHS that *is* referenced by
    //                        an earlier binding (forward reference);
    //                        the cell exists so the earlier RHS can
    //                        capture a mutable handle that this
    //                        binding's pass 2 mutates.
    const kinds = try classifyLetBindings(self, let_in.bindings, let_in.body);
    defer self.allocator.free(kinds);

    // Strictness-driven eagerness. Two analyses over the body:
    //   `eager_flags`      — may-force shallow set; drives the eager
    //                        *thunk* submit hint (helpers race ahead).
    //   `must_force_flags` — sound must-force set; drives eager
    //                        *elision* (pass 2): a non-recursive binding
    //                        the body unconditionally forces is compiled
    //                        straight into its slot, with no thunk at
    //                        all. Sound because lazy eval would force it
    //                        regardless — can't turn a success into an
    //                        error (only reorder which error surfaces in
    //                        an already-failing eval).
    const binding_name_ids = try self.allocator.alloc(InternId, let_in.bindings.len);
    defer self.allocator.free(binding_name_ids);
    for (let_in.bindings, binding_name_ids) |binding, *nid| {
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        nid.* = try self.intern.intern(name);
    }
    // Earliest source index of each binding root — the forward-ref guard
    // for eager elision (a binding can't be eagerly evaluated if its RHS
    // references a binding defined later, whose slot isn't filled yet).
    var earliest_index: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
    defer earliest_index.deinit(self.allocator);
    for (binding_name_ids, 0..) |nid, i| {
        if (!earliest_index.contains(nid)) try earliest_index.put(self.allocator, nid, i);
    }

    const eager_flags = try self.allocator.alloc(bool, let_in.bindings.len);
    defer self.allocator.free(eager_flags);
    const must_force_flags = try self.allocator.alloc(bool, let_in.bindings.len);
    defer self.allocator.free(must_force_flags);
    // One walk of the let body yields both the may-force (eager submit)
    // and must-force (eager elision) sets — they differ only at assert/with.
    try strictness.analyzeLetBindings(
        self.allocator,
        self.intern,
        self.source,
        let_in.body,
        binding_name_ids,
        eager_flags,
        must_force_flags,
    );
    // Eager elision may hoist a binding's evaluation ahead of the body's
    // reduction; if it isn't the FIRST thing the body demands, that reorders
    // which error surfaces (observable under `builtins.tryEval`: caught
    // `throw` vs uncaught `1/0`). Restrict elision to the single
    // first-demanded binding so eager order == lazy order. See firstForcedName.
    const first_demanded: ?InternId = try strictness.firstForcedName(self.intern, self.source, let_in.body);

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        if (kind == .unreferenced) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const name_id = try self.intern.intern(name);
        const slot = try scope.declareLocal(self, name, name_id);
        switch (kind) {
            .literal => {
                const leaf = singleLeafBinding(self, let_in.bindings, binding.path[0]).?;
                try access.compileContainerValue(self, leaf.expr, .{});
                try emit.emitSetLocal(self, slot);
            },
            .uncaptured => {}, // pass 2 will fill the slot directly
            .needs_cell => try emit.emitInitCellSlot(self, slot),
            .unreferenced => unreachable,
        }
    }

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        if (kind == .literal or kind == .unreferenced) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;

        // Eager elision: a non-recursive (`.uncaptured`) binding that the
        // body unconditionally forces, with a computational RHS that
        // references no later binding — evaluate it straight into the
        // slot, skipping the thunk alloc + force + frame entirely.
        if (kind == .uncaptured and must_force_flags[index] and
            first_demanded != null and binding_name_ids[index] == first_demanded.?)
        {
            if (eligibleEagerLeaf(self, let_in.bindings, binding.path[0], &earliest_index, index)) |leaf| {
                try self.compileNode(leaf.expr);
                try emit.emitSetLocal(self, slot);
                continue;
            }
        }

        try compileLetRootBinding(self, let_in.bindings, binding.path[0], slot, eager_flags[index]);
        switch (kind) {
            .needs_cell => try emit.emitSetCellLocal(self, slot),
            .uncaptured => try emit.emitSetLocal(self, slot),
            .literal, .unreferenced => unreachable,
        }
    }

    if (tail_body) {
        try lambda.compileTailExpression(self, let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    scope.endScope(self);
}

const LetBindingKind = enum { unreferenced, literal, uncaptured, needs_cell };

/// Decide for each binding whether it can skip the cell. A binding
/// needs a cell iff some *earlier* binding (which gets compiled first
/// in pass 2) references it by name — only then is the cell's
/// mutable-handle behaviour load-bearing. Later bindings and the body
/// always see the bound value because pass 2 fills slots in source
/// order before the body emits.
///
/// To keep compile cost reasonable on big lets, all queries below are
/// membership tests against the let's OWN binding names — so instead of
/// materializing a name set per region (body + every RHS), one walk per
/// region marks which binding names it mentions. Per name we keep how
/// many RHS regions mention it and the earliest such binding index;
/// that pair answers both the "referenced by another RHS" and the
/// "referenced at-or-before index" (cell-needed) predicates exactly.
fn classifyLetBindings(self: *Compiler, bindings: []const Node.Binding, body: *const Node) ![]LetBindingKind {
    const kinds = try self.allocator.alloc(LetBindingKind, bindings.len);
    errdefer self.allocator.free(kinds);

    // Slot per unique binding-root name, in first-occurrence order.
    var slots: std.StringHashMapUnmanaged(u32) = .empty;
    defer slots.deinit(self.allocator);
    try slots.ensureTotalCapacity(self.allocator, @intCast(bindings.len));
    var slot_count: u32 = 0;
    for (bindings) |binding| {
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const gop = slots.getOrPutAssumeCapacity(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = slot_count;
            slot_count += 1;
        }
    }

    const body_hit = try self.allocator.alloc(bool, slot_count);
    defer self.allocator.free(body_hit);
    @memset(body_hit, false);
    var body_marker: BodyMarker = .{ .slots = &slots, .hit = body_hit };
    refs_mod.walkReferencedNames(self, body, &body_marker);

    const rhs_counts = try self.allocator.alloc(u32, slot_count);
    defer self.allocator.free(rhs_counts);
    @memset(rhs_counts, 0);
    const rhs_first = try self.allocator.alloc(u32, slot_count);
    defer self.allocator.free(rhs_first);
    const rhs_stamp = try self.allocator.alloc(u32, slot_count);
    defer self.allocator.free(rhs_stamp);
    @memset(rhs_stamp, 0);

    var any_path_nested = false;
    var rhs_marker: RhsMarker = .{
        .slots = &slots,
        .counts = rhs_counts,
        .first = rhs_first,
        .stamp_seen = rhs_stamp,
        .stamp = 0,
        .index = 0,
    };
    for (bindings, 0..) |binding, i| {
        if (binding.path.len > 1) {
            // Nested-path bindings synthesise an attr-set thunk
            // whose captures we don't statically track; conservative:
            // any such binding "references" every other.
            any_path_nested = true;
        }
        rhs_marker.stamp += 1;
        rhs_marker.index = @intCast(i);
        refs_mod.walkReferencedNames(self, binding.expr, &rhs_marker);
    }

    for (bindings, 0..) |binding, i| {
        if (bindingRootSeen(self, bindings[0..i], binding.path[0])) {
            kinds[i] = .needs_cell;
            continue;
        }
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const slot = slots.get(name).?;

        const referenced_by_other_rhs = rhs_counts[slot] > 1 or
            (rhs_counts[slot] == 1 and rhs_first[slot] != i);
        const externally_referenced = body_hit[slot] or any_path_nested or
            referenced_by_other_rhs;
        if (!externally_referenced) {
            kinds[i] = .unreferenced;
            continue;
        }
        if (isLiteralLeafBinding(self, bindings, binding.path[0])) {
            kinds[i] = .literal;
            continue;
        }
        // A binding needs its cell when some RHS at-or-before it (earlier
        // sibling, or itself via self-recursion) mentions the name: that's
        // exactly the set whose pass-2 compile would capture before the
        // slot is filled.
        if (rhs_counts[slot] > 0 and rhs_first[slot] <= i) {
            kinds[i] = .needs_cell;
        } else {
            kinds[i] = .uncaptured;
        }
    }
    return kinds;
}

const BodyMarker = struct {
    slots: *const std.StringHashMapUnmanaged(u32),
    hit: []bool,

    pub fn mark(self: *BodyMarker, name: []const u8) void {
        if (self.slots.get(name)) |slot| self.hit[slot] = true;
    }
};

/// Per-slot RHS aggregation: `counts[slot]` = number of RHS regions
/// mentioning the name, `first[slot]` = earliest such binding index.
/// `stamp_seen` dedups within one region so a name mentioned twice in
/// the same RHS counts once (region semantics, matching the former
/// per-RHS hashsets).
const RhsMarker = struct {
    slots: *const std.StringHashMapUnmanaged(u32),
    counts: []u32,
    first: []u32,
    stamp_seen: []u32,
    stamp: u32,
    index: u32,

    pub fn mark(self: *RhsMarker, name: []const u8) void {
        const slot = self.slots.get(name) orelse return;
        if (self.stamp_seen[slot] == self.stamp) return;
        self.stamp_seen[slot] = self.stamp;
        self.counts[slot] += 1;
        if (self.counts[slot] == 1) self.first[slot] = self.index;
    }
};

/// True when the binding group sharing `root` is exactly one leaf
/// (no nested attr paths, no duplicates) and that leaf's RHS is a
/// pure literal — i.e. eager evaluation can replace the cell-wrap
/// without changing observable behaviour.
fn isLiteralLeafBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
    const leaf = singleLeafBinding(self, bindings, root) orelse return false;
    return access.isLiteralContainerValue(self, leaf.expr);
}

fn singleLeafBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom) ?Node.Binding {
    var found: ?Node.Binding = null;
    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root)) continue;
        if (binding.path.len != 1) return null;
        if (binding.inherit_outer) return null;
        if (found != null) return null;
        found = binding;
    }
    return found;
}

fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom, slot: u16, eager: bool) !void {
    var leaf: ?Node.Binding = null;
    var tail_count: usize = 0;

    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root)) continue;
        if (binding.path.len == 1) {
            if (leaf) |previous| {
                try diagnostics.reportCompileError(self, binding.name_offset, binding.name_len, "duplicate let binding");
                try diagnostics.reportCompileNote(self, previous.name_offset, previous.name_len, "first binding defined here");
                return error.DuplicateBinding;
            }
            leaf = binding;
        } else {
            tail_count += 1;
        }
    }

    if (tail_count == 0) {
        const binding = leaf orelse return error.UndefinedVariable;
        const previous_skip = self.skip_local_slot;
        if (binding.inherit_outer) self.skip_local_slot = slot;
        const compile_result = access.compileContainerValue(self, binding.expr, .{ .eager = eager });
        self.skip_local_slot = previous_skip;
        return compile_result;
    }

    const tails = try self.allocator.alloc(AttrEntryView, tail_count);
    defer self.allocator.free(tails);
    var i: usize = 0;
    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root) or binding.path.len == 1) continue;
        tails[i] = .{
            .path = binding.path[1..],
            .expr = binding.expr,
            .inherit_outer = binding.inherit_outer,
        };
        i += 1;
    }

    if (leaf) |root_leaf| {
        if (root_leaf.expr.tag != .attr_set) {
            try attrs.reportDuplicateAttribute(self, tails[0].path[0], root_leaf.path[0]);
            return error.DuplicateAttribute;
        }
        const leaves = [_]AttrEntryView{.{
            .path = root_leaf.path,
            .expr = root_leaf.expr,
            .inherit_outer = root_leaf.inherit_outer,
        }};
        return attrs.compileExtendedAttrSetLiteralThunk(self, &leaves, tails);
    }

    return attrs.compileAttrEntriesThunk(self, tails, true);
}

/// Eager-elision eligibility for a let binding. Returns the single-leaf
/// binding iff (a) it is a single leaf (not a nested attr path),
/// (b) its RHS is a computational shape — not a structural builder we
/// keep lazy (attrset/lambda/list) — and (c) its RHS references no
/// binding defined later in the same `let` (which would read an
/// unfilled slot when evaluated eagerly here). The caller guarantees
/// the binding is non-recursive (`.uncaptured`) and must-forced.
fn eligibleEagerLeaf(
    self: *Compiler,
    bindings: []const Node.Binding,
    root: Node.Atom,
    earliest: *const std.AutoHashMapUnmanaged(InternId, usize),
    index: usize,
) ?Node.Binding {
    const leaf = singleLeafBinding(self, bindings, root) orelse return null;
    if (!isEagerEvalShape(leaf.expr)) return null;
    if (rhsHasForwardRef(self, leaf.expr, earliest, index)) return null;
    return leaf;
}

/// Structural builders (attrset/lambda/list) stay lazy: they're already
/// inlined thunk-free where eager, and eagerly building an attrset value
/// can perturb module fixpoints. Everything else is a scalar/
/// computational expression whose strict evaluation is exactly what
/// forcing the binding-thunk would have done.
pub fn isEagerEvalShape(expr: *const Node) bool {
    return switch (expr.tag) {
        .attr_set, .lambda, .lambda_attrs, .list => false,
        else => true,
    };
}

/// Conservative forward-reference check: true if `expr` references any
/// `let` binding root whose earliest definition index is > `index`. On
/// collection failure returns true so the caller keeps the lazy path.
fn rhsHasForwardRef(
    self: *Compiler,
    expr: *const Node,
    earliest: *const std.AutoHashMapUnmanaged(InternId, usize),
    index: usize,
) bool {
    var refs: std.StringHashMapUnmanaged(void) = .empty;
    defer refs.deinit(self.allocator);
    refs_mod.collectReferencedNames(self, expr, &refs) catch return true;
    var it = refs.keyIterator();
    while (it.next()) |k| {
        const id = self.intern.intern(k.*) catch return true;
        if (earliest.get(id)) |first| {
            if (first > index) return true;
        }
    }
    return false;
}

fn bindingRootSeen(self: *const Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
    for (bindings) |binding| {
        if (binding.path.len > 0 and attrs.attrSegmentsEqual(self, binding.path[0], root)) return true;
    }
    return false;
}
