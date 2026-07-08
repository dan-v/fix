# Architecture

*The whole system in one pass: what `fix` is, how an expression becomes a derivation, and how the pieces fit.*

`fix` is a from-scratch evaluator for the Nix expression language, written in Zig. It targets **parity with `nix-instantiate`** — byte-identical `.drv` store paths — while evaluating **in parallel** across many cores. The bet: Nix evaluation is a huge graph of independent lazy computations, so with cheap enough suspensions and a work-stealing scheduler, idle cores can force thunks ahead of demand without changing a single result.

Read this page first, then follow the reading order at the bottom.

## The evaluation pipeline

```
source text
  → scanner ─ tokens ─ LALR(1) parser        → AST            [syntax]
  → single-pass compiler                      → bytecode Chunk [compiler + bytecode]
  → threaded VM forces lazy thunks            → Value          [vm + runtime]
  → derivation builtins hash the drv graph    → .drv + store paths  [derivation]
```

Each stage is lazy at the seams: the compiler emits **thunks** for anything not needed immediately, and the VM forces them only on demand (or *speculatively*, ahead of demand, on idle cores).

- **[syntax](syntax/parsing.md)** — a streaming scanner and a table-driven LALR(1) parser build an arena-allocated AST. Nix's awkward corners (interpolation, indented strings, paths, `inherit`, attr patterns, dynamic attrs) are handled here → [nix-syntax](syntax/nix-syntax.md).
- **[compiler](compiler/pipeline.md)** — walks the AST once and lowers it to immutable **bytecode chunks**. It resolves names to stack slots and [upvalue captures](compiler/scopes.md), computes [strictness](compiler/strictness.md) masks, and decides what to make lazy vs eager vs [deferred](compiler/lazy-compile.md).
- **[runtime](runtime/values.md)** — the data model: an 8-byte NaN-boxed [`Value`](runtime/values.md), a flat [object heap](runtime/heap.md), string [interning](runtime/interning.md), and the [thunk](runtime/thunks.md) that carries laziness.
- **[vm](vm/dispatch.md)** — a direct-threaded bytecode interpreter that [forces thunks](runtime/thunks.md), [calls closures](vm/calls.md), [reads attrsets/lists](vm/access.md), and runs the [builtins](vm/builtins.md).
- **[derivation](derivation/model.md)** — the `derivation` builtins assemble a `Drv`, then [hash](derivation/hashing.md) it (ATerm serialization → SHA-256 → nixBase32) to compute store paths. [String context](derivation/context.md) tracks which store paths each string depends on.

## Two kinds of module

The build (`build.zig`, see [build](build.md)) splits the code into **clean-cut modules** and one **coupled core**:

```
containers ┐
syntax     │
runtime    ├─ genuinely acyclic → separate Zig modules, imported by name,
parallel   │   boundaries enforced by `zig build lint`
derivation │
cli        ┘

fix (core) ── bytecode · compiler · vm · eval · probe
              real dependency cycles (vm/force ↔ compiler/deferred,
              eval/worker ↔ vm/force) → stays one module
```

Six modules are genuinely tree-shaped and become real Zig modules: `containers` (lock-free deques shared by the GC and scheduler), `syntax`, `runtime`, `parallel`, `derivation`, and `cli`. Each exposes a single facade file; reaching into its internals is a lint error (it also silently duplicate-compiles into a second, incompatible type). `cli` sits on top and imports the `fix` core by name; the other five never import the core.

The core stays one module because it has genuine cycles that a module boundary would have to break with forward-declared interfaces buying nothing: the VM's `forceThunk` triggers on-demand compilation of deferred thunk bodies (`vm/force ↔ compiler/deferred`), and the parallel eval worker drives the VM while the VM's force path re-enters the worker to schedule and steal (`eval/worker ↔ vm/force`). So the engine lives together and is organised by directory instead. See [build](build.md).

## Laziness and parallelism are one primitive

The spine of the system is the [thunk / `Future`](runtime/thunks.md). A thunk is a suspended computation; in parallel mode it is *also* a one-shot concurrent cell. Exactly one [fiber](parallel/fibers.md) **claims** it (CAS `unresolved → evaluating`), runs the body, and **publishes** the result; any other fiber that reaches an in-flight thunk **parks** on its waiter list and is **woken** when the result lands. No duplicate execution, no lock held across evaluation. Imports use the same machine (an `ImportEntry` embeds a `Future`).

## The concurrency model

- **[Fibers](parallel/fibers.md)** — stackful user-space coroutines with x86-64 stack-switching. A yielded fiber is fully-captured, movable state, so it can be stolen and resumed on any worker. This is why the engine uses fibers, not OS threads: "steal the work while it waits."
- **[Scheduler](parallel/scheduler.md)** — per-worker Chase-Lev deques with two priorities: *urgent* (demand-driven fan-out, uncapped) and *speculative* (capped). Idle workers steal; parked workers spin then futex-sleep.
- **[Workers](parallel/workers.md)** — N symmetric workers; the main thread runs a top-level fiber and, whenever it parks, joins the others in stealing. It never idle-waits.
- **[Speculation & fan-out](parallel/speculation.md)** — the evaluator forces likely-needed thunks ahead of demand (speculation) and forks a collection's element thunks in parallel (fan-out), gated by [strictness](compiler/strictness.md) and bounded by a bail-on-demand brake so a wrong guess can't extend wall time.

## Why it's shaped this way (performance)

Measured on the NixOS toplevel at `--workers=32`, the main worker runs the **serial critical path** — the drv-hashing DAG and the module-system fixpoint — essentially without ever waiting, while helpers sit ~86% idle offloading ~99.7% of forces *off* the chain. The wall is therefore set by **dependency-chain depth**, not throughput: more parallelism can't lower it, and VM machinery is only ~7% of it. The only lever that moves the wall is eliminating real work *on the chain*. This finding drives nearly every design decision (lean thunks, frameless attr access, layered merges, ATerm bulk-copy). Read [perf/model](perf/model.md) before attempting any optimization — it also catalogs the many measured dead-ends.

## Correctness posture

- **Byte-identical `.drv`** vs Nix C++ is the oracle for every change. See [invariants](invariants.md).
- **The interpreter is the sole execution engine and is canonical.** The [GC](gc.md) is an optional subsystem (`-Dgc`, compiled into the default build; `-Dgc=false` builds the collector-free evaluator) that bounds RSS and never changes output — evaluation is byte-identical whether it is dormant, collecting, or absent.
- **Headroom is measured before it's built.** A suite of [probes](perf/probes.md) (compile-time `-D` flags) quantifies each lever's ceiling first.

## Reading order

1. **This page**, then [invariants](invariants.md) — the cross-cutting rules.
2. **Front end:** [syntax/parsing](syntax/parsing.md) → [syntax/nix-syntax](syntax/nix-syntax.md) → [compiler/pipeline](compiler/pipeline.md) (→ [scopes](compiler/scopes.md), [strictness](compiler/strictness.md), [lazy-compile](compiler/lazy-compile.md)).
3. **Data & engine:** [runtime/values](runtime/values.md) → [heap](runtime/heap.md) → [interning](runtime/interning.md) → [thunks](runtime/thunks.md); then [vm/dispatch](vm/dispatch.md) → [calls](vm/calls.md) → [access](vm/access.md) → [builtins](vm/builtins.md).
4. **Derivations:** [derivation/model](derivation/model.md) → [hashing](derivation/hashing.md) → [context](derivation/context.md).
5. **Parallelism:** [fibers](parallel/fibers.md) → [scheduler](parallel/scheduler.md) → [workers](parallel/workers.md) → [speculation](parallel/speculation.md) → [imports](parallel/imports.md).
6. **Performance & memory:** [perf/model](perf/model.md) → [perf/probes](perf/probes.md); [gc](gc.md).
7. **Operating it:** [build](build.md); [cli](cli.md).

Historical design notes and A/B logs live in [`docs/plans/`](plans/).
