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
    would_float_bindings: std.atomic.Value(u64) = .init(0),
    would_float_levels: std.atomic.Value(u64) = .init(0),
    floated_out: std.atomic.Value(u64) = .init(0),
    floated_out_levels: std.atomic.Value(u64) = .init(0),
    blocked_out_shadow: std.atomic.Value(u64) = .init(0),
    blocked_out_chain: std.atomic.Value(u64) = .init(0),
    blocked_out_nodest: std.atomic.Value(u64) = .init(0),
    blocked_out_capture: std.atomic.Value(u64) = .init(0),
    mfe_candidates: std.atomic.Value(u64) = .init(0),
    floated_mfe: std.atomic.Value(u64) = .init(0),
    floated_chain_split: std.atomic.Value(u64) = .init(0),
    blocked_mfe_chain: std.atomic.Value(u64) = .init(0),
    blocked_mfe_enclosing: std.atomic.Value(u64) = .init(0),
    blocked_mfe_recursive: std.atomic.Value(u64) = .init(0),
    // ---- idiom census (structural Nix patterns, corpus-ranking only; ----
    // ---- counted during the analysis walk, reported with the rest) ------
    /// `a // b` where the LEFT operand is itself an `//` — a merge chain
    /// materializing intermediates a k-way merge would skip.
    idiom_update_chain: std.atomic.Value(u64) = .init(0),
    /// Apply whose callee is a SYNTACTIC lambda literal (through parens):
    /// an inline-candidate monomorphic call site.
    idiom_apply_lambda_lit: std.atomic.Value(u64) = .init(0),
    /// Apply of a builtin whose ARGUMENT is another builtin application
    /// (`f (g x)` with both `f`,`g` resolving as builtins/attr-paths off
    /// `builtins`): a fusable builtin pipeline.
    idiom_builtin_pipeline: std.atomic.Value(u64) = .init(0),
    /// `let`/rec binding whose RHS is a BARE identifier (alias/forwarding
    /// binding: one deref of pure indirection per read).
    idiom_alias_binding: std.atomic.Value(u64) = .init(0),
    /// `if <apply> then x else x`-shaped dynamic dispatch (`isFunction f`,
    /// `isAttrs v`, …): a type-dispatch site.
    idiom_type_dispatch: std.atomic.Value(u64) = .init(0),
    /// `rec { … }` or self-application shapes (fixpoint idiom).
    idiom_rec_attrs: std.atomic.Value(u64) = .init(0),
    /// Attr select chains `a.b.c` of depth >= 2 (path walks).
    idiom_select_chain: std.atomic.Value(u64) = .init(0),
    cluster_hits: std.atomic.Value(u64) = .init(0),
    cluster_walks: std.atomic.Value(u64) = .init(0),
    prefix_members: std.atomic.Value(u64) = .init(0),
};

/// Engine-owned optimizer capability inherited unchanged by every compiler in
/// a unit. `stats` is null only in isolated compiler harnesses; production
/// Engines always supply their own counter set.
pub const Context = struct {
    enabled: bool = true,
    /// Full-laziness development gate: pre-emission analysis walks at
    /// outermost lambdas (see `let_float.rewriteLambdaBody`). Independent
    /// of `enabled` only in that both must hold for the lambda hook.
    full_lazy: bool = false,
    /// Anonymous-MFE work gate: minimum applies in a candidate subtree.
    mfe_min_applies: u16 = 1,
    /// Dev A/B knob (`FIX_FL_NAMED_OFF=1`): stand down the NAMED float-out
    /// pass while keeping the walk machinery and MFE pass live.
    named_floats: bool = true,
    /// Experimental: wrap chain-inner lambdas (split uncurry chains).
    chain_split: bool = false,
    stats: ?*Stats = null,
};

pub const analysis = @import("../let_analysis/model.zig");

pub const Plan = struct {
    /// Per-binding: emit this group in the residual let?
    keep: []bool,
    /// Per-binding: at least one use site was replaced (inline or sink) —
    /// the RHS text now lives at those sites, so an enclosing region that
    /// mentioned this name must expand it to the RHS's effective free set
    /// when deciding its own later movements (cross-cluster composition).
    replaced_any: []bool,
    /// Per-binding: planner-derived extra free names accumulated while
    /// deciding this cluster (sunk siblings' frees, alias targets, and
    /// cross-cluster expansions). Alongside `Binding.free`, this is the
    /// binding's post-plan effective free set.
    extra_free: []const []const analysis.FreeName,
    /// Per-binding: the Lévy-level fixpoint result (== home level when the
    /// full-lazy gate is off or the binding is immobile). Inner clusters'
    /// fixpoints read these for cross-cluster free refs.
    assigned_levels: []const u16,
    any_change: bool,
};

pub const ClusterOverlay = struct {
    /// Computed once even when branch cloning compiles the same cluster more
    /// than once.
    plan: ?Plan = null,
    /// Cached flat node for a merged directly-nested let spine.
    flat: ?*const Node = null,
    /// Memoized unified-rebuild result for this cluster's head node, so a
    /// second compile of the same original node (branch-cloned subtrees)
    /// reuses one rebuilt tree. Valid only within the batch that built it
    /// (`rebuilt_batch`): the rebuild bakes in that batch's replacement/wrap
    /// maps, and a LATER batch re-registering the same head (a wrap-let
    /// recompile walking original nodes afresh) may add new replacements
    /// inside the subtree that a stale tree would silently drop. The PLAN,
    /// by contrast, is position-independent and shared across batches.
    rebuilt: ?*const Node = null,
    rebuilt_batch: u32 = 0,
    /// Batch that most recently REGISTERED this head in its walk. A memo is
    /// stale only when the head was re-registered after it was built (only
    /// then can new decisions target the subtree); comparing against the
    /// CURRENT batch instead would wrongly invalidate memos whenever an
    /// unrelated walk ran in between, recomputing with foreign maps.
    walk_batch: u32 = 0,
};

pub const UnitState = struct {
    allocator: std.mem.Allocator,
    /// Fresh-name counter for anonymous-MFE synthetic bindings
    /// (`"\x00fl.<n>"` — unspellable, so collision- and capture-free).
    synth_counter: u32 = 0,
    /// A cluster's outermost source node is its stable identity within one
    /// compile unit; all covered nested-let nodes share this overlay.
    overlays: std.AutoHashMapUnmanaged(*const Node, *ClusterOverlay) = .empty,
    /// Unit-global use-site rewrites: identifier node -> replacement
    /// expression. All clusters of a walk batch decide into ONE map, so a
    /// single copy-on-write rebuild applies every plan at once and later
    /// clusters see earlier clusters' replacements when chasing effective
    /// shapes (node pointers are unique across clusters).
    replacements: std.AutoHashMapUnmanaged(*const Node, *const Node) = .empty,
    /// Unit-global branch-local floats: branch expression node -> original
    /// bindings to wrap around it as a synthetic inner let.
    wraps: std.AutoHashMapUnmanaged(*const Node, std.ArrayListUnmanaged(Node.Binding)) = .empty,
    /// Full-laziness float-out wraps, BODY position: destination lambda
    /// node -> bindings whose thunk moves to the top of that lambda's body.
    /// Used only for uncurry-chain-clamped partial floats (the wrap sits at
    /// the post-chain body, splitting nothing). Batch-scoped like `wraps`.
    lambda_wraps: std.AutoHashMapUnmanaged(*const Node, std.ArrayListUnmanaged(Node.Binding)) = .empty,
    /// Full-laziness float-out wraps, AROUND position (the normal case):
    /// lambda node -> bindings wrapped around the lambda EXPRESSION itself
    /// (`let floated… in <lambda>`), so the thunk is created once per
    /// closure creation in the parent scope and shared by every
    /// application. Keys are never chain-inner lambdas (that would split
    /// the parent's uncurry chain). Batch-scoped.
    lambda_outer_wraps: std.AutoHashMapUnmanaged(*const Node, std.ArrayListUnmanaged(Node.Binding)) = .empty,
    /// Let nodes produced by a unified rebuild with their cluster's plan
    /// already applied: `rewriteLet` returns these untouched instead of
    /// re-walking the (fresh, unregistered) subtree — the decide-all +
    /// single-rebuild scheme's whole point. Branch-wrap synthetic lets are
    /// deliberately NOT marked (they re-plan on compile, as before).
    decided: std.AutoHashMapUnmanaged(*const Node, void) = .empty,
    /// Current decide/rebuild batch (one per walk); scopes the replacement
    /// and wrap maps and the per-cluster `rebuilt` memos.
    batch: u32 = 0,

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
