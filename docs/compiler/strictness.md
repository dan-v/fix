# Strictness Analysis

*Compile-time force analysis: which names a body provably evaluates, so the compiler can pass eager values and the scheduler can race work ahead of demand.*

## Mental model

Nix is lazy, but many bindings are **provably forced** the instant a body runs. `let x = …; in x + 1` forces `x` unconditionally. If the compiler proves a value *must* be forced to compute a body, it can evaluate it eagerly (no thunk) — the value would have been forced anyway, just later and on the critical path. If it proves a value *may* be forced, it can submit that work speculatively so a helper races it ahead of demand. Strictness analysis (`strictness.zig`) computes both proofs per body, at compile time, from one AST walk.

Because there are two different consumers, the walk tracks two directions of soundness:

- **may-force** — forced on *some* evaluation path. An over-approximation is safe here: acting on it can only waste speculative work, never change a result.
- **must-force** — forced on *every* path before any other observable effect. A sound *under*-approximation is required: eager evaluation is only correct for something lazy evaluation would force regardless (it can reorder which error surfaces in an already-failing eval, never turn a success into a failure).

And two *depths* of forcing:

- **shallow** — forced to reduce the body to **weak-head normal form** (WHNF).
- **deep** — additionally forced when the *result* of the body is itself deep-forced (walked) by the caller. Captures the case where a value only escapes *inside* a structure the body produces (an attrset/list literal builds nothing but its elements get forced if walked).

The walk therefore maintains three name-sets per node: `shallow` (may, WHNF), `shallow_must` (must, WHNF), and `deep` (may, deep). By construction `shallow_must ⊆ shallow ⊆ deep`.

## Semantic rules

Analysis is a bottom-up walk building the three name-sets per node. Only **free variables** end up in the sets; a `let`/lambda binding shadows its name via the analyzer's bound-stack, and a binding's references expand to its RHS's sets.

| Node | shallow (may) | shallow_must (must) | deep |
| --- | --- | --- | --- |
| identifier `x` | `{x}` | `{x}` | `{x}` |
| lambda value | ∅ | ∅ | ∅ — a closure is atomic; its body is a *separate* chunk |
| literal (int/float/string/path) | ∅ | ∅ | ∅ |
| attrset / list literal | ∅ | ∅ | ⋃ may(`value_i`) — building forces nothing; walking forces the elements |
| arithmetic / comparison / `//` / `++` | ⋃ over operands | ⋃ over operands | = shallow (result primitive) |
| `&&` / `\|\|` / `->` | left only | left only | left only — right is short-circuiting |
| `if c then t else f` | may(`c`) ∪ (may(`t`) ∩ may(`f`)) | must(`c`) ∪ (must(`t`) ∩ must(`f`)) | likewise |
| `assert g; body` | shallow(`g`) ∪ shallow(`body`) | shallow_must(`g`) only | union over both |
| `with s; body` | shallow(`s`) ∪ shallow(`body`) | shallow_must(`body`) only | union over both |
| `let x = rhs in body` | expand `x`'s uses in `body` to `rhs`'s sets | likewise | likewise |
| `apply f x` | shallow(`f`) | shallow_must(`f`) | shallow(`f`) — the arg is cross-chunk, a later phase |
| `a.b or d`, `a.${k} or d` | base of the chain only | base only | base only |

Notes:

- **Branches intersect, condition unions.** An `if` forces the condition unconditionally, but only forces a name in a branch if it is forced in **both** branches — otherwise the untaken branch might skip it.
- **`assert` / `with` diverge between may and must.** An `assert` body runs only if the guard passes, and a `with`-scope expression is resolved lazily by `lookup_with` — so both contribute to the *may* sets but **not** to `shallow_must`. This is the only place the two shallow sets differ.
- **`or`-chains short-circuit.** Only a lookup chain's base is unconditionally evaluated; a later segment may be skipped when an earlier one misses, so dynamic-segment names are never marked.
- **Atomic on lambdas.** Analysis **does not recurse into `lambda` / `lambda_attrs` bodies** — those are distinct chunks with their own masks. This keeps each analysis local and bounded.

## Products & consumers

The three sets are computed once and consumed by four call sites:

**1. Per-chunk upvalue masks (`stampOnBuilder`).** At the end of compiling a chunk body, the `shallow` and `deep` name-sets are lowered against the chunk's capture list into `ChunkStrictness`:

```
ChunkStrictness {
  forced_upvalues: u64   // shallow — set bit i ⇒ upvalue i may be forced to WHNF
  deep_upvalues:   u64   // deep    — superset of forced_upvalues
}
```

Bit `i` corresponds to the chunk-relative [upvalue index](scopes.md) `i`. **Chunks with more than 64 upvalue slots degrade coverage** — slots ≥ 64 are dropped from the masks (still safe: a missed bit only loses information, never forces anything wrongly). These masks are stamped onto `SchedulingHints.strictness` and read by the [disassembler](../vm/dispatch.md) and by the chunk-registry statistics (`speculatable_with_strictness`, surfaced in `fix inspect`) — they are informational, not consulted on the force path.

**2. Eager `let`-binding submission (`analyzeLetBindings`).** For a `let`, the same walk over the body yields, per binding, its `shallow` (may) and `shallow_must` (must) membership. A binding the body **may-forces** is emitted as a `thunk_captures_eager` thunk — the runtime submits it to the scheduler's **urgent queue** at creation, so a helper races it ahead of demand instead of waiting for the size heuristic. See [lazy-compile.md](lazy-compile.md) and [parallel/speculation.md](../parallel/speculation.md).

**3. Eager `let`-binding elision (`analyzeLetBindings` + `firstForcedName`).** A binding the body **must-forces**, that is non-recursive and forward-reference-free, is compiled straight into its slot with **no thunk at all**. Restricted to the single binding the body demands *first* (`firstForcedName`) so eager order equals lazy order and no error is reordered.

**4. Per-parameter must-force (`bodyMustForceName`).** A single-parameter lambda whose body must-forces its parameter sets `strict_param` (a caller holding the closure passes its argument eagerly); a forwarder `x: f x` records `f`'s upvalue index in `strict_via_upvalue`; an uncurried lambda records a per-parameter `strict_params` bitmask that the saturated [`call_n`](pipeline.md) path forces eagerly. A directly-applied strict lambda `(x: body) arg` likewise lets the caller pass `arg` eagerly.

The **zero-capture case is elided**: `stampOnBuilder` returns early for a capture-free body, since its mask would be all-zero anyway — the whole analysis walk is skipped, byte-identically.

## Invariants

- **Two soundness directions, one walk.** `shallow`/`deep` are may-force (over-approximations, safe for scheduling/speculation); `shallow_must` is a sound must-force under-approximation (safe for eager evaluation). `shallow_must ⊆ shallow ⊆ deep`.
- **Local to the chunk.** No recursion into lambda/nested-chunk bodies; each analysis describes only its own free variables.
- **> 64 upvalue slots degrade, never break.** Dropping high slots loses information, not correctness.
- **Hint- and reorder-only.** Strictness influences *when* and *how urgently* a value is computed (and lets already-inevitable forces happen without a thunk) — never *whether* a value is computed or *what* it is. Removing all strictness signals leaves output byte-identical (modulo which error surfaces first in a failing eval).

Out of scope: how the scheduler acts on eager submissions (urgency, fan-out interaction) → [parallel/speculation.md](../parallel/speculation.md); thunk representation → [runtime/thunks.md](../runtime/thunks.md); the stamp site in the pipeline → [pipeline.md](pipeline.md).

Code: `src/compiler/strictness.zig`
</content>
