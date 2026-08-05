//! Demand-driven `let` binding placement: a semantics-preserving AST→AST
//! rewrite that floats bindings toward their consumers, so the existing
//! lowering (adaptive `thunk_arg` arguments, strict-lambda detection,
//! trivial-thunk elision, cell classification) sees the most direct
//! expression structure and allocates fewer binding thunks and slots.
//!
//! Runs once per compiled `let`, before `let.zig` classifies and emits.
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

/// Global kill switch, resolved from `FIX_NO_LET_FLOAT` at engine start
/// (`eval/tuning.zig`). Compile-time only; safe to flip between units.
pub var enabled: bool = true;

/// Print the census to stderr when the engine tears down
/// (`FIX_LET_FLOAT_STATS=1`, resolved alongside the kill switch).
pub var report_on_deinit: bool = false;

/// Monotonic census counters (whole-process, compile-time only — never on
/// the force path). Reported by `fix disasm --stats`.
pub const Stats = model.Stats;
pub var stats: Stats = .{};

/// Report the census (`FIX_LET_FLOAT_STATS=1` prints it at engine teardown;
/// `fix disasm --stats` embeds it). One line per counter, zeros skipped.
pub fn writeReport(w: *std.Io.Writer) !void {
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
        .{ "cluster map hits", &stats.cluster_hits },
        .{ "cluster walks", &stats.cluster_walks },
        .{ "strict-prefix members", &stats.prefix_members },
    };
    inline for (fields) |field| {
        const v = field[1].load(.monotonic);
        if (v != 0) try w.print("  {s}: {d}\n", .{ field[0], v });
    }
}

fn bump(counter: *std.atomic.Value(u64)) void {
    _ = counter.fetchAdd(1, .monotonic);
}

fn bumpBy(counter: *std.atomic.Value(u64), n: u64) void {
    if (n != 0) _ = counter.fetchAdd(n, .monotonic);
}

/// Census hook for `let.zig` (the prefix is computed there, on the residual).
pub fn bumpPrefixMembers(n: usize) void {
    bumpBy(&stats.prefix_members, n);
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

/// Rewrite one `let` before lowering. Returns the node to compile instead:
/// the original node when nothing improved, a rebuilt `let_in`, or — when
/// every binding dissolved — the (rewritten) body expression itself.
pub fn rewriteLet(self: *Compiler, node: *const Node) !*const Node {
    if (!enabled) return node;
    // An installed debugger wants the source's bindings materialized as
    // written (breakpoint scopes resolve locals by name), so the optimizer
    // stands down entirely. Disasm/name capture does NOT stand down — it
    // must show production codegen.
    if (self.registry.preserve_bindings) return node;
    // Rewrite nodes live in the unit's AST arena (retained alongside
    // deferred bodies). Roots without one don't rewrite.
    const arena = rootAstArena(self) orelse return node;

    if (node.data.let_in.bindings.len == 0) return node;

    const _pt = prof.start(.let_float);
    defer prof.end(.let_float, _pt);

    const ua = try unitAnalysis(self);
    if (ua.clusters.get(node) != null) bump(&stats.cluster_hits) else bump(&stats.cluster_walks);
    const cluster = ua.clusters.get(node) orelse blk: {
        // First let of a subtree not yet analyzed (an outermost let, a
        // materialized elided body, an interpolation sub-parse, or a
        // subtree rebuilt by an enclosing rewrite): one walk registers this
        // cluster AND every let below it, so nesting never multiplies —
        // each subtree is walked once, plus once more per enclosing rewrite
        // that changed something inside it.
        const _wt = prof.start(.let_float_walk);
        try analysis_walker.analyze(self, ua, node);
        prof.end(.let_float_walk, _wt);
        break :blk ua.clusters.get(node) orelse return node;
    };

    // Decide once per cluster, even when the same cluster compiles more
    // than once (branch-cloned subtrees share nodes at scope-equivalent
    // positions, so the decisions apply identically).
    const overlay = try (try unitRewriteState(self)).overlay(cluster.head);
    if (overlay.plan == null) {
        bump(&stats.lets);
        bumpBy(&stats.bindings, cluster.graph.bindings.len);
        bumpBy(&stats.flattened_lets, cluster.levels - 1);
        overlay.plan = try planner.decide(self, &cluster.graph, cluster.entries, &stats);
    }
    const decisions = &overlay.plan.?;

    // Merged spines compile as one flat let (cached; entries are the
    // concatenated levels, body is the innermost body).
    const flat: *const Node = if (cluster.levels > 1) blk: {
        if (overlay.flat == null) {
            const merged = try arena.allocSlice(Node.Binding, cluster.entries.len);
            @memcpy(merged, cluster.entries);
            const flat_node = try arena.createNode(.let_in, .{ .let_in = .{
                .bindings = merged,
                .body = @constCast(cluster.body),
            } });
            flat_node.span = node.span;
            overlay.flat = flat_node;
        }
        break :blk overlay.flat.?;
    } else node;

    if (!decisions.any_change) return flat;
    return rewrite.rebuildLet(self, arena, decisions, flat);
}
