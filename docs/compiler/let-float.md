# Let-Float: Demand-Driven Binding Placement

*A semantics-preserving AST→AST rewrite that floats `let` bindings toward
their consumers, so the existing lowering sees the most direct expression
structure and allocates fewer binding thunks and slots.*

## Mental model

Nix `let` bindings are lazy thunks, but many of them don't need to be a
*named, cell-backed slot in this chunk* at all — a binding used exactly once
could just live at its use site; a binding whose value is a literal or an
alias could be copied to every use; a binding used only on one branch of an
`if` shouldn't cost a thunk allocation on the branch that never touches it.
`let_float.zig` proves these shapes are safe and rewrites the AST accordingly,
**before** `let.zig` classifies and emits the residual bindings (see
[pipeline.md](pipeline.md)). It runs once per compiled `let`, on the
compiling unit's AST arena, and is scoped to that one `let` — it is not a
whole-program IR or optimizer pass (see [pipeline.md](pipeline.md#mental-model)).

The rewrite never changes *what* the program computes or *when* a binding's
RHS is evaluated relative to demand: a binding's evaluation stays pinned to
its original first-demand point. What moves is where the **thunk gets
created** — which is unobservable, because Nix has no way to distinguish "a
thunk exists but is unforced" from "the thunk doesn't exist yet, but will
when reached."

Everything the pass cannot prove safe it leaves exactly as written.

## The cluster analysis (`let_analysis/`)

Each compiled `let` — a "cluster" of sibling bindings plus the let body — is
turned into a `Graph` (scratch-lifetime, unit arena) that answers, per
binding:

### The registry: one walk per compile unit, not per let

The root `Compiler` owns a `UnitAnalysis` (`context.zig`'s `let_units`
field): a cluster **registry** keyed by AST let-node pointer, plus a
`SharedTables` shared by every cluster the walk finds — a global,
append-only binder log (per-name position lists, each tagged with the
cluster that owns that binder), the `if`-branch array, and the `with_marks`
list (see [Capture safety](#capture-safety) below). `core.analyze` walks a
subtree once and registers a `Cluster` for **every** `let` inside it, not
just the outermost one — a deeply nested module body analyzes each of its
lets exactly once, not once per enclosing level.

All per-cluster measurements are **header-relative**: multiplicity is a
depth delta from the cluster's own header, shadow checks are windows into
the shared binder log starting at the header's log position, and branch
chains are cut at the header's branch. This makes a cluster's graph
**invariant under any enclosing rewrite that only moves its subtree** —
sinking, floating, or wrapping an outer binding's RHS doesn't change
anything header-relative inside a nested let, so the nested cluster stays
valid and reusable after its enclosing let has been rewritten.

An enclosing rewrite that instead *changes* a nested let's own contents (a
sink or float lands inside it) rebuilds that let's node outright
(copy-on-write). Because the registry is keyed by node pointer, the rebuilt
node is simply never found: `let_float.rewriteLet` falls back to one fresh
walk of that subtree, which re-registers every cluster inside it — so a
subtree is re-walked at most once per enclosing rewrite that touched it,
never once per nesting level below it. The census counters **cluster map
hits** and **cluster walks** (below) count these two paths.

Directly-nested let spines (`let A in let B in …`) merge into one cluster
**during this same walk** (see "Nested-let spine merging" below), so the
graph captures bindings across the merged spine.

The bullets below describe what the graph records once built; the registry
above is what makes building it cheap.

- **Every reference site**, tagged with its evaluation **multiplicity**
  relative to the let header (`Mult`): `same` (runs when the surrounding code
  runs), `once` (delayed but runs at most once — thunk bodies, attr/list
  members, argument thunks), or `many` (may run zero or many times — lambda
  bodies, pattern defaults). Multiplicities compose down the tree (`many`
  dominates, then `once`, then `same`).
- **Pinned mentions** — conservative text references that have no rewritable
  site: string/path interpolation words, elided (never-parsed) spans, and
  operator-overload hook names (`__add`, `__sub`, …). These keep the binding
  alive and its named slot in place; they can never be moved or duplicated.
- **Free-name classes** for each RHS: `cluster` (a sibling), `lexical` (an
  enclosing local/upvalue), `builtin` (the static builtin environment —
  stable even under `with`), or `dynamic` (`with`-resolved, unresolvable, or
  under a `scopedImport`-replaced base — gates movement per destination
  against the `with`-chain; see [Capture safety](#capture-safety)).
- **Dependency SCCs** (iterative Tarjan) over sibling reference edges —
  members of a multi-node cycle, or a self-referential binding, are marked
  `scc_recursive` and stay immobile.
- **If-branch chains** — every `if` encountered during the walk pushes a
  `Branch` (then/else, with a parent pointer), so a use's `branch` field
  gives the full nested-branch path from the let header. Branch-local
  floating uses this to find the deepest branch common to a binding's uses.

The walk mirrors `refs.zig`'s conservative coverage: every mention it reports
is either a resolved use or a pinned mention here. A mention that provably
resolves to an inner binder (a shadowing lambda parameter, nested `let`, or
recursive-attr name) is not counted as a cluster use.

## The transforms

`rewriteLet` applies these in order, on the residual bindings still alive
after each prior step:

### 0. Nested-let spine merging

`let a = …; in let b = …; in body` merges into one cluster when no inner
name collides with an accumulated name and no accumulated RHS mentions an
inner name (conservative name collection via `refs.zig`, so an interpolation
word counts as a mention). This check runs **during** the cluster walk
itself (`let_analysis/walker.zig`'s `walkCluster`, one safety check per level considered
for merging), not as a separate pre-pass: the walk keeps extending the same
cluster into the body's own nested `let` while it's safe to, then closes it
— so dead-cascade, inlining, sinking, and the strict prefix all see across
what were separate `let` levels.

```nix
let a = 1; in let b = a + 1; in a + b
# flattens to:
let a = 1; b = a + 1; in a + b
```

```nix
let a = 1; in let a = 2; in a
# does NOT flatten: inner `a` collides with the outer name (would become a
# duplicate binding, changing which `a` is which).
```

### 1. Dead-binding cascade

A group-aware liveness fixpoint over the graph's uses: a binding is live only
when reachable from the body through *live* sibling RHSes. This cascades —
today's simpler "is this name mentioned anywhere" check keeps a binding alive
merely because a *dead* sibling's RHS mentions it; the fixpoint does not.

```nix
let unused = expensiveA; helper = unused + 1; x = 1; in x
# `helper` mentions `unused`, but `helper` itself is dead — both drop:
let x = 1; in x
```

`inherit (source) a, b;` clauses count as one liveness unit: the shared
source expression stays live if *any* member of the clause is live.

### 2. Duplicable inlining

A **literal** RHS, or an **alias** `x = y` whose target resolves statically
(and isn't itself opaque/dynamic), replaces every rewritable use with a
*fresh* copy of the RHS — safe because neither duplicates computation (a
literal has none; an alias's target is still evaluated once, wherever it
ends up). Each replaced site gets a brand-new node so pointer identity stays
unique per occurrence (nested rewrite decisions are keyed by node pointer).

```nix
let greeting = "hi"; in [ greeting greeting ]
# inlines to:
[ "hi" "hi" ]
```

```nix
let y = x; in y + y
# (x resolves statically, unshadowed at both use sites) inlines to:
x + x
```

A pinned use (inside `${…}`, an elided span, or an operator-overload name)
is never replaced — it isn't a rewritable site. A use whose target name would
be shadowed by a binder between the alias's original position and the use
site is also left alone (`blocked_shadow`). If every use of a binding
inlines, the binding itself drops from the residual `let`.

### 3. Single-use sinking

A binding with exactly one live, non-pinned use in an at-most-once (`same`/
`once`) region moves its RHS to that use site. The consumer's own lowering
then picks the representation (eager value, adaptive argument thunk, plain
thunk) — evaluation still happens exactly where it would have.

```nix
let n = expensiveCompute a b; in { result = n; }
# sinks to:
{ result = expensiveCompute a b; }
```

Blocked when the use is in a `many` region (sinking into a repeatedly-run
lambda body would turn one shared evaluation into a fresh one per call —
`blocked_many`), when the RHS mentions a free name shadowed at the use site
(`blocked_shadow`), or when the RHS is lambda-valued (never sinks — see
below). A sunk binding's free names fold into the owner's RHS's free-name set,
so a later sink of the *owner* still sees them (cascading sinks compose).

**Lambda-valued bindings never sink.** The runtime-adaptive call path already
eagerizes call sites of a directly-known lambda, so sinking gains almost
nothing — and it would erase the binding's qualified chunk name, which error
traces attribute frames by (see [name tree](../architecture.md)).

### 4. Branch-local floating

When a binding's every live use lies under one `if`-branch, that branch is
wrapped in a synthetic inner `let` re-binding it — so the thunk is created
only on the path that actually uses it:

```nix
let big = heavyCompute y; in if cond then f big else g
# floats to:
if cond then (let big = heavyCompute y; in f big) else g
```

When a binding's uses split *exactly* across both branches of one `if`
(nothing outside it), the wrap clones into both branches instead — safe
because the branches are dynamically exclusive, so cloning duplicates code,
never evaluation:

```nix
let shared = a + b; in if cond then shared + 1 else shared - 1
# clones to:
if cond then (let shared = a + b; in shared + 1)
         else (let shared = a + b; in shared - 1)
```

The clone case is size-gated (RHS source span ≤ 160 bytes) to bound code
growth. Floating requires `same`/`once` multiplicity at the `if` itself (a
branch inside a `many` region would re-evaluate the binding per call —
`blocked_many`) and no free name shadowed at the branch's shadow mark.
Lambda-valued bindings *can* branch-float: the wrap is a real named `let`
binding, so the qualified chunk name survives.

## Capture safety

Every move is checked against an append-only **shadow log**
(`SharedTables.log_pos`, a per-name list of log positions; a cluster's own
window starts at `Graph.header_log_len`): every binder name pushed during
the walk is logged and never popped, so `Graph.shadowedAt(name, mark)`
answers "was `name` introduced by some inner binder before log position
`mark`?" — a conservative superset of the binders actually active there
(siblings that closed before `mark` stay logged, which only makes the check
*more* likely to block a move, never less; a cluster's own binders are
excluded from its own window, since siblings are scope-visible everywhere
within the cluster). A rewrite placing an expression at a new site must
prove none of the expression's free names were shadowed between the
original position and the target.

**`with`/dynamic names move only within an unchanged `with`-chain.** A free
name that resolves dynamically — through `with`, unresolvably, or through a
`scopedImport`-replaced base environment (`classifyOuterName`'s `.dynamic`
class) — is checked per destination. It may move only when the window from
its original position crosses no `with` body (`Graph.withCrossedAt`, backed by
`SharedTables.with_marks`). An identical `with`-chain resolves the name to the
same value; crossing a `with` entry could change that resolution, so it blocks
the move (`blocked_dynamic`).

`scopedImport` still pins outright in practice: it replaces the *entire*
base environment, so `classifyOuterName` classifies everything below
lexical scope as `.dynamic` under it — there is no stable resolution to
compare a destination against, so every window "crosses" in the sense that
matters.

One log-clock subtlety: `with_marks` records a mark for **every** `with`
body, even one that introduces no binders of its own (`with pkgs.lib; body`
where nothing from `pkgs.lib` is actually named would otherwise be invisible
to the crossing check). Appending the mark still advances the shared binder
log's clock (`ua.tables.log_len += 1`), so a site *inside* an empty-binder
`with` body is distinguishable from one just outside it — the crossing
check is a walk-order position, not merely a count of binders. Without this,
a binder-free `with` could be silently "hopped" by a move that should have
been blocked.

**Opaque (elided) spans immobilize too.** A never-parsed span inside an RHS
means every ident-shaped word in it is a conservative pinned mention and the
RHS as a whole is treated as opaque — it cannot be proven capture-safe, so it
stays put.

**Recursive SCCs stay atomic.** A binding in a multi-member dependency cycle,
or a self-referential binding, is marked `scc_recursive` and excluded from
inlining, sinking, and floating (`blocked_recursive`).

## Sharing safety

Three separate rules keep the rewrite from ever duplicating *evaluation*
(as opposed to code):

- **The many-region rule.** Anything that would move a binding's thunk
  creation into a potentially-repeated region (a lambda body, a pattern
  default) is refused. A binding evaluated once outside a lambda and shared
  across every call must not become "recompute per call."
- **Duplicable-only inlining.** Only literals (no computation to duplicate)
  and aliases (the target keeps its own single evaluation; a copy is just a
  redirect) are ever copied to multiple sites. Anything with real computation
  sinks (moves once) instead of inlining (copies).
- **Branch exclusivity.** Cloning a binding's RHS into both arms of an `if`
  is sound only because the two arms never both run in the same evaluation —
  cloning duplicates compiled code, not work.

## The strict prefix and its validation

After the rewrite, `let.zig` classifies the *residual* bindings and computes
the ordered **strict prefix** (`demand_prefix.analyze`) over eligible
members: the maximal sequence of bindings provably forced, in order, before
any other observable effect, extended transitively through binding RHSes.
See [strictness.md](strictness.md) for the full walk and completeness rules.

**Callee-aware descent.** A prefix binding whose RHS is a statically-known
value-lambda chain (`demand_prefix.Binding.lambda`, built by `demand_prefix.lambdaShape`
— pattern lambdas are excluded, since formal validation can throw before any
parameter is forced) is treated as a pre-resolved closure shell: forcing the
*binding* is effect-free. When the body applies it fully saturated, the walk
descends into the lambda's body with parameters bound to the call's argument
expressions, so the body's own demand order extends the prefix through the
call:

```nix
let f = x: x + 1; y = compute; in f y
```

`f`'s body (`x + 1`) forces `x` unconditionally, and `f y` is a saturated
call to a known sibling lambda, so the walk continues into `x + 1` with `x`
bound to `y` — `y` joins the strict prefix and is eagerized exactly as it
would be if the call were inlined by hand. A parameter the body never
forces stays lazy just as before (`let f = x: y: y; a = expensiveA; b = 2;
in f a b` never demands `a`, so `a` stays a thunk), and effect order still
follows body demand order — which error surfaces first under
`builtins.tryEval` is unchanged. Descent is depth-capped at 4 nested
known-callee calls (`max_call_depth`); a sibling lambda's body sees only its
own call-site frame, while an inline lambda literal's body extends the
current visibility window (`strictness.md`'s window model has the full
detail).

The prefix is then **validated** against sibling reference edges collected
during classification. A prefix member may be referenced only by a *later*
prefix member, whose pass-3 evaluation reads an already-filled slot. A lazy
sibling or an earlier prefix member demotes the referenced binding back to a
lazy thunk; demotions cascade. This rule prevents the strict prefix from
reading an uninitialized recursive binding.

## Interaction with deferred compilation and the debugger

**Opaque elided spans pin, rather than break, deferred compilation.** A
binding whose RHS (or whose only reference) sits inside a never-parsed
`.elided` span is marked opaque and pinned exactly as described above — the
rewrite simply declines to move it, so large machine-generated attrsets that
defer per-leaf compilation (see [lazy-compile.md](lazy-compile.md)) are
unaffected: their unparsed bodies are opaque to this pass either way.

**Rewrite nodes share the retained arena lifetime.** `rewriteLet` allocates
new nodes in the *root* compiler's AST arena (`rootAstArena` walks the
`parent` chain to find it) — the same arena deferred bodies are materialized
into. A compiler with no such arena (no root unit) doesn't rewrite at all.
This means a deferred entry created after a let-float rewrite may safely
retain pointers into the rewritten tree.

**The pass stands down entirely when a debugger is installed**
(`ChunkRegistry.preserve_bindings`, set by `Engine.setDebugUi`): breakpoint
scopes resolve locals by the name they're written with, so the source's
bindings must materialize exactly as written. `disasm` and name-capture do
**not** stand down — they must show production codegen, not a debug-only
shape.

## Kill switch & census

- **`FIX_NO_LET_FLOAT=1`** disables the rewrite wholesale, for A/B
  measurement. Resolved once at engine start (`eval/tuning.zig`) into
  `let_float.enabled`; compile-time only, safe to flip between units.
- **`FIX_LET_FLOAT_STATS=1`** prints a per-counter census to stderr at engine
  teardown (`let_float.writeReport`, also embedded in `fix disasm --stats`):
  lets analyzed, bindings seen, dead-dropped/inlined/sunk/floated counts, why
  a candidate was blocked (shadowed free name, many-region use, pinned
  mention, dynamic free name, recursive group), and three registry/prefix
  counters: **cluster map hits** (a `rewriteLet` call found its cluster
  already registered), **cluster walks** (a fresh `core.analyze` walk was
  needed — the outermost let of a subtree, or the copy-on-write fallback
  after an enclosing rewrite changed something), and **strict-prefix
  members** (bindings the callee-aware demand-prefix walk placed in a
  strict prefix, summed across every residual `let`). Counters are
  monotonic, process-wide atomics — cheap enough to leave instrumented,
  never touched on the force path.

## Cost profile

The analysis walks each **outermost** `let` subtree once and registers its
nested `let`s in that pass. A rewrite that changes a nested subtree can require
one additional analysis of that subtree, but not a fresh walk of every enclosing
`let`.

Historical measurements against a pinned nixpkgs universe found this registry
shape about 3% faster than the earlier per-`let` analysis. Treat that result as
motivation for the design, not as a current performance guarantee; use the
[performance probes](../perf/probes.md) to evaluate changes.

## Invariants

- **Semantics-preserving.** A binding's evaluation stays at its original
  first-demand point; only thunk *creation* moves, which is unobservable.
- **Retained AST is never mutated.** Rewrite nodes live in the unit's AST
  arena; subtrees the rewrite doesn't touch are shared, not copied.
- **Node identity stays unique per occurrence.** Every duplicated site (a
  literal/alias inline) gets a fresh node, so pointer-keyed decisions in a
  nested rewrite never conflate two occurrences.
- **At least as conservative as existing dead-binding elimination.**
  Precision differs from `refs.zig`'s walk only in the direction of *more*
  liveness accuracy (an inner-binder-shadowed mention isn't a use), never
  less.
- **Nothing moves without a capture-safety and sharing-safety proof.**
  Shadow checks, the per-destination `with`-crossing check on dynamic free
  names, opaque pinning, and SCC atomicity gate every transform; anything
  unproven stays exactly as written.

Out of scope: the strict-prefix walk and its completeness/barrier rules in
full → [strictness.md](strictness.md); where the residual `let` is classified
and emitted → [pipeline.md](pipeline.md); name resolution and the shadow
model this pass reads → [scopes.md](scopes.md); deferred per-attr compilation
→ [lazy-compile.md](lazy-compile.md). This pass does not attempt **full
laziness**: floating a binding outward past an enclosing lambda to share it
across calls. The strict prefix handles saturated calls to statically-known
sibling or inline value lambdas, depth-capped at 4; see
[The strict prefix and its validation](#the-strict-prefix-and-its-validation)
and [strictness.md](strictness.md#products--consumers). It does not reason
through indirectly referenced, dynamically selected, or partially applied
callees.

Code: `src/expr/compiler/let_float.zig` with `let_float/planner.zig`,
`let_float/rewrite.zig`, and `let_float/model.zig`;
`src/expr/compiler/let_analysis/model.zig`, `let_analysis/walker.zig`, and
`let_analysis/finalize.zig`; `src/expr/compiler/demand_prefix.zig`; and
`src/expr/compiler/context.zig` (`let_units` registry field).
