//! Rewrite-policy planning over immutable let analysis.

const std = @import("std");
const compiler_mod = @import("../context.zig");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const analysis = @import("../let_analysis/model.zig");
const model = @import("model.zig");
const access = @import("../access.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const InternId = types.InternId;
const BindingId = analysis.BindingId;
const invalid_binding = analysis.invalid_binding;

fn bump(census: ?*model.Stats, comptime field: []const u8) void {
    if (census) |stats| _ = @field(stats, field).fetchAdd(1, .monotonic);
}

fn bumpBy(census: ?*model.Stats, comptime field: []const u8, n: u64) void {
    if (n != 0) {
        if (census) |stats| _ = @field(stats, field).fetchAdd(n, .monotonic);
    }
}

fn rootAstArena(self: *Compiler) ?*ast.AstArena {
    var compiler: *Compiler = self;
    while (compiler.parent) |parent| compiler = parent;
    return compiler.ast_arena;
}

pub fn decide(
    self: *Compiler,
    graph: *const analysis.Graph,
    let_bindings: []const Node.Binding,
    census: ?*model.Stats,
) !model.Plan {
    const allocator = self.allocator;
    const n = graph.bindings.len;

    const alive = try computeLiveness(allocator, graph);
    const keep = try allocator.alloc(bool, n);
    // A binding whose keep=false AND rhs_gone: its RHS never compiles
    // (dead / fully inlined). Sunk and floated bindings also drop from the
    // residual let, but their RHS lives on at the new site, so uses inside
    // it still count.
    const rhs_gone = try allocator.alloc(bool, n);
    @memset(rhs_gone, false);
    var replacements: std.AutoHashMapUnmanaged(*const Node, *const Node) = .empty;
    var wraps: std.AutoHashMapUnmanaged(*const Node, std.ArrayListUnmanaged(Node.Binding)) = .empty;
    var any_change = false;

    // Alias collapse appends transferred target uses to planner-local state;
    // the analysis graph remains an immutable snapshot.
    var uses: std.ArrayListUnmanaged(analysis.Use) = .empty;
    try uses.appendSlice(allocator, graph.uses);
    var consumed: std.ArrayListUnmanaged(bool) = .empty;
    try consumed.appendNTimes(allocator, false, uses.items.len);

    // Rewrites can change a containing RHS's effective free-name set. Keep
    // those derived facts beside the plan instead of mutating analysis.
    const facts = try allocator.alloc(PlannerFacts, n);
    @memset(facts, .{});

    // Per-binding use-index lists: both passes visit exactly one binding's
    // uses at a time, and generated lets are large — a scan of ALL uses per
    // binding is quadratic.
    const use_lists = try allocator.alloc(std.ArrayListUnmanaged(u32), n);
    @memset(use_lists, .empty);
    for (graph.bindings, 0..) |_, binding| {
        try use_lists[binding].appendSlice(allocator, graph.useIndices(@intCast(binding)));
    }

    for (graph.bindings, 0..) |*binding, i| {
        keep[i] = true;
        if (!alive[i]) {
            switch (binding.kind) {
                .plain, .inherit_member, .inherit_outer => {
                    keep[i] = false;
                    rhs_gone[i] = true;
                    any_change = true;
                    bump(census, "dropped_dead");
                },
                // Dotted groups always compile (their merge/duplicate
                // diagnostics are load-bearing), matching today's behavior.
                .dotted => {},
            }
        }
    }

    // Ascending SCC index = dependencies before dependents (see
    // `let_analysis.computeSccs`), so a binding sunk into a sibling's RHS has its
    // free names folded into that sibling before the sibling is decided.
    const order = try sccOrder(allocator, graph);

    // ---- Pass A: duplicable inlines (literals and aliases). -------------
    // These replace every rewritable use with a FRESH copy of the RHS; an
    // alias collapse transfers the redirected sites to its target as
    // synthetic use records so pass B decides the target over its true,
    // post-collapse use set.
    for (order) |i| {
        const binding = &graph.bindings[i];
        if (!keep[i] or !alive[i]) continue;
        if (binding.kind != .plain) continue;
        if (binding.scc_recursive) {
            bump(census, "blocked_recursive");
            continue;
        }
        const leaf = binding.leaf.?;
        // A leaf that already received a replacement (an earlier inline into
        // it) is examined through its rewritten shape.
        const shape = ast.unwrapParens(effectiveNode(&replacements, leaf));

        const is_literal = access.isLiteralContainerValue(self, shape);
        const is_alias = !is_literal and shape.tag == .identifier and
            !hasOpaque(binding, facts[i]);
        if (!is_literal and !is_alias) continue;

        const target_id: InternId = if (is_alias)
            try self.intern.intern(self.source[shape.data.atom.offset .. shape.data.atom.offset + shape.data.atom.len])
        else
            0;
        const target_binding: ?BindingId = if (is_alias) graph.findBinding(target_id) else null;

        var replaced: u32 = 0;
        var total: u32 = 0;
        var transfers: std.ArrayListUnmanaged(analysis.Use) = .empty;
        defer transfers.deinit(allocator);
        for (use_lists[i].items) |ui| {
            const use = uses.items[ui];
            if (consumed.items[ui]) continue;
            if (use.in_rhs_of != invalid_binding and rhs_gone[use.in_rhs_of]) continue;
            total += 1;
            if (use.pinned or use.site == null) continue;
            if (is_alias and graph.shadowedAt(target_id, use.shadow_mark)) {
                bump(census, "blocked_shadow");
                continue;
            }
            // A dynamically-resolved target (`with`-scope name) reads the
            // same value only under an identical with-chain: the window to
            // the site must cross no `with` body.
            if (is_alias and hasDynamicFree(binding, facts[i]) and graph.withCrossedAt(use.shadow_mark)) {
                bump(census, "blocked_dynamic");
                continue;
            }
            const fresh = try freshCopy(self, use.site.?, shape);
            try replacements.put(allocator, use.site.?, fresh);
            consumed.items[ui] = true;
            replaced += 1;
            // The inlined identifier becomes part of the containing RHS: its
            // TARGET name joins that binding's free set, so a later sink or
            // float of that sibling shadow-checks the effective (rewritten)
            // expression, not just the names it was originally written with.
            if (is_alias and use.in_rhs_of != invalid_binding) {
                try addPlannerFree(allocator, &facts[use.in_rhs_of], &graph.bindings[use.in_rhs_of], .{
                    .id = target_id,
                    .class = if (target_binding != null) .cluster else .lexical,
                    .binding = target_binding orelse invalid_binding,
                });
            }
            if (target_binding != null) {
                var transferred = use;
                transferred.binding = target_binding.?;
                transferred.site = fresh;
                transferred.pinned = false;
                try transfers.append(allocator, transferred);
            }
        }
        for (transfers.items) |transferred| {
            try use_lists[transferred.binding].append(allocator, @intCast(uses.items.len));
            try uses.append(allocator, transferred);
            try consumed.append(allocator, false);
        }

        if (is_literal)
            bumpBy(census, "inlined_literal_uses", replaced)
        else
            bumpBy(census, "inlined_alias_uses", replaced);
        if (replaced != 0) any_change = true;
        if (replaced == total and total != 0) {
            keep[i] = false;
            rhs_gone[i] = true;
            bump(census, "inlined_bindings");
            // The alias's own RHS (a bare identifier read) disappears with
            // it; its use record of the target is inside this RHS and is
            // filtered by `rhs_gone`.
        }
    }

    // ---- Pass B: single-use sinking, then branch-local floating. --------
    for (order) |i| {
        const binding = &graph.bindings[i];
        if (!keep[i] or !alive[i]) continue;
        if (binding.kind != .plain) continue;
        if (binding.scc_recursive) continue;
        // Elided (never-parsed) spans stay put; dynamic free names gate
        // per destination below (movement is fine while the with-chain is
        // unchanged between header and site).
        if (hasOpaque(binding, facts[i])) {
            bump(census, "blocked_dynamic");
            continue;
        }
        const leaf = binding.leaf.?;
        const shape = ast.unwrapParens(effectiveNode(&replacements, leaf));
        const is_lambda = shape.tag == .lambda or shape.tag == .lambda_attrs;

        // Collect the binding's live use records.
        var live: std.ArrayListUnmanaged(analysis.Use) = .empty;
        defer live.deinit(allocator);
        for (use_lists[i].items) |ui| {
            const use = uses.items[ui];
            if (consumed.items[ui]) continue;
            if (use.in_rhs_of != invalid_binding and rhs_gone[use.in_rhs_of]) continue;
            try live.append(allocator, use);
        }
        if (live.items.len == 0) continue;

        // Single-use sinking. Lambda-valued bindings stay put: the
        // runtime-adaptive call path already eagerizes their call sites, so
        // sinking gains almost nothing — and it would erase the binding's
        // qualified chunk name, which error traces attribute frames by.
        if (live.items.len == 1 and !is_lambda) sink: {
            const use = live.items[0];
            if (use.pinned or use.site == null) {
                bump(census, "blocked_pinned");
                break :sink;
            }
            if (use.mult == .many) {
                bump(census, "blocked_many");
                break :sink;
            }
            if (anyFreeShadowedAt(graph, binding, facts[i], use.shadow_mark)) {
                bump(census, "blocked_shadow");
                break :sink;
            }
            if (hasDynamicFree(binding, facts[i]) and graph.withCrossedAt(use.shadow_mark)) {
                bump(census, "blocked_dynamic");
                break :sink;
            }
            try replacements.put(allocator, use.site.?, leaf);
            keep[i] = false;
            any_change = true;
            bump(census, "sunk_single_use");
            // The RHS now lives inside the owner's region: fold its free
            // names into the owner so a later sink of the owner checks them.
            if (use.in_rhs_of != invalid_binding) {
                const owner_facts = &facts[use.in_rhs_of];
                const owner = &graph.bindings[use.in_rhs_of];
                for (binding.free.items) |f| try addPlannerFree(allocator, owner_facts, owner, f);
                for (facts[i].extra_free.items) |f| try addPlannerFree(allocator, owner_facts, owner, f);
                owner_facts.has_opaque = owner_facts.has_opaque or hasOpaque(binding, facts[i]);
            }
            continue;
        }

        // Branch-local floating: every live use under one if-branch (wrap
        // that branch in a synthetic let), or split exactly across the two
        // branches of one if (clone the wrap into both — dynamically
        // exclusive, so evaluation is never duplicated; code is, hence the
        // size gate). Lambda RHSes are fine here: the wrap is a real named
        // binding, so qualified chunk names survive.
        const targets = try floatTargets(allocator, graph, live.items) orelse continue;
        var ok = true;
        for (targets.branches) |branch_id| {
            const branch = graph.tables.branches.items[branch_id];
            if (graph.branchMult(branch) == .many) {
                bump(census, "blocked_many");
                ok = false;
                break;
            }
            if (anyFreeShadowedAt(graph, binding, facts[i], branch.shadow_mark)) {
                bump(census, "blocked_shadow");
                ok = false;
                break;
            }
            if (hasDynamicFree(binding, facts[i]) and graph.withCrossedAt(branch.shadow_mark)) {
                bump(census, "blocked_dynamic");
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        if (targets.branches.len > 1) {
            const span_len = if (leaf.span) |s| s.len else clone_max_bytes + 1;
            if (span_len > clone_max_bytes) continue;
        }
        for (targets.branches) |branch_id| {
            const branch = graph.tables.branches.items[branch_id];
            const gop = try wraps.getOrPut(allocator, branch.node);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, let_bindings[binding.first_index]);
        }
        keep[i] = false;
        any_change = true;
        if (targets.branches.len > 1)
            bump(census, "floated_cloned")
        else
            bump(census, "floated_branch");
    }

    return .{ .keep = keep, .replacements = replacements, .wraps = wraps, .any_change = any_change };
}

/// Source-size ceiling for cloning a binding's RHS into both arms of an if.
const clone_max_bytes: u32 = 160;

const PlannerFacts = struct {
    extra_free: std.ArrayListUnmanaged(analysis.FreeName) = .empty,
    has_dynamic_free: bool = false,
    has_opaque: bool = false,
};

fn addPlannerFree(
    allocator: std.mem.Allocator,
    facts: *PlannerFacts,
    binding: *const analysis.Binding,
    name: analysis.FreeName,
) !void {
    for (binding.free.items) |existing| {
        if (existing.id == name.id) return;
    }
    for (facts.extra_free.items) |existing| {
        if (existing.id == name.id) return;
    }
    try facts.extra_free.append(allocator, name);
    if (name.class == .dynamic) facts.has_dynamic_free = true;
}

fn hasDynamicFree(binding: *const analysis.Binding, facts: PlannerFacts) bool {
    return binding.has_dynamic_free or facts.has_dynamic_free;
}

fn hasOpaque(binding: *const analysis.Binding, facts: PlannerFacts) bool {
    return binding.has_opaque or facts.has_opaque;
}

fn anyFreeShadowedAt(
    graph: *const analysis.Graph,
    binding: *const analysis.Binding,
    facts: PlannerFacts,
    mark: u32,
) bool {
    for (binding.free.items) |f| {
        if (graph.shadowedAt(f.id, mark)) return true;
    }
    for (facts.extra_free.items) |f| {
        if (graph.shadowedAt(f.id, mark)) return true;
    }
    return false;
}

const FloatTargets = struct { branches: []const u32 };

/// The wrap target(s) for a multi-use float: the deepest branch common to
/// all live uses, or — when the chains diverge exactly at one `if` with
/// every use inside one of its two branches — both branches of that if.
/// Null when some use lies outside any common branch.
fn floatTargets(
    allocator: std.mem.Allocator,
    graph: *const analysis.Graph,
    live: []const analysis.Use,
) !?FloatTargets {
    std.debug.assert(live.len > 0);
    if (live[0].branch == analysis.invalid_branch) return null;
    var common = try graph.branchChain(allocator, live[0].branch);
    for (live[1..]) |use| {
        if (use.branch == analysis.invalid_branch) return null;
        const chain = try graph.branchChain(allocator, use.branch);
        defer allocator.free(chain);
        var k: usize = 0;
        while (k < common.len and k < chain.len and common[k] == chain[k]) : (k += 1) {}
        common = common[0..k];
    }
    if (common.len > 0) {
        const branches = try allocator.alloc(u32, 1);
        branches[0] = common[common.len - 1];
        return .{ .branches = branches };
    }

    // No common branch: try the clone case — every chain must start at one
    // of the two branches of a single if node.
    var then_branch: ?u32 = null;
    var else_branch: ?u32 = null;
    var if_node: ?*const Node = null;
    for (live) |use| {
        const chain = try graph.branchChain(allocator, use.branch);
        defer allocator.free(chain);
        if (chain.len == 0) return null;
        const top = graph.tables.branches.items[chain[0]];
        if (if_node == null) if_node = top.if_node;
        if (top.if_node != if_node.?) return null;
        if (top.is_then) then_branch = chain[0] else else_branch = chain[0];
    }
    if (then_branch == null or else_branch == null) return null;
    const branches = try allocator.alloc(u32, 2);
    branches[0] = then_branch.?;
    branches[1] = else_branch.?;
    return .{ .branches = branches };
}

/// Group-aware liveness fixpoint: a binding is live when the body (or a
/// pinned mention in a live region) reaches it through live sibling RHSes.
/// Inherit clauses count as one unit — the shared source expression is
/// walked once but keeps its names alive for every member of the clause.
fn computeLiveness(allocator: std.mem.Allocator, graph: *const analysis.Graph) ![]bool {
    const n = graph.bindings.len;
    const alive = try allocator.alloc(bool, n);
    @memset(alive, false);

    const activated = try allocator.alloc(bool, n);
    @memset(activated, false);
    var work: std.ArrayListUnmanaged(BindingId) = .empty;
    for (graph.root_dependencies) |binding| {
        if (alive[binding]) continue;
        alive[binding] = true;
        try work.append(allocator, binding);
    }

    var next: usize = 0;
    while (next < work.items.len) : (next += 1) {
        const owner = graph.ownerFor(work.items[next]);
        if (activated[owner]) continue;
        activated[owner] = true;
        for (graph.dependencies(owner)) |binding| {
            if (alive[binding]) continue;
            alive[binding] = true;
            try work.append(allocator, binding);
        }
    }
    return alive;
}

/// Binding indices in ascending SCC order (stable within an SCC).
fn sccOrder(allocator: std.mem.Allocator, graph: *const analysis.Graph) ![]u32 {
    const order = try allocator.alloc(u32, graph.bindings.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, graph, struct {
        fn lessThan(g: *const analysis.Graph, a: u32, b: u32) bool {
            if (g.bindings[a].scc != g.bindings[b].scc)
                return g.bindings[a].scc < g.bindings[b].scc;
            return a < b;
        }
    }.lessThan);
    return order;
}

fn effectiveNode(
    replacements: *const std.AutoHashMapUnmanaged(*const Node, *const Node),
    node: *const Node,
) *const Node {
    var cur = node;
    while (replacements.get(cur)) |r| cur = r;
    return cur;
}

/// A fresh shallow copy of a duplicable replacement (identifier/literal
/// atom), one per site: replacement subtrees must stay pointer-unique so a
/// nested let's node-keyed decisions never conflate two occurrences. The
/// copy keeps the ORIGINAL use site's span, so stack traces and the
/// debugger still point at the place the value is consumed.
fn freshCopy(self: *Compiler, site: *const Node, template: *const Node) !*const Node {
    const arena = rootAstArena(self).?;
    const node = try arena.createNode(template.tag, template.data);
    node.span = site.span;
    return node;
}
