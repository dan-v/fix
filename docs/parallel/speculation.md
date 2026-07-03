# Speculation & Fan-out

*How the evaluator does useful work ahead of demand, and how that work is kept safe and bounded.*

## Mental model

Nix evaluation is lazy: a value is computed only when forced. On one core that is optimal. On many cores it leaves helper [workers](workers.md) idle, because demand is a narrow serial chain. Speculation and fan-out **manufacture demand early** — they force thunks the demanded result *will probably* need, off the critical path, so the answer is already resolved (or in flight) by the time real demand arrives.

Two independent mechanisms, contributing roughly [~50/50 to the parallel speedup](../perf/model.md):

| Mechanism | Trigger | Action |
|---|---|---|
| **Speculation** | applying a closure whose body is *substantial* | submit the body-force to the speculation [queue](scheduler.md); continue with a lazy thunk |
| **Fan-out** | forcing a list/attrset (consumer), or entering a thunk body (producer) | submit one urgent task per element / per strict upvalue |

Neither changes results. Both are pure earliness: the [claim/waiter protocol](../runtime/thunks.md) guarantees each thunk resolves exactly once regardless of who forces it first.

---

## (a) Speculation

**Submission heuristic.** When a closure is applied, speculate iff the callee chunk is marked `body_is_substantial` — its compiled body is ≥ ~256 bytes, or [strictness analysis](../compiler/strictness.md) proved the argument eagerly forced. A `.force_thunk` task for the body goes to the speculation queue; the caller continues with a lazy thunk. The in-flight task runs the force with `in_speculation = true`.

**Why a size gate.** A trivial body (return-upvalue, constant) is cheaper to run inline than to package as a task — the [trivial-body short-circuit](../compiler/lazy-compile.md) skips thunk allocation for those entirely. The 256-byte line is where packaging pays off.

**Precision vs cost.** On `nixos_toplevel` the guesses are accurate — ~71% submission precision, and only **~0.2%** of speculative forces are ever *actually wasted* (undemanded). The real cost is not waste, it is **churn**:

- speculation inflates thunk creation ~+38%;
- ~+1.16M **duplicate resolves** across workers — the [force memo](../runtime/thunks.md) is per-worker, so a value one worker speculated can be recomputed by another (10.8% of bytecode-thunk forces are duplicates).

Cores are mostly idle, so duplicate CPU is nearly free; the churn is thunk-object allocation pressure, not wall time.

---

## (b) Fan-out

### Consumer strict-demand
Forcing a **list or attrset** with ≥ ~4 elements means every element is about to be demanded. Rather than force them serially, submit them urgently:

- **lists** — batched, up to 16 element-thunks per `ForceListRange` task;
- **attrsets** — one `.force_thunk` per entry thunk.

Helpers running these urgent tasks **fan out recursively** — forcing a list of imported modules fans out to each module, which fans out to its contents. The cascade is bounded by the urgent-[queue](scheduler.md) cap (~4096) and by the finite structure sizes.

### Producer strict-upvalue
Not a guess: [Phase-A shallow strictness masks](../compiler/strictness.md) mark upvalues a thunk body **provably forces**. On entering the body, those marked upvalues are forked urgent. Recursion is natural (each forked producer may itself have strict upvalues). **Shallow only** — deep-strictness prefetch cascaded catastrophically in Phase B and was removed.

---

## Safety & bounding

The danger: a speculatively-forced sibling that real demand *never touches* could be enormous (a whole unused package tree) and extend wall time past the serial baseline. Two guards prevent this.

### The `in_speculation` brake
Speculation and fan-out only fire from the **demand path**, never from within an already-speculative force (`in_speculation` short-circuits re-submission). Cascades stay **one layer deep**: a spec task can fan out its immediate children, but those children do not spawn their own speculation. This is the load-bearing invariant that keeps the working set finite.

### Bail-on-demand
Once the *demanded* result exists, `suppress_background` is set. Speculative [fibers](fibers.md) poll a cheap predicate before any long loop or large allocation and abandon:

```
specBailRequested(vm)  ==  vm.in_speculation && scheduler.backgroundSuppressed()

  at each checkpoint:
      if specBailRequested(vm):
          publish thunk failure = error.SpeculativeBail   # TRANSIENT
          return error.SpeculativeBail
```

`SpeculativeBail` is a **transient** error: it resets the thunk to unresolved so it is simply recomputed if *real* demand ever arrives. Nothing observable is lost.

**Builtin checkpoints.** Long-running builtins poll too: `genList` calls `specBailRequested` every 8192 iterations. Map-creation loops are *not* checkpointed on purpose — high allocation implies high input demand, so their inputs are already covered transitively.

### Why byte-identity is free here
Bail only fires **after** the demanded result already exists — so whatever a bailed speculation would have produced is either already computed or genuinely undemanded. The `.drv` is byte-identical regardless of how aggressively we bail. **There is no correctness knob to tune.**

Pathologies this fixes (bounded, not merely faster):
- a single huge never-demanded sibling: 6.6s → 0.018s;
- a 256-byte-body list: 0.16s → 0.084s.

---

## Contribution & floor

Measured on `nixos_toplevel`, w=32 (serial w=1 baseline 2.750s):

| Config | Wall |
|---|---|
| fan-out only | 1.938s |
| speculation only | 2.186s |
| both (best) | **1.247s** |

Fan-out is the bigger single lever; together they buy ~0.69s of earliness, roughly ~50/50. The remaining gap to the serial critical path is the **discovery-serialization floor**, discussed in [perf/model.md](../perf/model.md) — speculation cannot cross it.

---

## Invariants

- Speculation/fan-out **never** change a result — earliness only; the [claim protocol](../runtime/thunks.md) enforces exactly-once resolution.
- Cascades are **one layer deep** (`in_speculation` gate).
- Bail fires **only after** the demanded result exists ⇒ byte-identical, untunable.
- `SpeculativeBail` is **transient** — the thunk is reset and recomputed on real demand, never cached as an error.
- Submission fires **only from the demand path**.

## Debug flags

- `--no-spec-thunks` — turn off mechanism (a).
- `--no-fanout` — turn off mechanism (b).

See [cli.md](../cli.md).

Code: src/vm/force.zig, src/eval/
