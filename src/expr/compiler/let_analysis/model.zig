//! Immutable binder-resolved model for `let` cluster analysis.
//!
//! `walker.zig` builds these values once per compile unit; `finalize.zig`
//! freezes their lookup and adjacency indexes before rewrite policy sees them.
//!
//! `let_float.zig` consults one `Cluster` per compiled `let` and reads its
//! graph to decide capture-safe binding rewrites. Per root-name binding
//! group the graph answers:
//!
//!   - every reference site (the exact identifier `Node`) with its evaluation
//!     **multiplicity** relative to the cluster header (`Mult`): `same` runs
//!     when the surrounding code runs, `once` is delayed but runs at most
//!     once (thunk bodies, attr/list members, argument thunks), `many` may
//!     run repeatedly (lambda bodies, pattern defaults);
//!   - references that exist only as conservative text mentions (string/path
//!     interpolation words, elided spans, operator-overload names) — these
//!     are **pinned**: they keep the binding alive and its named slot in
//!     place, and can never be rewritten;
//!   - the RHS's **free names**, each with a static-resolution class, so a
//!     rewrite can prove capture-safety (no intervening binder shadows a
//!     moved expression's free name) and effect-safety (a name resolved
//!     dynamically through `with` never moves);
//!   - dependency **SCCs** over sibling references (recursive groups stay
//!     atomic and immobile).
//!
//! The walk visits each AST node exactly once, maintaining the stack of
//! ACTIVE clusters: a resolved name records a use for the one cluster that
//! binds it and contributes to the free set of every enclosing binding-RHS
//! region it sits in. All per-cluster measurements are HEADER-RELATIVE
//! (multiplicity as depth deltas, shadow checks as windows into a global
//! binder log, branch chains cut at the header's branch), which makes a
//! cluster's graph invariant under enclosing rewrites that merely MOVE its
//! subtree. All clusters of one walk are decided as a BATCH (outer-first;
//! `walk_clusters` preserves that order) and applied by a single rebuild,
//! so rebuilt residuals never need re-analysis; the per-let fallback walk
//! remains only for AST created after the pass (materialized elided
//! bodies, interpolation sub-parses, branch-wrap synthetic lets), keyed by
//! node pointer identity.
//!
//! Directly-nested let spines (`let A in let B in …`) merge into one cluster
//! during the walk when no capture changes (no name collisions, no
//! accumulated RHS mention of an inner name), so dead-cascade, aliasing,
//! sinking, and the strict prefix see across the levels.
//!
//! The walk mirrors `refs.zig`'s conservative coverage exactly: every
//! mention that walker would report is either a resolved use or a pinned
//! mention here, so liveness decisions are at least as conservative as the
//! existing dead-binding elimination. Precision differs only in one safe
//! direction — mentions that provably resolve to an inner binder (a
//! shadowing lambda param, nested let, or rec-attr name) are not counted as
//! uses.

const std = @import("std");
const ast = @import("syntax").ast;
const types = @import("runtime").types;

const Node = ast.Node;
const InternId = types.InternId;

pub const BindingId = u32;
pub const invalid_binding: BindingId = std.math.maxInt(BindingId);
pub const invalid_branch: u32 = std.math.maxInt(u32);
pub const invalid_cluster: u32 = std.math.maxInt(u32);

/// Evaluation multiplicity of a position relative to a cluster header.
pub const Mult = enum(u2) {
    /// Evaluated exactly when the enclosing code runs (incl. conditionally —
    /// what matters for sharing is "at most once", not "always").
    same,
    /// Delayed behind a thunk that runs at most once (attr members, list
    /// elements, argument thunks, binding RHSes, `with` subjects).
    once,
    /// May run zero or many times (lambda bodies, pattern defaults).
    many,
};

/// How a free name of an RHS resolves at the cluster's own position.
pub const NameClass = enum {
    /// A sibling binding of this cluster.
    cluster,
    /// A binder above the cluster: an enclosing lambda param, an enclosing
    /// cluster's binding, or a local/upvalue up the compiler chain.
    lexical,
    /// The static builtin environment (`builtins`, ambient builtins,
    /// `__curPos`, `__nixPath`). Stable under `with` (lexical and builtin
    /// resolution outrank `with` lookups — see `literals.compileIdent`).
    builtin,
    /// Everything else: `with`-resolved, unresolvable (a compile error at
    /// the original site), any name under `scopedImport`'s replaced base
    /// environment, or a conservative word from an opaque span. Dynamic
    /// names pin their RHS in place.
    dynamic,
};

pub const FreeName = struct {
    id: InternId,
    class: NameClass,
    /// Sibling id when `class == .cluster`; for `class == .lexical` names
    /// that resolve to an ENCLOSING cluster's binding within the same walk,
    /// the binding id in that cluster (with `src_cluster` set). The
    /// cross-cluster link lets a later decision expand this name through a
    /// decided-away outer binding (its RHS text may land in this region).
    binding: BindingId = invalid_binding,
    /// Walk-local id of the enclosing cluster that binds a `.lexical` name,
    /// or `invalid_cluster` (plain binders: lambda params, rec-attr names,
    /// names resolved outside the walk).
    src_cluster: u32 = invalid_cluster,
    /// Lévy level of the resolved binder: lambda params carry their
    /// lambda's introduced level; let/rec binders carry the level they sit
    /// AT; names resolved outside the walk (lexical-above, builtins) are
    /// level 0. An expression's floor is the max over its frees — see
    /// `Binding.assigned_level`.
    level: u16 = 0,
};

pub const Use = struct {
    binding: BindingId,
    /// The exact identifier node, or null for a pinned mention that has no
    /// rewritable site (interpolation word, overload name, elided span).
    site: ?*const Node,
    mult: Mult,
    /// Global binder-log length when this use was recorded: a rewrite
    /// placing an expression here must prove none of its free names were
    /// introduced in the window (cluster header, shadow_mark) — a
    /// conservative superset of the binders between header and site.
    shadow_mark: u32,
    /// Which sibling's RHS contains this use; `invalid_binding` = the
    /// cluster body.
    in_rhs_of: BindingId,
    /// Innermost enclosing if-branch (global id into `SharedTables`), or
    /// `invalid_branch`. Chains via `Branch.parent`, cut at the cluster's
    /// header branch, drive branch-local floating.
    branch: u32 = invalid_branch,
    pinned: bool,
};

/// Compact immutable adjacency assembled when a cluster walk finishes.
/// Keys are binding ids; values are either binding ids or use indices.
pub const Adjacency = struct {
    offsets: []const u32 = &.{0},
    items: []const u32 = &.{},

    pub fn at(self: Adjacency, key: BindingId) []const u32 {
        return self.items[self.offsets[key]..self.offsets[key + 1]];
    }
};

/// One lambda position in the walk (full-laziness levels). `level` is the
/// Lévy level it INTRODUCES (= many_depth after entering it): an
/// expression whose free names all resolve at levels < L may float to the
/// top of the level-L lambda's body. `parent` chains outward for
/// destination lookup; `entry_mark` is the binder-log position at body
/// entry (the outward shadow window's lower bound); `chain_member` marks a
/// directly-adjacent value-lambda child of its parent (the uncurry chain —
/// splitting it has a codegen cost, see the plan's chain-split gate).
pub const LambdaInfo = struct {
    node: *const Node,
    parent: u32 = invalid_lambda,
    level: u16,
    entry_mark: u32,
    entry_branch: u32 = invalid_branch,
    entry_once: u32 = 0,
    chain_member: bool = false,
};

pub const invalid_lambda: u32 = std.math.maxInt(u32);

/// One `if` branch position. Bindings whose every use lies under a branch
/// can float into it (a synthetic let wrapping the branch expression): the
/// thunk is then only ever created on the path that uses it, and evaluation
/// still happens at the original demand point.
pub const Branch = struct {
    parent: u32,
    /// The branch expression node (wrap target).
    node: *const Node,
    if_node: *const Node,
    is_then: bool,
    /// Region-depth snapshots at the `if`; a cluster derives the branch's
    /// multiplicity relative to its own header (`Graph.branchMult`).
    once_depth: u32,
    many_depth: u32,
    /// Binder-log mark at branch entry: a floated RHS's free names must not
    /// be shadowed by any binder between the cluster header and the branch.
    shadow_mark: u32,
};

pub const BindingKind = enum {
    /// Exactly one `name = expr;` leaf. The only movable shape.
    plain,
    /// Dotted paths (`a.b = …`) and/or several entries sharing one root.
    dotted,
    /// A member of an `inherit (source) …` clause (shared source thunk).
    inherit_member,
    /// `inherit name;` — rebinds an outer name (skip-slot resolution).
    inherit_outer,
};

pub const Binding = struct {
    name_id: InternId,
    /// Index of the group's first entry in the cluster's `entries` slice.
    first_index: u32,
    kind: BindingKind,
    inherit_group: u32 = 0,
    /// RHS expression when `kind == .plain`.
    leaf: ?*const Node = null,

    /// Free names of the RHS (deduplicated), classified at the cluster site.
    free: std.ArrayListUnmanaged(FreeName) = .empty,
    /// RHS mentions a `with`-resolved / unresolvable name → immobile.
    has_dynamic_free: bool = false,
    /// RHS contains an elided (never-parsed) span → immobile.
    has_opaque: bool = false,
    self_ref: bool = false,

    use_count: u32 = 0,
    body_use_count: u32 = 0,
    pinned_use: bool = false,

    scc: u32 = 0,
    /// Member of a multi-binding cycle, or self-referential.
    scc_recursive: bool = false,

    /// Lévy level this binding's cluster sits at (== the cluster's
    /// `header_many`): the binding may float OUT when `assigned_level <
    /// home_level` (stage 1 records the would-float census; stage 2 moves).
    home_level: u16 = 0,
    /// Fixpoint over the free set: max of each free's binder level, with
    /// sibling/outer cluster bindings contributing their own POST-float
    /// assigned level (outer-first decide order makes this a single pass).
    /// Immobile shapes (dynamic frees, opaque, recursive SCCs, non-plain
    /// kinds) pin `assigned_level = home_level`.
    assigned_level: u16 = 0,

    pub fn addFree(self: *Binding, allocator: std.mem.Allocator, name: FreeName) !void {
        for (self.free.items) |existing| {
            if (existing.id == name.id) return;
        }
        try self.free.append(allocator, name);
        if (name.class == .dynamic) self.has_dynamic_free = true;
    }
};

/// One logged binder introduction: its position in the global log order and
/// the cluster that owns it (or `invalid_cluster` for plain inner binders —
/// lambda params, rec-attr names). A cluster's shadow windows skip its OWN
/// binders: sibling references are scope-visible everywhere in the cluster.
const LogEntry = struct {
    pos: u32,
    cluster: u32,
};

/// Walk-global side tables shared by every cluster of one walker run: the
/// append-only binder log (positions per name) and the branch array. Owned
/// by the `UnitAnalysis`, referenced by each `Graph`.
pub const SharedTables = struct {
    allocator: std.mem.Allocator,
    log_len: u32 = 0,
    log_pos: std.AutoHashMapUnmanaged(InternId, std.ArrayListUnmanaged(LogEntry)) = .empty,
    branches: std.ArrayListUnmanaged(Branch) = .empty,
    /// Every lambda entered by this walk batch, in entry order (full-lazy
    /// only; empty otherwise). Cluster graphs reference these by index for
    /// float destinations.
    lambdas: std.ArrayListUnmanaged(LambdaInfo) = .empty,
    /// Full-lazy only: every NAME MENTION (resolved, `with`-resolved,
    /// unresolvable, conservative interpolation word) at its log position.
    /// Hoisting a binder grants its name new visibility over the
    /// destination's whole body; a mention there that previously resolved
    /// elsewhere — an outer lexical binder, or dynamically through `with`
    /// (lexical resolution outranks `with`) — would be CAPTURED. The float
    /// proof refuses names mentioned in the newly-covered region.
    mentions: std.AutoHashMapUnmanaged(InternId, std.ArrayListUnmanaged(u32)) = .empty,
    /// Binder-log positions where a `with` body begins. A binding whose RHS
    /// mentions a dynamically-resolved name may still move — but only when
    /// the walk window between its cluster header and the destination
    /// crosses no `with` entry (the with-lookup chain is then identical at
    /// both positions). Ascending by construction.
    with_marks: std.ArrayListUnmanaged(u32) = .empty,

    pub fn logMention(self: *SharedTables, name_id: InternId) !void {
        const gop = try self.mentions.getOrPut(self.allocator, name_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, self.log_len);
        // Advance the walk clock (like `with` marks do): a cluster that
        // closes right after a mention must record a LATER end position,
        // or inside-subtree mentions are indistinguishable from
        // later-sibling ones. Positions stay monotonic, so every window
        // consumer is unaffected.
        self.log_len += 1;
    }

    /// Any mention of `name_id` in log window [from, to)?
    pub fn mentionedInWindow(self: *const SharedTables, name_id: InternId, from: u32, to: u32) bool {
        const list = self.mentions.get(name_id) orelse return false;
        const items = list.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < from) lo = mid + 1 else hi = mid;
        }
        return lo < items.len and items[lo] < to;
    }

    pub fn logBinder(self: *SharedTables, name_id: InternId, cluster: u32) !void {
        const gop = try self.log_pos.getOrPut(self.allocator, name_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, .{ .pos = self.log_len, .cluster = cluster });
        self.log_len += 1;
    }

    /// Does log window [from, to) cross into a `with` body?
    fn withCrossed(self: *const SharedTables, from: u32, to: u32) bool {
        const items = self.with_marks.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < from) lo = mid + 1 else hi = mid;
        }
        return lo < items.len and items[lo] < to;
    }

    /// Public window check for OUTWARD movement (float-out): same
    /// semantics as `shadowedInWindow`, exported for the planner's
    /// destination proofs.
    pub fn shadowedInWindowPub(self: *const SharedTables, name_id: InternId, from: u32, to: u32, own: u32) bool {
        return self.shadowedInWindow(name_id, from, to, own);
    }

    /// Was `name_id` introduced by a binder in log window [from, to), other
    /// than by cluster `own` itself? Positions per name are ascending by
    /// construction (append-only log).
    fn shadowedInWindow(self: *const SharedTables, name_id: InternId, from: u32, to: u32, own: u32) bool {
        const list = self.log_pos.get(name_id) orelse return false;
        const items = list.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].pos < from) lo = mid + 1 else hi = mid;
        }
        while (lo < items.len and items[lo].pos < to) : (lo += 1) {
            if (items[lo].cluster != own) return true;
        }
        return false;
    }
};

/// Per-cluster analysis result: the binding table and use records, with the
/// header snapshots that make every measurement relative to this cluster.
pub const Graph = struct {
    tables: *SharedTables,
    /// This cluster's id (used to skip its own binders in shadow windows).
    id: u32,
    bindings: []Binding,
    uses: []const Use = &.{},
    /// Direct name lookup, frozen with the binding slice.
    binding_by_name: std.AutoHashMapUnmanaged(InternId, BindingId) = .empty,
    /// Binding id -> indices into `uses`.
    uses_by_binding: Adjacency = .{},
    /// Activation owner -> sibling bindings referenced by that owner's RHS.
    /// Members of one `inherit (source)` clause share a single owner because
    /// the source expression is evaluated once for the whole clause.
    dependencies_by_owner: Adjacency = .{},
    /// Sibling bindings referenced by the cluster body.
    root_dependencies: []const BindingId = &.{},
    /// Binding id -> activation owner used by `dependencies_by_owner`.
    activation_owner: []const BindingId = &.{},
    header_log_len: u32 = 0,
    header_branch: u32 = invalid_branch,
    /// Innermost enclosing lambda at the cluster header (index into
    /// `SharedTables.lambdas`; full-lazy walks only). Float destinations
    /// ascend its parent chain.
    header_lambda: u32 = invalid_lambda,
    /// Log position when the cluster's walk CLOSED — mentions at or beyond
    /// this are outside the cluster's subtree (later siblings), which a
    /// hoisted binder would also newly cover.
    end_log_len: u32 = 0,
    header_once: u32 = 0,
    header_many: u32 = 0,

    /// True when `name_id` was introduced by some binder between this
    /// cluster's header and log position `mark` — i.e. an expression
    /// mentioning `name_id` freely may not move to a site recorded at
    /// `mark`. The cluster's own binders don't count (siblings are
    /// scope-visible everywhere within the cluster).
    pub fn shadowedAt(self: *const Graph, name_id: InternId, mark: u32) bool {
        return self.tables.shadowedInWindow(name_id, self.header_log_len, mark, self.id);
    }

    /// Does moving an expression from this cluster's header to a site
    /// recorded at `mark` cross into a `with` body? Gates the movement of
    /// bindings with dynamically-resolved free names (identical with-chain
    /// on both sides ⇒ identical resolution).
    pub fn withCrossedAt(self: *const Graph, mark: u32) bool {
        return self.tables.withCrossed(self.header_log_len, mark);
    }

    /// The branch's multiplicity relative to this cluster's header.
    pub fn branchMult(self: *const Graph, branch: Branch) Mult {
        if (branch.many_depth > self.header_many) return .many;
        if (branch.once_depth > self.header_once) return .once;
        return .same;
    }

    /// The branch-id path from this cluster's header down to `branch`
    /// (root-first). Cut at the branch that was active at the header.
    pub fn branchChain(self: *const Graph, allocator: std.mem.Allocator, branch: u32) ![]u32 {
        var chain: std.ArrayListUnmanaged(u32) = .empty;
        var cur = branch;
        while (cur != invalid_branch and cur != self.header_branch) {
            try chain.append(allocator, cur);
            cur = self.tables.branches.items[cur].parent;
        }
        std.mem.reverse(u32, chain.items);
        return chain.toOwnedSlice(allocator);
    }

    pub fn findBinding(self: *const Graph, name_id: InternId) ?BindingId {
        return self.binding_by_name.get(name_id);
    }

    pub fn useIndices(self: *const Graph, binding: BindingId) []const u32 {
        return self.uses_by_binding.at(binding);
    }

    pub fn dependencies(self: *const Graph, owner: BindingId) []const BindingId {
        return self.dependencies_by_owner.at(owner);
    }

    pub fn ownerFor(self: *const Graph, binding: BindingId) BindingId {
        return self.activation_owner[binding];
    }
};

/// One analyzed `let` (possibly a merged spine of directly-nested lets).
/// Held by the unit's cluster registry, keyed by every ORIGINAL let node
/// the cluster covers. Scratch-lifetime (compile-unit arena).
pub const Cluster = struct {
    /// The outermost let node of the (possibly merged) spine.
    head: *const Node,
    /// Concatenated binding entries across merged levels.
    entries: []const Node.Binding,
    /// The body below the last merged level.
    body: *const Node,
    /// Number of merged let levels (1 = no merge).
    levels: u32,
    graph: Graph,
};

/// Cluster registry for one compile unit (or one fallback walk). Owned by
/// the ROOT compiler; children route through it. Everything scratch.
pub const UnitAnalysis = struct {
    allocator: std.mem.Allocator,
    tables: SharedTables,
    clusters: std.AutoHashMapUnmanaged(*const Node, *Cluster) = .empty,
    /// Clusters registered by the MOST RECENT walk, indexed by walk-local
    /// cluster id (walk order = outer-first). Cleared at each walk's entry;
    /// consumed immediately after by the decide-all pass, which needs both
    /// the outer-first order and id→cluster resolution for cross-cluster
    /// free-name refs (`FreeName.src_cluster` is walk-local).
    walk_clusters: std.ArrayListUnmanaged(*Cluster) = .empty,
    /// Full-laziness only: every lambda node covered by a walk (original
    /// nodes during `walker.analyze`, rebuilt nodes during the unified
    /// rebuild), so `rewriteLambdaBody` skips already-analyzed subtrees in
    /// O(1). Untouched when the full-lazy gate is off.
    walked: std.AutoHashMapUnmanaged(*const Node, void) = .empty,

    pub fn init(allocator: std.mem.Allocator) UnitAnalysis {
        return .{ .allocator = allocator, .tables = .{ .allocator = allocator } };
    }
};
