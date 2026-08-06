//! Demand-driven `let` binding placement: a semantics-preserving AST→AST
//! rewrite that floats bindings toward their consumers, so the existing
//! lowering (adaptive `thunk_arg` arguments, strict-lambda detection,
//! trivial-thunk elision, cell classification) sees the most direct
//! expression structure and allocates fewer binding thunks and slots.
//!
//! Entered from `let.zig` before it classifies and emits. The FIRST let of
//! an unanalyzed subtree walks the whole subtree, decides EVERY registered
//! cluster in one batch (outer-first, into unit-level replacement/wrap
//! maps), and applies all of it in ONE copy-on-write rebuild; the rebuilt
//! nested residuals come back through here `decided` and compile untouched.
//! This replaces the earlier per-let decide+rebuild, whose rebuilt inner
//! lets were fresh nodes and re-walked once per enclosing rewrite.
//! Reads the binder-resolved use/region graph from `let_analysis/model.zig` and applies,
//! in order:
//!
//!   1. **Dead-binding cascade** — a binding is live only if reachable from
//!      the body (through live sibling RHSes); dead plain/inherit bindings
//!      drop, including chains today's direct-reference check keeps.
//!   2. **Duplicable inline** — a literal RHS, or an alias `x = y` whose
//!      target resolves statically, replaces every rewritable use; sharing
//!      is unaffected because no computation is duplicated. Aliases may
//!      cross lambda boundaries; each replaced site gets a FRESH node so
//!      node identity stays unique within any subtree (nested rewrites key
//!      decisions by node pointer).
//!   3. **Single-use sinking** — a binding whose one live use sits in an
//!      at-most-once region moves to its use site. Evaluation still happens
//!      exactly at the original demand point; the consumer's own lowering
//!      then chooses the representation (eager value, adaptive argument
//!      thunk, plain thunk). Never crosses a potentially-many lambda
//!      boundary, a shadowing binder of any RHS free name, or a `with`
//!      when the RHS mentions a dynamically-resolved name.
//!
//! Rewrites build NEW nodes in the unit's AST arena (the same arena elided
//! bodies materialize into, so deferred-attr entries may safely retain
//! pointers into the result); retained parser AST is never mutated, and
//! unchanged subtrees are shared. Anything the pass cannot prove safe it
//! leaves exactly as written — the kill switch `FIX_NO_LET_FLOAT=1`
//! disables it wholesale for A/B measurement.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const analysis = @import("let_analysis/model.zig");
const analysis_walker = @import("let_analysis/walker.zig");
const model = @import("let_float/model.zig");
const planner = @import("let_float/planner.zig");
const rewrite = @import("let_float/rewrite.zig");
const prof = @import("../probe.zig").prof;

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;

/// Monotonic census counters owned by one Engine and updated only while
/// compiling. Reported by that Engine's teardown and `fix disasm --stats`.
pub const Stats = model.Stats;

/// Report the census (`FIX_LET_FLOAT_STATS=1` prints it at engine teardown;
/// `fix disasm --stats` embeds it). One line per counter, zeros skipped.
pub fn writeReport(w: *std.Io.Writer, stats: *const Stats) !void {
    const fields = .{
        .{ "lets analyzed", &stats.lets },
        .{ "bindings seen", &stats.bindings },
        .{ "dead bindings dropped", &stats.dropped_dead },
        .{ "literal uses inlined", &stats.inlined_literal_uses },
        .{ "alias uses inlined", &stats.inlined_alias_uses },
        .{ "bindings fully inlined", &stats.inlined_bindings },
        .{ "single-use bindings sunk", &stats.sunk_single_use },
        .{ "bindings floated into a branch", &stats.floated_branch },
        .{ "bindings cloned into both branches", &stats.floated_cloned },
        .{ "nested lets flattened", &stats.flattened_lets },
        .{ "blocked: shadowed free name", &stats.blocked_shadow },
        .{ "blocked: many-region use", &stats.blocked_many },
        .{ "blocked: pinned mention", &stats.blocked_pinned },
        .{ "blocked: dynamic free name", &stats.blocked_dynamic },
        .{ "blocked: recursive group", &stats.blocked_recursive },
        .{ "would-float bindings (full-lazy)", &stats.would_float_bindings },
        .{ "would-float levels crossed", &stats.would_float_levels },
        .{ "bindings floated out of lambdas", &stats.floated_out },
        .{ "float-out levels crossed", &stats.floated_out_levels },
        .{ "float-out blocked: shadowed", &stats.blocked_out_shadow },
        .{ "float-out blocked: uncurry chain", &stats.blocked_out_chain },
        .{ "float-out blocked: no destination", &stats.blocked_out_nodest },
        .{ "cluster map hits", &stats.cluster_hits },
        .{ "cluster walks", &stats.cluster_walks },
        .{ "strict-prefix members", &stats.prefix_members },
    };
    inline for (fields) |field| {
        const v = field[1].load(.monotonic);
        if (v != 0) try w.print("  {s}: {d}\n", .{ field[0], v });
    }
}

fn bump(stats: ?*Stats, comptime field: []const u8) void {
    if (stats) |s| _ = @field(s, field).fetchAdd(1, .monotonic);
}

fn bumpBy(stats: ?*Stats, comptime field: []const u8, n: u64) void {
    if (n != 0) {
        if (stats) |s| _ = @field(s, field).fetchAdd(n, .monotonic);
    }
}

/// Census hook for `let.zig` (the prefix is computed there, on the residual).
pub fn bumpPrefixMembers(stats: ?*Stats, n: usize) void {
    bumpBy(stats, "prefix_members", n);
}

fn rootAstArena(self: *Compiler) ?*ast.AstArena {
    var c: *Compiler = self;
    while (c.parent) |p| c = p;
    return c.ast_arena;
}

/// The root compiler's cluster registry, created on first use. Scratch
/// (unit arena), like every other analysis structure.
fn unitAnalysis(self: *Compiler) !*analysis.UnitAnalysis {
    var root: *Compiler = self;
    while (root.parent) |p| root = p;
    if (root.let_units) |ua| return ua;
    const ua = try root.allocator.create(analysis.UnitAnalysis);
    ua.* = analysis.UnitAnalysis.init(root.allocator);
    root.let_units = ua;
    return ua;
}

fn unitRewriteState(self: *Compiler) !*model.UnitState {
    var root: *Compiler = self;
    while (root.parent) |p| root = p;
    if (root.let_float_state) |state| return state;
    const state = try root.allocator.create(model.UnitState);
    state.* = model.UnitState.init(root.allocator);
    root.let_float_state = state;
    return state;
}

/// Decide every cluster registered by the most recent walk, in walk order
/// (outer-first), all into the unit-level replacement/wrap maps. One
/// subsequent rebuild applies the whole batch.
fn decideAll(self: *Compiler, ua: *analysis.UnitAnalysis, state: *model.UnitState) !void {
    // The replacement/wrap maps are BATCH-scoped: this batch's single
    // rebuild applies them, and a wrap's subtree is fully resolved when the
    // wrap is constructed, so later batches (wrap-let recompiles, sub-parse
    // walks) must start clean — a stale wrap key re-encountered by a later
    // rebuild would wrap its branch node a second time (unboundedly, since
    // each wrap recompile walks afresh). Contents are unit-scratch; clearing
    // retains capacity.
    state.replacements.clearRetainingCapacity();
    state.wraps.clearRetainingCapacity();
    state.lambda_wraps.clearRetainingCapacity();
    state.lambda_outer_wraps.clearRetainingCapacity();
    state.batch +%= 1;

    var batch_clean = true;
    for (ua.walk_clusters.items) |cluster| {
        const overlay = try state.overlay(cluster.head);
        overlay.walk_batch = state.batch;
        if (overlay.plan == null) {
            bump(self.let_float.stats, "lets");
            bumpBy(self.let_float.stats, "bindings", cluster.graph.bindings.len);
            bumpBy(self.let_float.stats, "flattened_lets", cluster.levels - 1);
            overlay.plan = try planner.decide(self, &cluster.graph, cluster.entries, self.let_float.stats, .{
                .state = state,
                .walk_clusters = ua.walk_clusters.items,
            });
        }
        batch_clean = batch_clean and !overlay.plan.?.any_change and cluster.levels == 1;
    }
    // Nothing in the batch changes and no spine flattens: every head
    // compiles as written — pre-seed the rebuild memos so no rebuild ever
    // descends this subtree (matching the old no-change fast path's cost).
    if (batch_clean) {
        for (ua.walk_clusters.items) |cluster| {
            const overlay = try state.overlay(cluster.head);
            overlay.rebuilt = cluster.head;
            overlay.rebuilt_batch = state.batch;
        }
    }
}

/// Full-laziness pre-emission hook (`FIX_FULL_LAZY=1`), called from the
/// DRIVER when a lambda expression is about to compile: analyze its whole
/// subtree, decide the batch, and return the rebuilt EXPRESSION — which
/// may be a synthetic `let floated… in <lambda>` when bindings float all
/// the way out (the thunk then lives in the parent scope, created once
/// per closure creation, shared by every application). Nested float
/// destinations are applied inside the rebuild. Returns `node` untouched
/// when the gate is off or an enclosing walk already covered this lambda
/// (a covered-but-unchanged lambda has no pending wraps by construction).
pub fn rewriteLambdaExpression(self: *Compiler, node: *const Node) !*const Node {
    if (!self.let_float.enabled or !self.let_float.full_lazy) return node;
    if (self.registry.preserve_bindings) return node;
    const arena = rootAstArena(self) orelse return node;

    const ua = try unitAnalysis(self);
    if (ua.walked.contains(node)) return node;
    const state = try unitRewriteState(self);

    const _pt = prof.start(.let_float);
    defer prof.end(.let_float, _pt);
    {
        const _wt = prof.start(.let_float_walk);
        try analysis_walker.analyze(self, ua, node);
        prof.end(.let_float_walk, _wt);
    }
    try decideAll(self, ua, state);
    // Consume this batch's maps NOW (they are batch-scoped): every nested
    // residual comes out `decided`, so a later interpolation sub-parse (a
    // new batch, cleared maps) cannot strand a pending rebuild.
    return rewrite.rebuildTree(self, arena, ua, state, node);
}

/// Rewrite one `let` before lowering. Returns the node to compile instead:
/// the original node when nothing improved, a rebuilt `let_in`, or — when
/// every binding dissolved — the (rewritten) body expression itself.
///
/// The first let of an unanalyzed subtree walks the whole subtree, decides
/// EVERY registered cluster, and applies all of it in one rebuild; nested
/// residual lets come back through here already `decided` and compile
/// untouched (no re-walk of rebuilt AST).
pub fn rewriteLet(self: *Compiler, node: *const Node) !*const Node {
    if (!self.let_float.enabled) return node;
    // An installed debugger wants the source's bindings materialized as
    // written (breakpoint scopes resolve locals by name), so the optimizer
    // stands down entirely. Disasm/name capture does NOT stand down — it
    // must show production codegen.
    if (self.registry.preserve_bindings) return node;
    // Rewrite nodes live in the unit's AST arena (retained alongside
    // deferred bodies). Roots without one don't rewrite.
    const arena = rootAstArena(self) orelse return node;

    if (node.data.let_in.bindings.len == 0) return node;

    const state = try unitRewriteState(self);
    // A unified rebuild already applied this residual's plan.
    if (state.decided.contains(node)) return node;

    const _pt = prof.start(.let_float);
    defer prof.end(.let_float, _pt);

    const ua = try unitAnalysis(self);
    if (ua.clusters.get(node) != null)
        bump(self.let_float.stats, "cluster_hits")
    else
        bump(self.let_float.stats, "cluster_walks");
    const cluster = ua.clusters.get(node) orelse blk: {
        // First let of a subtree not yet analyzed (an outermost let, a
        // materialized elided body, an interpolation sub-parse, or a
        // branch-wrap synthetic let): one walk registers this cluster AND
        // every let below it, and decide-all plans the whole batch at once.
        const _wt = prof.start(.let_float_walk);
        try analysis_walker.analyze(self, ua, node);
        prof.end(.let_float_walk, _wt);
        try decideAll(self, ua, state);
        break :blk ua.clusters.get(node) orelse return node;
    };

    // Rebuild once per cluster, even when the same original node compiles
    // more than once (branch-cloned subtrees share nodes at scope-equivalent
    // positions, so the decisions apply identically); `rebuildCluster`
    // memoizes per head.
    return rewrite.rebuildCluster(self, arena, ua, state, cluster);
}
