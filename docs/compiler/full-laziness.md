# Full Laziness: Level-Aware Sharing Across Applications

*An extension of [let-float](let-float.md) in the opposite direction: an
expression inside a lambda that does not depend on the lambda's parameters
floats OUT of it, so every application shares one thunk (evaluated at most
once) instead of re-creating — and possibly re-evaluating — it per call.*

**Default ON** since the 2026-08-05 qualification. `FIX_NO_FULL_LAZY=1` is
the kill switch: both the analysis walk and the transform stand down
entirely, and the flag participates in the chunk-cache key so cached
bytecode never crosses the gate.

## Mental model

Let-float's many-region rule — never move thunk *creation* into a region
that may run repeatedly — read backwards is exactly this pass's win
condition: when an expression's value cannot vary across the applications
of its enclosing lambda, moving its creation out of the lambda converts
per-call work into once-per-closure work. Two forms:

- **Named floats**: a `let` binding whose RHS is parameter-independent
  moves out of the lambda wholesale (the binding keeps its name; use sites
  are untouched — the name simply resolves through ordinary scope/upvalue
  chains from farther away).
- **Anonymous MFEs** (maximal free expressions): a parameter-independent
  `.apply` subtree with no name at all is bound to a fresh synthetic name
  and replaced by a reference to it.

Both land in **AROUND position**: `let floated… in <lambda>` wrapped
around the lambda *expression* in its parent context. The thunk is created
once per closure creation and shared by every application of that closure.
Wrapping the body instead would recreate the thunk per call and share
nothing — around-position is what realizes the level-0 (unit root) home
uniformly, including for the outermost lambda (the driver hook rebuilds
the whole lambda expression, so the wrap composes there too).

Evaluation *timing* is unchanged: a floated thunk is still forced exactly
when the original expression would first be demanded (wrap-lets have a
lambda body, so the strict-prefix walk never eagerizes them). What changes
is *identity*: N applications share one thunk instead of owning N
equal-valued ones. Sticky errored thunks make shared failures replay with
the origin trace plus each demand site's own frames, same as Nix's own
sharing.

## Lévy levels

The analysis walker's `many_depth` is the level clock: the lambda at
nesting depth L introduces level L; its parameters live at level L; a
`let`/`rec` binder lives at the depth where it sits. An expression's
**floor** is the max level over its free names' *resolved binders* — the
outermost lambda it can escape. Names that resolve outside the walk
(builtins, outer compile scope) are level 0; `with`-resolvable misses,
elided source, and skip-slot resolutions (`inherit`-outer, rec-`inherit`)
are immobile.

Two invariants the level arithmetic gives for free:

- **Scope validity**: a binder at level ≤ L was pushed before entering the
  level-L+1 lambda, so it encloses the wrap position. No separate scope
  proof is needed for the moved expression's frees.
- **Resolution stability**: if a binder *between* the wrap position and
  the original site shadowed a free name, the site would have resolved to
  that (deeper) binder, contradicting the floor. Frees resolve identically
  at both positions.

### Named floats: fused fixpoint + decision

Binding levels are decided in one outer-first pass **fused with the float
decision**: dependents read siblings' *landed* levels, and every refusal
(shadow, chain, no destination, capture) resets the binding to its home
level before dependents read it. Deciding from theoretical floors instead
deadlocks in practice — a dependent floats above a sibling whose own float
was refused, and evaluates against an unbound name.

### The inverse-capture proof

Hoisting a binder grants its NAME new visibility over the destination's
whole body. A mention of that name in the newly-covered region — before
the cluster (`[dest, header)`) or after it (`[end, ∞)`) — previously
resolved elsewhere (an outer binder, or dynamically through `with`, which
lexical resolution outranks) and would silently re-resolve to the hoisted
binding. The walk keeps a global mention log (mentions advance the walk
clock, like `with` marks, so a cluster closing right after a mention is
distinguishable from a later sibling); the float refuses names mentioned
in the window.

**Opaque spans are scanned lazily.** Elided function bodies and
interpolated strings crossed *outside any active cluster* are logged as
spans (one clock tick, no per-word interning): interning and resolving
every identifier-shaped word of every never-compiled body measured as an
11% w=1 tax on warm nixos-minimal — the entire cost of the pass. The
capture proof instead text-scans only the spans whose clock position falls
inside a proposed float's window, for the one name being hoisted.

## Anonymous MFEs (tier 1: applies)

The walker threads per-subtree facts — max free level, an opacity bit, and
a saturating apply count — and seals a candidate at each `.apply` whose
facts prove parameter-independence (`level < many_depth`). Facts cost
nothing extra: lambda exits clamp body facts to `introduced − 1`, which is
*exact* (inner binders all sit at ≥ introduced, outer ones below).

- A candidate that is a whole named RHS is skipped (the named pass owns
  it). A candidate in FUNC position of an enclosing apply (a call-spine
  prefix, through parens) never seals: floating a partial application
  splits the uncurried `call_n` chain into generic 1-ary calls and defeats
  saturated-builtin opcode lowering (`s: builtins.getAttr "x" s` must keep
  its fused opcode, not share a `getAttr` partial application). Descendant candidates at ≥ the sealing level are subsumed — the
  outer wrap shares their computation wholesale, and an outer-or-equal
  float would otherwise strand their synthetic references outside their
  own wraps' scope. Descendants at lower levels survive (they float
  farther, so their bindings still enclose this one).
- The wrap binds a fresh `"\x00fl.<n>"` name — unspellable, so
  collision- and capture-free — encoded as `Atom{len = 0, offset =
  InternId}`. `attr_names.identText` is the choke point; every
  identifier/name-span reader handles the encoding (a missed reader is an
  out-of-bounds source slice at an InternId offset — Debug builds catch
  it).
- The replacement expression at the original site is the synthetic
  identifier; the wrap's RHS is a *shallow clone* of the candidate: same
  children, so nested replacements and wraps still apply through it during
  the rebuild; fresh root pointer, so the replacement cannot fire inside
  the wrap itself.
- `FIX_FL_MFE_MIN_APPLIES` (default 1) gates candidates by contained
  apply count; `FIX_FL_NAMED_OFF` stands down the named pass. Both are
  A/B levers and both participate in the chunk-cache key — sweeping a
  threshold without keying it mixes cached bytecode across configurations.

### Emission-time soundness checks

Two rules found by real failures, checked against the candidate's recorded
chain of enclosing named-binding RHSes:

- **Stranding**: an enclosing binding whose home is inside the wrap lambda
  (`home ≥ level + 1`) but whose landed level is outside (`assigned <
  level`) would carry the synthetic reference — inside its RHS — out of
  the wrap's scope. Blocked (`blocked_mfe_enclosing`).
- **Recursion**: inside a recursive group's RHS, per-call thunks of the
  same expression each terminate through laziness, but ONE shared thunk
  can be re-demanded during its own force via the group. nixpkgs'
  `extendDerivation` (`commonAttrs`/`outputsList` in
  `lib/customisation.nix`) turns from terminating into `RecursiveThunk`.
  Blocked wholesale for SCC-recursive or self-referential enclosing
  bindings (`blocked_mfe_recursive`). This guard is *enclosing-SCC only*;
  a cycle routed through closure flow (a free whose force applies a
  closure of the destination lambda, fixpoint-style) would evade it — the
  nixpkgs monolithic differential is the standing arbiter.

Chain-inner destinations (mid-uncurry-chain lambdas) are blocked for both
forms — a wrap between curried params splits the arity-N `call_n` chunk.
This is the largest coverage lever left (~100 named + ~800 MFE
candidates blocked on nixos-minimal); lifting it needs a split-benefit
gate.

## Census and qualification

`FIX_LET_FLOAT_STATS=1` extends the let-float census: candidates, floats,
and blocked-reason counters for both forms. **Warm-cache censuses
undercount** — cache-hit chunks never walk.

nixos-minimal (cold, w=1): 1,327 named floats, 5,331 anonymous MFEs
(5,815 candidates; 363 chain-, 121 recursion-blocked).

Qualification snapshot (2026-08-05, same-binary A/B, warm cache):
`torture/shared-mfe` 383ms→6ms and `json/wide-call-tree` 440ms→10ms
(the memo-proof shapes the pass exists for); `hm-profile` and
`json/nixpkgs-package-metadata` −6%; realworld nixos-minimal and all
tripwire fixtures (`string-*`, `spec-pathology`, `json/*`) neutral.
Full-universe monolithic differential 80,586/80,586 with floats active;
peak RSS +0.3%; universe w=8 wall neutral; w=16 neutral-to-better; w=32
(SMT-oversubscribed past the scheduler knee) ~+3% on nixos-desktop with
no scheduler-counter degradation — the accepted cost at that operating
point.

## Semantic-divergence ledger

| Divergence | Status |
|---|---|
| `trace` inside a shared expression fires once, not per call | Accepted (this IS the transform); e2e locks counts |
| Shared errored thunk replays origin trace + demand-site frames | Accepted + tested; same shape as Nix thunk sharing |
| `with`/dynamic scope | Prevented (dynamic frees are immobile; mention log guards inverse capture) |
| drvPath / string contexts | None — monolithic differential is the arbiter |
