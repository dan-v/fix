//! Lowers `let … in`: classifies each binding root
//! (unreferenced/literal/uncaptured/needs_cell) to skip binding cells and
//! dead bindings, then drives strictness-based eager elision (a
//! first-demanded, forward-ref-free binding is evaluated straight into its
//! slot with no thunk).

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");
const attr_names = @import("attr_names.zig");
const access = @import("access.zig");
const strictness = @import("strictness.zig");
const refs_mod = @import("refs.zig");
const lambda = @import("lambda.zig");
const thunks = @import("thunks.zig");

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

    var plan = try LetPlan.init(self, let_in.bindings, let_in.body);
    defer plan.deinit(self.allocator);
    try declareBindingSlots(self, let_in.bindings, plan);

    // Hidden locals for `inherit (expr)` sources. They are declared after all
    // user bindings (so they cannot affect lexical resolution) and initialized
    // lazily at the first live member's source position in pass 2.
    var inherit_states: std.AutoHashMapUnmanaged(u32, InheritState) = .empty;
    defer inherit_states.deinit(self.allocator);
    try declareInheritSlots(self, let_in.bindings, plan.kinds, &inherit_states);
    try emitBindingInitializers(self, let_in.bindings, plan, &inherit_states);

    if (tail_body) {
        try lambda.compileTailExpression(self, let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    scope.endScope(self);
}

const LetBindingKind = enum { unreferenced, literal, uncaptured, needs_cell };
const InheritState = struct { slot: u16, initialized: bool = false };

/// Immutable analysis result consumed by the two bytecode-emission passes.
/// All arrays and the lookup map are region-local to one `let`.
const LetPlan = struct {
    kinds: []LetBindingKind,
    name_ids: []InternId,
    eager: []bool,
    must_force: []bool,
    earliest_index: std.AutoHashMapUnmanaged(InternId, usize),
    first_demanded: ?InternId,

    fn init(self: *Compiler, bindings: []const Node.Binding, body: *const Node) !LetPlan {
        const kinds = try classifyLetBindings(self, bindings, body);
        errdefer self.allocator.free(kinds);

        const name_ids = try self.allocator.alloc(InternId, bindings.len);
        errdefer self.allocator.free(name_ids);
        for (bindings, name_ids) |binding, *name_id| {
            name_id.* = try self.intern.intern(attr_names.span(self, binding.path[0]));
        }

        var earliest_index: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
        errdefer earliest_index.deinit(self.allocator);
        for (name_ids, 0..) |name_id, index| {
            if (!earliest_index.contains(name_id))
                try earliest_index.put(self.allocator, name_id, index);
        }

        const eager = try self.allocator.alloc(bool, bindings.len);
        errdefer self.allocator.free(eager);
        const must_force = try self.allocator.alloc(bool, bindings.len);
        errdefer self.allocator.free(must_force);
        try strictness.analyzeLetBindings(
            self.allocator,
            self.intern,
            self.source,
            body,
            name_ids,
            eager,
            must_force,
        );

        return .{
            .kinds = kinds,
            .name_ids = name_ids,
            .eager = eager,
            .must_force = must_force,
            .earliest_index = earliest_index,
            .first_demanded = try strictness.firstForcedName(self.intern, self.source, body),
        };
    }

    fn deinit(self: *LetPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.kinds);
        allocator.free(self.name_ids);
        allocator.free(self.eager);
        allocator.free(self.must_force);
        self.earliest_index.deinit(allocator);
    }
};

fn declareBindingSlots(self: *Compiler, bindings: []const Node.Binding, plan: LetPlan) !void {
    for (bindings, plan.kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, bindings[0..index], binding.path[0])) continue;
        if (kind == .unreferenced) continue;
        const name = attr_names.span(self, binding.path[0]);
        const name_id = plan.name_ids[index];
        const slot = try scope.declareLocal(self, name, name_id);
        switch (kind) {
            .literal => {
                const leaf = singleLeafBinding(self, bindings, binding.path[0]).?;
                self.armRecursiveName(name_id);
                try access.compileContainerValue(self, leaf.expr, .{});
                try emit.emitSetLocal(self, slot);
            },
            .uncaptured => {},
            .needs_cell => try emit.emitInitCellSlot(self, slot),
            .unreferenced => unreachable,
        }
    }
}

fn declareInheritSlots(
    self: *Compiler,
    bindings: []const Node.Binding,
    kinds: []const LetBindingKind,
    states: *std.AutoHashMapUnmanaged(u32, InheritState),
) !void {
    const inherit_name = "\x00inherit-source";
    const inherit_name_id = try self.intern.intern(inherit_name);
    for (bindings, kinds) |binding, kind| {
        if (binding.inherit_group == 0 or kind == .unreferenced or states.contains(binding.inherit_group)) continue;
        try states.put(self.allocator, binding.inherit_group, .{
            .slot = try scope.declareLocal(self, inherit_name, inherit_name_id),
        });
    }
}

fn emitBindingInitializers(
    self: *Compiler,
    bindings: []const Node.Binding,
    plan: LetPlan,
    inherit_states: *std.AutoHashMapUnmanaged(u32, InheritState),
) !void {
    for (bindings, plan.kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, bindings[0..index], binding.path[0])) continue;
        if (kind == .literal or kind == .unreferenced) continue;
        const name = attr_names.span(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;

        if (binding.inherit_group == 0 and kind == .uncaptured and plan.must_force[index] and
            plan.first_demanded != null and plan.name_ids[index] == plan.first_demanded.?)
        {
            if (eligibleEagerLeaf(self, bindings, binding.path[0], &plan.earliest_index, index)) |leaf| {
                self.armRecursiveName(plan.name_ids[index]);
                try self.compileNode(leaf.expr);
                self.name_hint = null;
                try emit.emitSetLocal(self, slot);
                continue;
            }
        }

        var inherit_source_slot: ?u16 = null;
        if (binding.inherit_group != 0) {
            const state = inherit_states.getPtr(binding.inherit_group) orelse return error.InvalidAttributePath;
            if (!state.initialized) {
                const inherited = ast.unwrapParens(binding.expr);
                if (inherited.tag != .attr_path or inherited.data.attr_path.segments.len != 1)
                    return error.InvalidAttributePath;
                try thunks.compileThunk(self, inherited.data.attr_path.root);
                try emit.emitSetLocal(self, state.slot);
                state.initialized = true;
            }
            inherit_source_slot = state.slot;
        }

        self.armRecursiveName(plan.name_ids[index]);
        try compileLetRootBinding(self, bindings, binding.path[0], slot, plan.eager[index], inherit_source_slot);
        switch (kind) {
            .needs_cell => try emit.emitSetCellLocal(self, slot),
            .uncaptured => try emit.emitSetLocal(self, slot),
            .literal, .unreferenced => unreachable,
        }
    }
}

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
        const name = attr_names.span(self, binding.path[0]);
        const gop = slots.getOrPutAssumeCapacity(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = slot_count;
            slot_count += 1;
        }
    }

    // First binding index per slot: all members of a merged dotted group
    // (`a.x = …; a.y = …`) are compiled together at the group's first
    // index, so their RHS references must be credited to that index.
    const slot_first = try self.allocator.alloc(u32, slot_count);
    defer self.allocator.free(slot_first);
    @memset(slot_first, std.math.maxInt(u32));
    for (bindings, 0..) |binding, i| {
        const slot = slots.get(attr_names.span(self, binding.path[0])).?;
        if (slot_first[slot] == std.math.maxInt(u32)) slot_first[slot] = @intCast(i);
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
    for (bindings) |binding| {
        if (binding.path.len > 1) {
            // Nested-path bindings synthesise an attr-set thunk
            // whose captures we don't statically track; conservative:
            // any such binding "references" every other.
            any_path_nested = true;
        }
        rhs_marker.stamp += 1;
        rhs_marker.index = slot_first[slots.get(attr_names.span(self, binding.path[0])).?];
        refs_mod.walkReferencedNames(self, binding.expr, &rhs_marker);
    }

    for (bindings, 0..) |binding, i| {
        if (bindingRootSeen(self, bindings[0..i], binding.path[0])) {
            kinds[i] = .needs_cell;
            continue;
        }
        const name = attr_names.span(self, binding.path[0]);
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
/// `stamp_seen` deduplicates within one region, so repeated mentions in the
/// same RHS count once.
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
        // Regions are visited in binding order but carry their group's first
        // index, which is not monotone — keep the minimum, not the first seen.
        if (self.counts[slot] == 1 or self.index < self.first[slot]) self.first[slot] = self.index;
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
        if (!attr_names.equal(self, binding.path[0], root)) continue;
        if (binding.path.len != 1) return null;
        if (binding.inherit_outer) return null;
        if (found != null) return null;
        found = binding;
    }
    return found;
}

fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom, slot: u16, eager: bool, inherit_source_slot: ?u16) !void {
    var leaf: ?Node.Binding = null;
    var tail_count: usize = 0;

    for (bindings) |binding| {
        if (!attr_names.equal(self, binding.path[0], root)) continue;
        if (binding.path.len == 1) {
            if (leaf) |previous| {
                const span = self.source[binding.name_offset .. binding.name_offset + binding.name_len];
                const message = try std.fmt.allocPrint(self.allocator, "variable '{s}' already defined", .{span});
                try self.owned_diagnostic_messages.append(self.allocator, message);
                try diagnostics.reportCompileError(self, binding.name_offset, binding.name_len, message);
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
        if (inherit_source_slot) |source_slot| {
            try emit.emitThunkAttr(self, .{
                .name = "\x00inherit-source",
                .name_id = try self.intern.intern("\x00inherit-source"),
                .kind = .local,
                .index = source_slot,
            }, try attr_names.intern(self, binding.path[0]));
            return;
        }
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
        if (!attr_names.equal(self, binding.path[0], root) or binding.path.len == 1) continue;
        tails[i] = .{
            .path = binding.path[1..],
            .expr = binding.expr,
            .inherit_outer = binding.inherit_outer,
            .inherit_group = binding.inherit_group,
        };
        i += 1;
    }

    if (leaf) |root_leaf| {
        if (root_leaf.expr.tag != .attr_set) {
            try diagnostics.reportDuplicateAttribute(self, tails[0].path[0], root_leaf.path[0]);
            return error.DuplicateAttribute;
        }
        const leaves = [_]AttrEntryView{.{
            .path = root_leaf.path,
            .expr = root_leaf.expr,
            .inherit_outer = root_leaf.inherit_outer,
            .inherit_group = root_leaf.inherit_group,
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
        if (binding.path.len > 0 and attr_names.equal(self, binding.path[0], root)) return true;
    }
    return false;
}
