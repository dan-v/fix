# Speculation & Fan-out

*How the evaluator does useful work ahead of demand, and how that work is kept safe and bounded.*

## Mental model

Nix evaluation is lazy: a value is computed only when forced. On one core that is optimal. On many cores it leaves helper [workers](workers.md) idle, because demand is a narrow serial chain. Speculation and fan-out **manufacture demand early** — they force thunks the demanded result *will probably* need, off the critical path, so the answer is already resolved (or in flight) by the time real demand arrives.

Neither changes results. Both are pure earliness: the [claim/waiter protocol](../runtime/thunks.md) guarantees each thunk resolves exactly once regardless of who forces it first, so a bad guess costs CPU, never correctness.

| Mechanism | Trigger | Action |
|---|---|---|
| **Speculation** | creating a thunk whose body is *substantial* | submit the body-force to the speculation [queue](scheduler.md); continue with a lazy thunk |
| **Fan-out (consumer)** | strict-forcing a list/attrset | submit batched range tasks so its elements resolve in parallel |
| **Sibling prefetch** | a demand attr lookup missing on an unresolved member of a mid-sized attrset | sweep the whole attrset's still-unresolved members |

---

## (a) Speculation

**Submission heuristic.** `makeThunk` speculates a freshly created thunk iff `shouldSpeculateClosure` holds:

- for a **user closure**, its chunk's `body_is_substantial` bit — set at chunk registration when the compiled body (plus fusion savings) is ≥ `speculation_min_code_bytes` = **256 bytes**;
- for a **`builtin_closure`** whose builtin id is `mapValue`, `mapAttrValue`, or `zipAttrsValue` (the per-element wrappers `map` / `mapAttrs` / `zipAttrsWith` build around a user function), when that inner function (its `args[0]`) is itself a substantial closure or a *known-expensive* builtin — `import`, `scopedImport`, `fetchurl`/`fetchTarball`/`fetchGit`/`fetchTree`, `readFile`/`readFileType`/`readDir`, `derivation` (`isExpensiveBuiltin`). Trivial map bodies (`x: x + 1`) fail the closure size gate, and `derivationLazyAttr` is explicitly excluded, so speculation doesn't wander into unobserved package graphs.

When it fires, a `force_thunk` task for the body goes to the speculation queue and the caller continues with a lazy thunk; the task runs the force with `speculation.active = true`.

**Why a size gate.** A trivial body (return-upvalue, constant) is cheaper to run inline than to package as a task — the [trivial-body short-circuit](../compiler/lazy-compile.md) skips thunk allocation for those entirely. The 256-byte line is where packaging pays off.

**Novel-chunk priority lane.** The **first** speculative instance of any chunk — a new code region, a potential subsystem or chain root — is routed to the high-priority [novel lane](scheduler.md) (`FIX_SPEC_NOVEL`) via `submitNovel` instead of the bulk backlog; repeat instances stay in the bulk lane. `novelClosureChunk` is a test-and-set on the chunk's "spec submitted" bit, so the routing costs one flag flip and the lane's total volume is bounded at one task per chunk. This keeps a lone chain-seed thunk from having to win a pop/steal race against hundreds of repeat-instance junk tasks.

**The real cost is churn, not waste.** Because the [claim protocol](../runtime/thunks.md) resolves each thunk once, a wrong guess is rarely *wasted* on undemanded work — it is *duplicate* work (the force memo is per-worker, so a value one worker speculated can be recomputed by another) and *allocation pressure* (speculation inflates thunk creation). At high worker counts cores are mostly idle, so the duplicate CPU is nearly free; the pressure it puts on the heap is the cost that matters, which the bounding below caps.

---

## (b) Fan-out

### Consumer strict-demand
Strict-forcing a **list or attrset** with ≥ `fan_out_min_items` = **4** elements means every element is about to be demanded. Rather than force them serially, `forceListAccelerate` / `forceAttrsAccelerate` submit the elements as **batched urgent range tasks** — up to `fan_out_batch_items` = **16** slots per `force_list_range` / `force_attrs_range` task. Batching pays the queue + wake overhead once per meaningful chunk of work instead of once per thunk (the attrs heap layout is a positional slice, so the same offset/len shape serves both).

Helpers running these urgent tasks **fan out recursively** — forcing a list of imported modules fans out to each module, which fans out to its contents. The cascade is bounded by the urgent-[queue](scheduler.md) cap (`urgent_queue_capacity` = 4096 per worker; a rejected push falls back to serial forcing) and by the finite structure sizes.

Saturated uncurried calls also use the chunk's strictness-derived `strict_params` mask (`forceStrictArgs`) to force must-force argument positions to WHNF in place on the stack. This is ordinary demand evaluation, not a scheduler submission.

### Sibling prefetch
On a **demand** fiber's inline-cache miss that lands on a still-unresolved thunk member of a plain attrset whose entry count is in `[sibling_min, sibling_max)` = **[16, 64)**, `maybeSiblingSweep` submits one `force_attrs_sweep` task for the whole set. `FIX_SIBLING` defaults on for 2–16 workers and can override that gate. The size range avoids sweeping large package sets; once-per-set deduplication and per-member claim/creation budgets bound wasted work.

A further `readdir_prefetch` lane (`FIX_READDIR_PREFETCH`, on by default whenever helpers exist) warms the [file cache](workers.md) with a directory-of-directories' children when a cold `builtins.readDir` is about to walk them serially on the chain.

---

## Safety & bounding

The danger: a speculatively-forced sibling that real demand *never touches* could be enormous (a whole unused package tree) and extend wall time past the serial baseline. Three guards prevent this.

### The speculation brake
Speculation and fan-out only fire from the **demand path**, never from within an already-speculative force (`speculation.active` short-circuits re-submission). Cascades stay **one layer deep**: a spec task can fan out its immediate children, but those children do not spawn their own speculation. This is the load-bearing invariant that keeps the working set finite.

### Bail-on-demand
Once the *demanded* result exists, the [worker driver](workers.md) sets `suppress_background`. Speculative [fibers](fibers.md) poll a cheap predicate before any long loop or large allocation and abandon:

```
specBailRequested(vm)  ==  vm.speculation.active and
                           (scheduler.backgroundSuppressed() or over-budget)

  at each checkpoint:
      if specBailRequested(vm):
          publish thunk failure = error.SpeculativeBail   # TRANSIENT
          return error.SpeculativeBail
```

`SpeculativeBail` is a **transient** error: it resets the thunk to unresolved so it is simply recomputed if *real* demand ever arrives (never cached as a sticky error). Nothing observable is lost. Long-running builtins poll too: `genList` calls `specBailRequested` every 8192 iterations.

### Per-task creation budgets
`specBailRequested` also fires when an untrusted-band spec task exceeds its creation budget (`FIX_SPEC_BAND_BUDGET`), or a sibling sweep exceeds its per-member claim/creation budgets. A wrong guess's cascade is abandoned once it reaches its budget, while urgent, demand-adjacent tasks stay unbounded. Bailing here is likewise a transient reset — resolved sub-thunks are kept.

### Why byte-identity is free here
Bail fires **only after** the demanded result already exists (or a bounded budget is blown) — so whatever a bailed speculation would have produced is either already computed or genuinely undemanded. The `.drv` is byte-identical regardless of how aggressively we bail. **There is no correctness knob to tune.**

---

## Contribution & floor

Fan-out and speculation are independent levers and each contributes a substantial share of the parallel speedup on realistic workloads; measured contributions and the residual **discovery-serialization floor** they cannot cross live in [perf/model.md](../perf/model.md).

## Invariants

- Speculation/fan-out **never** change a result — earliness only; the [claim protocol](../runtime/thunks.md) enforces exactly-once resolution.
- Cascades are **one layer deep** (`speculation.active` gate).
- Bail fires **only after** the demanded result exists (or a budget is blown) ⇒ byte-identical, untunable.
- `SpeculativeBail` is **transient** — the thunk is reset and recomputed on real demand, never cached as an error.
- Submission fires **only from the demand path**.

## Debug flags

- `--no-spec-thunks` — turn off mechanism (a).
- `--no-fanout` — turn off mechanism (b).

See [cli.md](../cli.md). The `FIX_*` tuning knobs named above are read once before workers start.

Code: `src/expr/vm/force.zig`, `src/expr/vm/force_speculate.zig`, `src/expr/vm/closures.zig`, `src/expr/vm/access.zig`, `src/expr/eval/workers/worker.zig`
