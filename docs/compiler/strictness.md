# Strictness Analysis

*Compile-time must-force analysis: which captured upvalues a body provably evaluates, so the scheduler can pre-submit them.*

## Mental model

Nix is lazy, but many bindings are **provably forced** the instant a body runs. A `let x = …; in x + 1` forces `x` unconditionally. If the compiler proves a captured upvalue *must* be forced to compute the body, the scheduler can submit that thunk **deterministically and eagerly** (urgent, not speculative) — no waste, no waiting for demand. Strictness analysis computes that proof per chunk, at compile time, as a **sound under-approximation**: every upvalue in the mask is definitely forced; some forced upvalues may be missed (safe — worst case is a missed prefetch, never a wrongly-eager evaluation).

Two levels are tracked, because "forced" has two meanings:

- **shallow** — forced unconditionally to reduce the body to **weak-head normal form** (WHNF).
- **deep** — additionally forced when the *result* of the body is itself deep-forced (walked) by the caller. Captures the case where an upvalue only escapes *inside* a structure the body produces.

By construction `shallow(e) ⊆ deep(e)`.

## Semantic rules

Analysis is a bottom-up walk building a `{shallow, deep}` name-set pair per node. Only **free variables that resolve to upvalues** end up in a chunk's masks (locals are frame-private; separate chunks are analyzed independently).

| Node | shallow | deep |
| --- | --- | --- |
| identifier `x` | `{x}` | `{x}` |
| lambda value | ∅ | ∅ — a closure is atomic; its body is a *separate* chunk |
| literal (int/float/string/path) | ∅ | ∅ |
| attrset / list literal | ∅ | ⋃ `deep(value_i)` — building it forces nothing; walking it forces the elements' deeps |
| arithmetic / comparison / binop | ⋃ over operands | = shallow (result is primitive) |
| `if c then t else f` | `shallow(c)` ∪ (`shallow(t)` ∩ `shallow(f)`) | `deep(c)` ∪ (`deep(t)` ∩ `deep(f)`) |
| `assert g; body` | `shallow(g)` ∪ `shallow(body)` | union likewise |
| `let x = rhs in body` | substitute `x`'s references in `body` with `rhs`'s sets | likewise |
| `with s; body` (under must-force) | skip `s` (lazy lookup), take `body` | skip `s`, take `body` |
| `apply f x` | `shallow(f)` | `shallow(f)` — the arg is cross-chunk, a later phase |

Notes:

- **Branches intersect, condition unions.** An `if` forces the condition unconditionally, but only forces a name in a branch if it is forced in **both** branches — otherwise the untaken branch might skip it. (Intersection keeps the under-approximation sound.)
- **`let` substitution.** A binding used strictly in the body contributes its rhs's strictness *at the binding's use sites*; an unused binding contributes nothing.
- **`with` is skipped under force.** A `with`-scope expression is resolved lazily by `lookup_with`, so it is not counted as must-force; the body's own strictness still applies.
- **Atomic on lambdas.** Analysis **does not recurse into lambda bodies** — those are distinct chunks with their own masks. This keeps each chunk's analysis local and bounded.

## Encoding

The name-sets are lowered to `ChunkStrictness`: two **64-bit bitmasks over upvalue slots**.

```
ChunkStrictness {
  forced_upvalues: u64   // shallow — set bit i ⇒ upvalue i forced to WHNF
  deep_upvalues:   u64   // deep   — superset of forced_upvalues
}
```

Bit `i` corresponds to the chunk-relative [upvalue index](scopes.md) `i`. **Chunks with more than 64 upvalue slots degrade coverage** — slots ≥ 64 are simply dropped from the masks (still sound: a missed bit is a missed prefetch, never a wrong force). This is stamped onto the Chunk at **finish**, inside `SchedulingHints`.

## Runtime use

The masks feed the **scheduler**, not the interpreter's force path directly. When a chunk with strictness bits runs, the scheduler submits a **deterministic urgent** thunk for each provably-forced captured upvalue — distinct from [speculation](../parallel/speculation.md), which guesses. Because the force is proven, there is no wasted work: the value would have been forced anyway, just later and on the critical path.

The zero-capture case is elided entirely: a body that captures nothing needs no strictness stamp (the compile-time **zero-capture skip**). Strictness bits also gate `body_is_substantial ∧ has_strict` accounting used to reason about which chunks are worth speculating with a strictness hint.

Per-parameter strictness (for uncurried lambdas) is a sibling mechanism carried on the same `SchedulingHints` (`strict_param`): the saturated [`call_n`](pipeline.md) path eagerly forces the argument positions the callee marks must-force.

## History (Phase A / B)

- **Phase A (landed).** Compile-time shallow+deep masks per chunk — the analysis described here. Measured ~58% overlap between speculatable chunks and deep tracking.
- **Phase B (reverted).** A *runtime* prefetch that, at chunk entry, eagerly forced the masked upvalues. It proved **redundant with fan-out + speculation** (those already covered the same work), and **deep prefetch cascaded catastrophically** — deep-forcing an upvalue recursively pulled in unbounded structure. Reverted.
- **Zero-capture skip (landed).** Skipping the stamp for capture-free bodies — a sliver, byte-identical.

Net: strictness is consumed **only** as a scheduling *hint*, never as an eager-force at chunk entry.

## Invariants

- **Sound under-approximation.** Every masked upvalue is definitely forced; the analysis never marks a name that could go unforced.
- **`forced_upvalues ⊆ deep_upvalues`** always.
- **Local to the chunk.** No recursion into lambda/nested-chunk bodies; each chunk's masks describe only its own upvalues.
- **> 64 slots degrade, never break.** Dropping high slots loses prefetch, not correctness.
- **Hint-only.** Strictness influences *when* and *how urgently* a thunk is scheduled — never *whether* a value is computed or *what* it is. Removing all strictness bits leaves output byte-identical.

Out of scope: how the scheduler acts on the masks (submission, urgency, fan-out interaction) → [parallel/speculation.md](../parallel/speculation.md); thunk representation → [runtime/thunks.md](../runtime/thunks.md); the stamp site in the pipeline → [pipeline.md](pipeline.md).

Code: `src/compiler/`
