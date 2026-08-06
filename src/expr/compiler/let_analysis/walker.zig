//! Single-pass builder for immutable let-cluster analysis.

const std = @import("std");
const compiler_mod = @import("../context.zig");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const builtins = @import("runtime").builtins;
const scope = @import("../scope.zig");
const fold = @import("../fold.zig");
const attr_names = @import("../attr_names.zig");
const model = @import("model.zig");
const finalize = @import("finalize.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const InternId = types.InternId;
const BindingId = model.BindingId;
const invalid_binding = model.invalid_binding;
const invalid_branch = model.invalid_branch;
const invalid_cluster = model.invalid_cluster;
const Mult = model.Mult;
const NameClass = model.NameClass;
const FreeName = model.FreeName;
const Use = model.Use;
const Binding = model.Binding;
const BindingKind = model.BindingKind;
const Graph = model.Graph;
const Cluster = model.Cluster;
const UnitAnalysis = model.UnitAnalysis;

/// Analyze `root`'s whole subtree, registering a cluster for every `let`
/// found (unit entry — called once per compile unit before emission, and
/// again as a per-let fallback for AST created after that pass: materialized
/// elided bodies, interpolation sub-parses, rebuilt residual subtrees).
pub fn analyze(self: *Compiler, ua: *UnitAnalysis, root: *const Node) !void {
    // Walk-local cluster ids restart at 0 per walk; the decide-all pass
    // consumes `walk_clusters` right after this returns, so the previous
    // walk's list is dead by now.
    ua.walk_clusters.clearRetainingCapacity();
    var walker = Walker{ .c = self, .ua = ua };
    defer walker.deinit();
    try walker.walk(root);
}

const Binder = struct {
    name_id: InternId,
    /// Lévy level of this binder: lambda params carry their lambda's
    /// introduced level; let/rec binders sit AT the current level.
    level: u16 = 0,
    /// Owning cluster id and binding id when this is a cluster binder.
    cluster: u32 = invalid_cluster,
    /// Index into the walker's `active` list while the cluster is open —
    /// O(1) owner lookup (a live binder's cluster is always active, and its
    /// position in the active stack is fixed for the cluster's lifetime).
    active_index: u32 = 0,
    binding: BindingId = invalid_binding,
    /// Previous stack index of a binder with the same name (shadow chain),
    /// or maxInt — resolution is O(1) via `by_name`.
    prev_same_name: usize = std.math.maxInt(usize),
};

/// Per-active-cluster walk state.
const ClusterCtx = struct {
    cluster: *Cluster,
    id: u32,
    /// Which binding's RHS is being walked (`invalid_binding` = body/none).
    cur_rhs: BindingId = invalid_binding,
    /// Stack length when the current RHS region began: binders at lower
    /// positions are OUTSIDE the moving subtree, hence free names of it.
    rhs_start_stack: usize = 0,
    /// Inherit groups whose shared source expression was already walked.
    /// Lazily used — only touched when a level has inherit-from entries.
    inherit_walked: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Mutable walk builder; frozen into `Graph.uses` when the cluster closes.
    uses: std.ArrayListUnmanaged(Use) = .empty,
};

pub const Walker = struct {
    c: *Compiler,
    ua: *UnitAnalysis,
    stack: std.ArrayListUnmanaged(Binder) = .empty,
    /// Innermost binder stack index per name (O(1) resolution).
    by_name: std.AutoHashMapUnmanaged(InternId, usize) = .empty,
    active: std.ArrayListUnmanaged(ClusterCtx) = .empty,
    /// Stack indices to ignore while resolving (`inherit`-outer skip-slot);
    /// almost always empty, nests only through inherit-in-inherit RHSes.
    skips: std.ArrayListUnmanaged(usize) = .empty,
    next_cluster_id: u32 = 0,
    once_depth: u32 = 0,
    many_depth: u32 = 0,
    cur_branch: u32 = invalid_branch,
    /// Innermost enclosing lambda (index into `tables.lambdas`), tracked
    /// only under the full-lazy gate.
    cur_lambda: u32 = model.invalid_lambda,

    fn deinit(self: *Walker) void {
        self.stack.deinit(self.c.allocator);
        self.by_name.deinit(self.c.allocator);
        self.active.deinit(self.c.allocator);
        self.skips.deinit(self.c.allocator);
    }

    fn pushBinder(self: *Walker, name_id: InternId, cluster: u32, active_index: u32, binding: BindingId) !void {
        return self.pushBinderAt(name_id, cluster, active_index, binding, @intCast(self.many_depth));
    }

    fn pushBinderAt(self: *Walker, name_id: InternId, cluster: u32, active_index: u32, binding: BindingId, level: u16) !void {
        const allocator = self.c.allocator;
        const gop = try self.by_name.getOrPut(allocator, name_id);
        const prev = if (gop.found_existing) gop.value_ptr.* else std.math.maxInt(usize);
        gop.value_ptr.* = self.stack.items.len;
        try self.stack.append(allocator, .{
            .name_id = name_id,
            .level = level,
            .cluster = cluster,
            .active_index = active_index,
            .binding = binding,
            .prev_same_name = prev,
        });
        // The log only feeds cluster shadow windows: binders pushed while no
        // cluster is active sit before every window and are never queried.
        if (self.active.items.len != 0 or cluster != invalid_cluster) {
            try self.ua.tables.logBinder(name_id, cluster);
        }
    }

    fn popBinders(self: *Walker, to_len: usize) void {
        while (self.stack.items.len > to_len) {
            const binder = self.stack.pop().?;
            if (binder.prev_same_name == std.math.maxInt(usize)) {
                _ = self.by_name.remove(binder.name_id);
            } else {
                self.by_name.putAssumeCapacity(binder.name_id, binder.prev_same_name);
            }
        }
    }

    fn internSpan(self: *Walker, atom: Node.Atom) !InternId {
        return self.c.intern.intern(self.c.source[atom.offset .. atom.offset + atom.len]);
    }

    fn curMultFor(self: *const Walker, graph: *const Graph) Mult {
        if (self.many_depth > graph.header_many) return .many;
        if (self.once_depth > graph.header_once) return .once;
        return .same;
    }

    /// Add `name` to the free set of every active cluster whose current RHS
    /// region encloses the mention. `binder_pos` is the resolved binder's
    /// stack index (or null when the name resolved outside the walk).
    fn attributeFree(self: *Walker, name_id: InternId, binder_pos: ?usize, class_hint: ?NameClass) !void {
        var outer_class: ?NameClass = class_hint;
        for (self.active.items) |*ctx| {
            if (ctx.cur_rhs == invalid_binding) continue;
            if (binder_pos) |pos| {
                if (pos >= ctx.rhs_start_stack) continue; // RHS-internal binder
            }
            const binder = if (binder_pos) |pos| self.stack.items[pos] else null;
            const entry: FreeName = if (binder != null and binder.?.cluster == ctx.id)
                .{ .id = name_id, .class = .cluster, .binding = binder.?.binding, .level = binder.?.level }
            else if (binder != null)
                // A cluster binder of an ENCLOSING cluster keeps its source
                // link (walk-local); plain binders (params, rec-attr names)
                // stay unlinked.
                .{
                    .id = name_id,
                    .class = .lexical,
                    .binding = binder.?.binding,
                    .src_cluster = binder.?.cluster,
                    .level = binder.?.level,
                }
            else blk: {
                if (outer_class == null) outer_class = classifyOuterName(self.c, name_id);
                break :blk .{ .id = name_id, .class = outer_class.? };
            };
            try ctx.cluster.graph.bindings[ctx.cur_rhs].addFree(self.c.allocator, entry);
        }
    }

    /// Resolve one name mention: record a use for the cluster binding it
    /// reaches (if any) and contribute to enclosing RHS free sets.
    /// `static_fallback` marks synthetic words with a position-independent
    /// fallback when unresolved (operator-overload hooks like `__mul`, which
    /// lower to the plain VM op, and `__nixPath` → `builtins.nixPath`): they
    /// classify `.builtin` instead of `.dynamic`, staying movable while the
    /// shadow check still guards against crossing a binder that introduces
    /// the hook.
    fn refName(self: *Walker, name_id: InternId, site: ?*const Node, pinned: bool, static_fallback: bool) !void {
        var found: ?usize = self.by_name.get(name_id);
        // `inherit`-outer skip-slot: resolution skips the binding's own
        // binder. Skips are rare; the stack is almost always empty.
        while (found != null and self.skips.items.len != 0) {
            var skipped = false;
            for (self.skips.items) |skip| {
                if (skip == found.?) {
                    const prev = self.stack.items[found.?].prev_same_name;
                    found = if (prev == std.math.maxInt(usize)) null else prev;
                    skipped = true;
                    break;
                }
            }
            if (!skipped) break;
        }

        if (found) |pos| {
            const binder = self.stack.items[pos];
            if (binder.cluster != invalid_cluster) {
                // A use of some active cluster's binding.
                const ctx = &self.active.items[binder.active_index];
                const graph = &ctx.cluster.graph;
                const b = &graph.bindings[binder.binding];
                b.use_count += 1;
                if (ctx.cur_rhs == invalid_binding) b.body_use_count += 1;
                if (pinned) b.pinned_use = true;
                if (ctx.cur_rhs == binder.binding) b.self_ref = true;
                try ctx.uses.append(self.c.allocator, .{
                    .binding = binder.binding,
                    .site = if (pinned) null else site,
                    .mult = self.curMultFor(graph),
                    .shadow_mark = self.ua.tables.log_len,
                    .in_rhs_of = ctx.cur_rhs,
                    .branch = self.cur_branch,
                    .pinned = pinned,
                });
            }
            try self.attributeFree(name_id, pos, null);
            return;
        }
        // Free of the walk entirely: classify once, attribute everywhere.
        var class = classifyOuterName(self.c, name_id);
        if (class == .dynamic and static_fallback) class = .builtin;
        try self.attributeFree(name_id, null, class);
    }

    fn refWord(self: *Walker, word: []const u8) !void {
        try self.refName(try self.c.intern.intern(word), null, true, false);
    }

    fn refSpecialWord(self: *Walker, word: []const u8) !void {
        try self.refName(try self.c.intern.intern(word), null, true, true);
    }

    /// Mirror of `refs.zig walkIdentifiersInSpan`: mentions inside `${…}`
    /// interpolation are conservative words — real uses, unrewritable sites.
    fn wordsInSpan(self: *Walker, atom: Node.Atom) !void {
        const text = self.c.source[atom.offset .. atom.offset + atom.len];
        if (std.mem.indexOf(u8, text, "${") == null) return;
        try self.markIdentWords(text);
    }

    fn markIdentWords(self: *Walker, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            if (isIdentStart(text[i])) {
                const start = i;
                while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
                try self.refWord(text[start..i]);
            } else {
                i += 1;
            }
        }
    }

    /// Resolve `name_id` skipping the innermost binder of that exact name
    /// (`inherit x;` in rec attrsets / nested lets), as a pinned mention.
    fn refPastInnermost(self: *Walker, name_id: InternId) !void {
        const innermost = self.by_name.get(name_id) orelse return;
        const prev = self.stack.items[innermost].prev_same_name;
        if (prev == std.math.maxInt(usize)) return;
        const binder = self.stack.items[prev];
        if (binder.cluster == invalid_cluster) return; // plain inner binder
        const ctx = &self.active.items[binder.active_index];
        const graph = &ctx.cluster.graph;
        const b = &graph.bindings[binder.binding];
        b.use_count += 1;
        if (ctx.cur_rhs == invalid_binding) b.body_use_count += 1;
        b.pinned_use = true;
        try ctx.uses.append(self.c.allocator, .{
            .binding = binder.binding,
            .site = null,
            .mult = self.curMultFor(graph),
            .shadow_mark = self.ua.tables.log_len,
            .in_rhs_of = ctx.cur_rhs,
            .branch = self.cur_branch,
            .pinned = true,
        });
    }

    fn walk(self: *Walker, node: *const Node) anyerror!void {
        switch (node.tag) {
            .integer, .float_val, .bool_true, .bool_false, .null, .uri => {},
            // `<name>` desugars through the `__nixPath` identifier.
            .search_path => try self.refSpecialWord("__nixPath"),
            .string, .path => try self.wordsInSpan(node.data.atom),
            .elided => {
                // Never parsed: every ident-shaped word is a conservative,
                // pinned mention, and every enclosing RHS is opaque.
                for (self.active.items) |*ctx| {
                    if (ctx.cur_rhs != invalid_binding)
                        ctx.cluster.graph.bindings[ctx.cur_rhs].has_opaque = true;
                }
                const atom = node.data.atom;
                try self.markIdentWords(self.c.source[atom.offset .. atom.offset + atom.len]);
            },
            .identifier => {
                const atom = node.data.atom;
                // `__curPos` is intercepted by `compileIdent` BEFORE local
                // resolution: it never reads a binding, even one spelled
                // `__curPos` (matching Nix, where it is a parse-time form).
                const text = self.c.source[atom.offset .. atom.offset + atom.len];
                if (std.mem.eql(u8, text, "__curPos")) return;
                try self.refName(try self.c.intern.intern(text), node, false, false);
            },
            .unary_op => {
                // `-e` lowers to `__sub 0 e` when a lexical `__sub` exists.
                if (node.data.unary.op == .negate) try self.refSpecialWord("__sub");
                try self.walk(node.data.unary.expr);
            },
            .binary_op => {
                const b = node.data.binary;
                if (fold.overloadNameForBinary(b.op)) |name| try self.refSpecialWord(name);
                try self.walk(b.left);
                // Short-circuit RHS still runs at most once → same region.
                try self.walk(b.right);
            },
            .apply => {
                try self.walk(node.data.apply.func);
                // Argument positions are runtime-adaptive/lazy thunks.
                self.once_depth += 1;
                try self.walk(node.data.apply.arg);
                self.once_depth -= 1;
            },
            .lambda => {
                const start = self.stack.items.len;
                const lam = node.data.lambda;
                const introduced: u16 = @intCast(self.many_depth + 1);
                try self.pushBinderAt(try self.c.intern.intern(
                    self.c.source[lam.param_offset .. lam.param_offset + lam.param_len],
                ), invalid_cluster, 0, invalid_binding, introduced);
                const saved_lambda = self.cur_lambda;
                if (self.c.let_float.full_lazy) {
                    try self.ua.walked.put(self.ua.allocator, node, {});
                    // Chain membership: a value lambda directly under a
                    // value lambda (post-paren) uncurries into one chunk.
                    const chain = saved_lambda != model.invalid_lambda and blk: {
                        const p = self.ua.tables.lambdas.items[saved_lambda].node;
                        break :blk p.tag == .lambda and ast.unwrapParens(p.data.lambda.body) == node;
                    };
                    try self.ua.tables.lambdas.append(self.c.allocator, .{
                        .node = node,
                        .parent = saved_lambda,
                        .level = introduced,
                        .entry_mark = self.ua.tables.log_len,
                        .entry_branch = self.cur_branch,
                        .entry_once = self.once_depth,
                        .chain_member = chain,
                    });
                    self.cur_lambda = @intCast(self.ua.tables.lambdas.items.len - 1);
                }
                self.many_depth += 1;
                try self.walk(lam.body);
                self.many_depth -= 1;
                self.cur_lambda = saved_lambda;
                self.popBinders(start);
            },
            .lambda_attrs => {
                const start = self.stack.items.len;
                const la = node.data.lambda_attrs;
                const introduced: u16 = @intCast(self.many_depth + 1);
                if (la.bind_name) |bn| try self.pushBinderAt(try self.internSpan(bn), invalid_cluster, 0, invalid_binding, introduced);
                for (la.params) |param| try self.pushBinderAt(try self.internSpan(param.name), invalid_cluster, 0, invalid_binding, introduced);
                const saved_lambda = self.cur_lambda;
                if (self.c.let_float.full_lazy) {
                    try self.ua.walked.put(self.ua.allocator, node, {});
                    try self.ua.tables.lambdas.append(self.c.allocator, .{
                        .node = node,
                        .parent = saved_lambda,
                        .level = introduced,
                        .entry_mark = self.ua.tables.log_len,
                        .entry_branch = self.cur_branch,
                        .entry_once = self.once_depth,
                    });
                    self.cur_lambda = @intCast(self.ua.tables.lambdas.items.len - 1);
                }
                self.many_depth += 1;
                for (la.params) |param| {
                    if (param.default) |d| try self.walk(d);
                }
                try self.walk(la.body);
                self.many_depth -= 1;
                self.cur_lambda = saved_lambda;
                self.popBinders(start);
            },
            .let_in => try self.walkCluster(node),
            .if_else => {
                const i = node.data.if_else;
                try self.walk(i.cond);
                const saved_branch = self.cur_branch;
                try self.ua.tables.branches.append(self.c.allocator, .{
                    .parent = saved_branch,
                    .node = i.then_branch,
                    .if_node = node,
                    .is_then = true,
                    .once_depth = self.once_depth,
                    .many_depth = self.many_depth,
                    .shadow_mark = self.ua.tables.log_len,
                });
                self.cur_branch = @intCast(self.ua.tables.branches.items.len - 1);
                try self.walk(i.then_branch);
                try self.ua.tables.branches.append(self.c.allocator, .{
                    .parent = saved_branch,
                    .node = i.else_branch,
                    .if_node = node,
                    .is_then = false,
                    .once_depth = self.once_depth,
                    .many_depth = self.many_depth,
                    .shadow_mark = self.ua.tables.log_len,
                });
                self.cur_branch = @intCast(self.ua.tables.branches.items.len - 1);
                try self.walk(i.else_branch);
                self.cur_branch = saved_branch;
            },
            .assert => {
                try self.walk(node.data.assert.cond);
                try self.walk(node.data.assert.body);
            },
            .with_expr => {
                const w = node.data.with_expr;
                self.once_depth += 1;
                try self.walk(w.attr_set);
                self.once_depth -= 1;
                // Mark the body region: dynamic-name movement may not cross.
                // The mark itself advances the log clock, so a site inside
                // the body is distinguishable even when the body introduces
                // no binders (positions are a walk-order clock, not just
                // binder indices).
                try self.ua.tables.with_marks.append(self.c.allocator, self.ua.tables.log_len);
                self.ua.tables.log_len += 1;
                try self.walk(w.body);
            },
            .attr_set => {
                const start = self.stack.items.len;
                const set = node.data.attr_set;
                if (set.recursive) {
                    for (set.entries) |entry| {
                        if (entry.path.len == 0) continue;
                        if (attr_names.hasInterpolation(self.c, entry.path[0])) continue;
                        try self.pushBinder(try attr_names.intern(self.c, entry.path[0]), invalid_cluster, 0, invalid_binding);
                    }
                }
                for (set.entries) |entry| {
                    if (entry.dynamic_name) |dn| try self.walk(dn);
                    for (entry.path) |seg| try self.wordsInSpan(seg);
                    if (set.recursive and entry.inherit_outer) {
                        // `rec { inherit x; }` resolves x past the rec set's
                        // own binder.
                        if (entry.path.len == 1 and !attr_names.hasInterpolation(self.c, entry.path[0])) {
                            try self.refPastInnermost(try attr_names.intern(self.c, entry.path[0]));
                            continue;
                        }
                    }
                    self.once_depth += 1;
                    try self.walk(entry.expr);
                    self.once_depth -= 1;
                }
                self.popBinders(start);
            },
            .attr_path => {
                try self.walk(node.data.attr_path.root);
                for (node.data.attr_path.segments) |seg| try self.wordsInSpan(seg);
            },
            .attr_dynamic => {
                try self.walk(node.data.attr_dynamic.root);
                try self.walk(node.data.attr_dynamic.name);
            },
            .attr_or => {
                try self.walk(node.data.attr_or.attr_path);
                self.once_depth += 1;
                try self.walk(node.data.attr_or.default);
                self.once_depth -= 1;
            },
            .has_attr => {
                try self.walk(node.data.has_attr.root);
                for (node.data.has_attr.segments) |seg| try self.wordsInSpan(seg);
            },
            .has_attr_mixed => {
                const ham = node.data.has_attr_mixed;
                try self.walk(ham.root);
                for (ham.segments) |seg| switch (seg) {
                    .static => |a| try self.wordsInSpan(a),
                    .dynamic => |n| {
                        self.once_depth += 1;
                        try self.walk(n);
                        self.once_depth -= 1;
                    },
                };
            },
            .list => {
                self.once_depth += 1;
                for (node.data.list.items) |item| try self.walk(item);
                self.once_depth -= 1;
            },
            .parens => try self.walk(node.data.parens),
        }
    }

    /// Open a cluster at let node `head`, merging directly-nested let levels
    /// when safe, walking every binding RHS and the final body, then closing
    /// (SCCs) and registering the cluster for each covered let node.
    fn walkCluster(self: *Walker, head: *const Node) anyerror!void {
        const allocator = self.c.allocator;
        const stack_start = self.stack.items.len;

        const cluster = try allocator.create(Cluster);
        const id = self.next_cluster_id;
        self.next_cluster_id += 1;
        // Walk-order registry (index == walk-local id): decide-all iterates
        // this outer-first, and cross-cluster free refs resolve through it.
        std.debug.assert(self.ua.walk_clusters.items.len == id);
        try self.ua.walk_clusters.append(self.ua.allocator, cluster);

        var merged_entries: std.ArrayListUnmanaged(Node.Binding) = .empty;
        var bindings: std.ArrayListUnmanaged(Binding) = .empty;

        cluster.* = .{
            .head = head,
            .entries = &.{},
            .body = undefined,
            .levels = 0,
            .graph = .{
                .tables = &self.ua.tables,
                .id = id,
                .bindings = &.{},
            },
        };
        try self.active.append(allocator, .{ .cluster = cluster, .id = id });
        const ctx_index = self.active.items.len - 1;

        // Level loop: append this level's bindings, walk its RHSes, then
        // try to merge the body if it is itself a let.
        var level_node: *const Node = head;
        var covered: std.ArrayListUnmanaged(*const Node) = .empty;
        defer covered.deinit(allocator);
        while (true) {
            const let_in = level_node.data.let_in;
            try covered.append(allocator, level_node);
            cluster.levels += 1;

            const level_first: u32 = if (cluster.levels == 1)
                0
            else blk: {
                // Second and later levels concatenate entry lists; the first
                // level's entries are copied in lazily on first merge.
                if (merged_entries.items.len == 0)
                    try merged_entries.appendSlice(allocator, head.data.let_in.bindings);
                const first: u32 = @intCast(merged_entries.items.len);
                try merged_entries.appendSlice(allocator, let_in.bindings);
                break :blk first;
            };
            const level_bindings_first: u32 = @intCast(bindings.items.len);
            try collectBindings(self.c, &bindings, let_in.bindings, level_first);
            // Every spine level sits at the cluster's own Lévy level
            // (spine merge never crosses a lambda).
            for (bindings.items[level_bindings_first..]) |*b| b.home_level = @intCast(self.many_depth);

            // Push this level's binders (recursive scope: RHSes see all
            // siblings of their level and every outer level). Logged with
            // this cluster's id: the cluster's own shadow windows skip them
            // (siblings are scope-visible everywhere within the cluster),
            // while enclosing clusters' windows still see them.
            for (bindings.items[level_bindings_first..], level_bindings_first..) |*b, bi| {
                try self.pushBinder(b.name_id, id, @intCast(ctx_index), @intCast(bi));
            }
            cluster.graph.bindings = bindings.items;
            if (cluster.levels == 1) {
                // Header marks are FIRST-level only: merged levels' binders
                // land inside the windows but are skipped by cluster id.
                cluster.graph.header_log_len = self.ua.tables.log_len;
                cluster.graph.header_branch = self.cur_branch;
                cluster.graph.header_once = self.once_depth;
                cluster.graph.header_many = self.many_depth;
            }

            // Walk this level's RHS regions.
            try self.walkClusterRhses(ctx_index, let_in.bindings, bindings.items);

            // Spine merge: body directly a let with fresh, unmentioned names?
            const body = ast.unwrapParens(let_in.body);
            if (body.tag != .let_in or body.data.let_in.bindings.len == 0) {
                cluster.body = let_in.body;
                break;
            }
            var safe = true;
            {
                // Collision or accumulated-RHS mention of an inner name
                // blocks. Binding lists and free lists are deduplicated and
                // small; merge checks only run when the body is directly a
                // let.
                outer: for (body.data.let_in.bindings) |binding| {
                    const name_id = try self.c.intern.intern(attr_names.span(self.c, binding.path[0]));
                    for (bindings.items) |*b| {
                        if (b.name_id == name_id) {
                            safe = false;
                            break :outer;
                        }
                        for (b.free.items) |f| {
                            if (f.id == name_id) {
                                safe = false;
                                break :outer;
                            }
                        }
                    }
                }
            }
            if (!safe) {
                cluster.body = let_in.body;
                break;
            }
            level_node = body;
        }

        // Body of the (merged) cluster.
        {
            const ctx = &self.active.items[ctx_index];
            ctx.cur_rhs = invalid_binding;
        }
        cluster.graph.bindings = bindings.items;
        try self.walk(cluster.body);

        cluster.entries = if (cluster.levels == 1)
            head.data.let_in.bindings
        else
            try merged_entries.toOwnedSlice(allocator);
        cluster.graph.bindings = try bindings.toOwnedSlice(allocator);
        cluster.graph.uses = try self.active.items[ctx_index].uses.toOwnedSlice(allocator);
        try finalize.finalize(allocator, &cluster.graph);

        self.popBinders(stack_start);
        _ = self.active.pop();
        for (covered.items) |let_node| {
            try self.ua.clusters.put(self.ua.allocator, let_node, cluster);
        }
    }

    /// Walk one level's RHS regions, setting per-entry rhs ownership. The
    /// entry loop mirrors the per-group semantics `let.zig` compiles with:
    /// inherit clauses walk their shared source once, dotted groups walk
    /// every entry (including interpolated tail segments).
    fn walkClusterRhses(
        self: *Walker,
        ctx_index: usize,
        level_entries: []const Node.Binding,
        all_bindings: []Binding,
    ) anyerror!void {
        const allocator = self.c.allocator;
        for (level_entries) |entry| {
            const name_id = try self.c.intern.intern(attr_names.span(self.c, entry.path[0]));
            // Group id via the binder map: this level's binders are pushed
            // and innermost for their names during their own RHS walks.
            const binder_pos = self.by_name.get(name_id).?;
            const binding_id = self.stack.items[binder_pos].binding;
            const b = &all_bindings[binding_id];

            {
                const ctx = &self.active.items[ctx_index];
                ctx.cur_rhs = binding_id;
                ctx.rhs_start_stack = self.stack.items.len;
            }
            defer self.active.items[ctx_index].cur_rhs = invalid_binding;

            self.once_depth += 1;
            defer self.once_depth -= 1;

            switch (b.kind) {
                .plain => try self.walk(entry.expr),
                .inherit_outer => {
                    // `inherit x;` resolves x OUTSIDE the cluster: skip this
                    // binding's own binder during resolution.
                    try self.skips.append(allocator, binder_pos);
                    defer _ = self.skips.pop();
                    try self.walk(entry.expr);
                },
                .inherit_member => {
                    // One shared source expression per clause.
                    const ctx = &self.active.items[ctx_index];
                    const gop = try ctx.inherit_walked.getOrPut(allocator, entry.inherit_group);
                    if (!gop.found_existing) try self.walk(entry.expr);
                },
                .dotted => {
                    // Every entry of the group visits here in entry order;
                    // walk each one's expr and interpolated tail segments.
                    for (entry.path[1..]) |seg| try self.wordsInSpan(seg);
                    try self.walk(entry.expr);
                },
            }
        }
    }
};

/// One `Binding` per unique root name of one level, appended to `out` with
/// `first_index` offset by `entry_offset` (merged spines concatenate entry
/// lists). Mirrors `let.zig`'s slot model: merged dotted groups share their
/// first index.
fn collectBindings(
    self: *Compiler,
    out: *std.ArrayListUnmanaged(Binding),
    level_entries: []const Node.Binding,
    entry_offset: u32,
) !void {
    var by_name: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
    defer by_name.deinit(self.allocator);

    for (level_entries, 0..) |entry, i| {
        const name_id = try self.intern.intern(attr_names.span(self, entry.path[0]));
        const gop = try by_name.getOrPut(self.allocator, name_id);
        if (gop.found_existing) {
            // Second entry for the same root: the group is dotted/merged.
            const b = &out.items[gop.value_ptr.*];
            b.kind = .dotted;
            b.leaf = null;
            continue;
        }
        gop.value_ptr.* = out.items.len;
        const kind: BindingKind = if (entry.inherit_outer)
            .inherit_outer
        else if (entry.inherit_group != 0)
            .inherit_member
        else if (entry.path.len > 1)
            .dotted
        else
            .plain;
        try out.append(self.allocator, .{
            .name_id = name_id,
            .first_index = entry_offset + @as(u32, @intCast(i)),
            .kind = kind,
            .inherit_group = entry.inherit_group,
            .leaf = if (kind == .plain) entry.expr else null,
        });
    }
}

/// How `name_id` resolves at the walk root's position, beyond the walker's
/// own binders: lexically up the compiler chain, via the static builtin
/// environment, or dynamically (`with` / unresolvable / scopedImport base).
pub fn classifyOuterName(self: *Compiler, name_id: InternId) NameClass {
    var c: ?*Compiler = self;
    while (c) |cc| : (c = cc.parent) {
        if (scope.resolveLocalId(cc, name_id) != null) return .lexical;
    }
    // scopedImport replaces the whole base environment: nothing below
    // lexical scope is stable.
    if (self.scoped_base) return .dynamic;
    const name = self.intern.get(name_id);
    if (std.mem.eql(u8, name, "builtins") or std.mem.eql(u8, name, "__curPos") or
        std.mem.eql(u8, name, "__nixPath"))
        return .builtin;
    if (builtins.ambientIdForName(name) != null or builtins.hasConstant(name)) return .builtin;
    return .dynamic;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '\'' or c == '-';
}
