# Lazy & Elided Compilation

*Deferring compilation work that may never be needed, and eliding thunk machinery for bodies too trivial to warrant it.*

Two independent levers reduce compile-time and force-time cost:

- **(a) Deferred per-attr compilation** — don't compile an attribute's value body until it's forced (for huge generated attrsets).
- **(b) Trivial-body short-circuits** — for bodies that reduce to a single value with no real work, skip thunk allocation entirely.

Both preserve the correctness oracle: deferred bytecode is equivalent to eager bytecode; a short-circuited thunk yields the same value. Both reference [runtime/thunks.md](../runtime/thunks.md) (thunk targets) and interact with [speculation](../parallel/speculation.md).

---

## (a) Deferred per-attr compilation

### Problem

Some Nix files are enormous machine-generated attrsets (e.g. `hackage-packages.nix`) — tens of thousands of attributes, most never forced in a given evaluation. Compiling every value body up front is wasted work when a consumer touches a handful.

### Gates (`deferred_table.zig`)

`attrs.shouldDeferSet` defers an attrset's value bodies only when **all** hold:

| Gate | Constant | Why |
| --- | --- | --- |
| file / import scope | `source_path != null` | need retained source + AST arena to recompile later |
| ≥ 64 entries | `MIN_ENTRIES = 64` | coarse pre-filter; skip the snapshot machinery for small sets |
| body span ≥ 100 bytes | `MIN_BODY_BYTES = 100` | **the real lever** — defer only when the compile cost beats the deferral bookkeeping |
| ≤ 32 snapshot entries | `MAX_SCOPE = 32` | snapshot must stay small (lexical bindings + active `with` subjects; perl-packages.nix needs ~16) |
| deferrable leaves | — | value bodies must be recompilable in isolation |

### Mechanism

At compile time, for a deferring set:

1. **Snapshot the enclosing scope** — capture the ancestor bindings visible to the value bodies, each resolved to a `.local` slot or `.upvalue` index, then the subject values of the active `with` scopes (innermost-first, via `collectWithScopes` — the same capture plumbing a with-lookup uses), all capped at `MAX_SCOPE`. The entry records how many trailing snapshot slots are with-subjects (`with_count`).
2. **Register an `Entry` per leaf** — the value's AST node + that scope snapshot, into the deferred table (keyed by a table id). The snapshot is **adopted once** (`adoptScope`) and shared by every entry of the set, and the base/source paths are content-deduped (`internPath`), so a 19k-entry generated set does not dupe 19k copies. The evaluator **retains the file's source text and AST arena** so the node stays live.
3. **Emit `thunk_defer`** — carrying the table id + an environment descriptor array (the snapshot, as [capture descriptors](scopes.md)). The attrset is built with these as deferred thunks.

At **force time** (`deferred.compile`), on first demand:

1. Build a **synthetic single-level parent** whose locals `0..k-1` are exactly the snapshot names, in declaration order — and whose `with_scopes` stack re-establishes the set site's with nesting over the trailing `with_count` env slots (pushed outermost-first, so the body's with-lookups collect them innermost-first, exactly as the eager compile saw them).
2. Compile the value body as a **child of that parent**, pre-seeding the child's captures with the same snapshot names 1:1 — so `resolveCaptureId`'s dedup maps every free variable to a fixed upvalue index `i` **equal to its position in the thunk's env** (env index `i`). No force-time remap.
3. Funnel through **`finishCompiledChild`** (the same tail eager compilation uses — strictness stamp, terminate, finish, register), then **CAS-cache** the resulting `ChunkId` so concurrent forcers converge on one chunk.

```
compile time:   snapshot scope → register Entry(node, snapshot) → emit thunk_defer(table_id, env-desc)
force time:     synthetic parent(locals = snapshot) → compile child (captures pre-seeded, upvalue i == env i)
                → finishCompiledChild → register → CAS-cache ChunkId
```

### Correctness

- **Byte-identical to eager.** The synthetic-parent trick guarantees the produced bytecode is equivalent to what an eager compile emitted — the only difference is *when* it is compiled, and internal upvalue numbering (never observable in output).
- **Concurrency-safe.** Each forcer builds its own chunk on a per-body scratch arena; `ChunkRegistry.register` bumps a lock-free atomic cursor (`StableSegments.appendAtomic`), so racers get distinct `ChunkId`s; the CAS on the entry's cached `compiled` word (`ChunkId + 1`, `0` = uncompiled) then ensures a single winner (the loser's chunk is orphaned but correct). Runs on any worker.
- **Elision-aware.** A deferred leaf's body may itself be an `.elided` span that the parser never parsed; `deferred.compile` sub-parses it at first force (into a throwaway arena, never mutating the shared AST), so a syntax error inside an elided body surfaces at force time rather than parse time.
- **One funnel.** Deferred and eager compilation share `finishCompiledChild`, so strictness stamping / trivial classification / registration are identical.

---

## (b) Trivial-body short-circuits

### Problem

Many thunks wrap a body that does essentially nothing — return an upvalue, a constant, `null`, or a single attr access. Allocating a heap thunk, submitting it, forcing it, and pushing/popping a frame is pure overhead when the body reduces to one value (the short-circuit cuts a heap alloc, a future force, a frame push/pop, and two dispatches per occurrence).

### Classification (`classifyTrivialBody`, at chunk finish)

The finished body is classified **once** into one of the `TrivialBody` variants below, else `none` (safe because thunk bodies have [`local_count == 0`](scopes.md), which pins the possible instruction shapes). The result is stored as `SchedulingHints.trivial : TrivialBody` (`push_const_ret` and the `push_null|push_true|push_false` bodies both classify as `literal`):

| Shape | Body bytecode | Yields |
| --- | --- | --- |
| `identity_upvalue N` | `up_get_ret N; halt` | upvalue `N` verbatim |
| `literal` (constant) | `push_const_ret idx; halt` | constant pool entry (Value copied at classify time) |
| `literal` (immediate) | `push_null｜push_true｜push_false; ret; halt` | the immediate |
| `attr_access U N` | `up_get_attr U N; ret; halt` (7 bytes) | attr `N` of upvalue `U` |
| `closure_zero CL` | `closure CL, 0; ret; halt` | capture-free closure |
| `closure_captures CL,K,…` | `closure_cap CL, K, descriptors; ret; halt` | closure with K captures |
| `builtins` | `push_builtins; ret; halt` | the builtins attrset alias |
| `none` | anything else | (full thunk required) |

### Effect

When such a body would be wrapped at a `thunk` site, the compiler instead **pushes the value directly** — skipping heap thunk allocation, scheduler submission, force, and frame push/pop. For `closure_*` and `attr_access` shapes the descriptors/operands are read straight from the classification. The value produced is identical to forcing the thunk would have produced.

### Keeping the speculation threshold calibrated

Emit-time super-op fusion (see [pipeline.md](pipeline.md)) shrinks a body's encoding, which would make it look *smaller* than it is to the [speculation](../parallel/speculation.md) size gate. The `*_get_attr` and `thunk*_st(_cell)` rewrites each add their saved byte to **`ChunkBuilder.fusion_savings`** (string-interpolation lowering adjusts it too); `fusion_savings` is added back to `code.len` when computing `body_is_substantial`, so `SPECULATION_MIN_CODE_BYTES` measures the *pre-fusion* body size and fusion never silently changes which bodies are deemed substantial enough to speculate. The `<op>_ret` rewrite that produces the trivial shapes above is not recorded — those bodies are a handful of bytes and never approach the 256-byte threshold anyway.

---

## Invariants

- **Deferral changes only *when*.** Deferred bytecode ≡ eager bytecode (modulo internal upvalue numbering); output is byte-identical.
- **Classify runs once, over the frozen body**, guarded by `local_count == 0` — the shape set is exhaustive for thunk bodies.
- **Short-circuit ≡ force.** Pushing the trivial value directly yields exactly what forcing the thunk would have.
- **Fusion is size-neutral to the scheduler.** `fusion_savings` (fed by the `*_get_attr` and store-fusion rewrites) restores the pre-fusion byte count for the `body_is_substantial` decision.

Out of scope: thunk states / how `thunk` and force behave → [runtime/thunks.md](../runtime/thunks.md); how substantial bodies get speculated → [parallel/speculation.md](../parallel/speculation.md); emission & fusion → [pipeline.md](pipeline.md).

Code: `src/nix/compiler/`
