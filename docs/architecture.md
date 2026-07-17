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
  → realization recipes + nix-daemon client  → .drv files in the store, built
                                                outputs, result links  [store]
```

Each stage is lazy at the seams: the compiler emits **thunks** for anything not needed immediately, and the VM forces them only on demand (or *speculatively*, ahead of demand, on idle cores).

- **[syntax](syntax/parsing.md)** — a streaming scanner and a table-driven LALR(1) parser build an arena-allocated AST. Nix's awkward corners (interpolation, indented strings, paths, `inherit`, attr patterns, dynamic attrs) are handled here → [nix-syntax](syntax/nix-syntax.md).
- **[compiler](compiler/pipeline.md)** — walks the AST once and lowers it to immutable **bytecode chunks**. It resolves names to stack slots and [upvalue captures](compiler/scopes.md), computes [strictness](compiler/strictness.md) masks, and decides what to make lazy vs eager vs [deferred](compiler/lazy-compile.md).
- **[runtime](runtime/values.md)** — the data model: an 8-byte NaN-boxed [`Value`](runtime/values.md), a flat [object heap](runtime/heap.md), string [interning](runtime/interning.md), and the [thunk](runtime/thunks.md) that carries laziness.
- **[vm](vm/dispatch.md)** — a direct-threaded bytecode interpreter that [forces thunks](runtime/thunks.md), [calls closures](vm/calls.md), [reads attrsets/lists](vm/access.md), and runs the [builtins](vm/builtins.md).
- **[store / derivation](derivation/model.md)** — the domain model: `Drv`, canonical hashing and paths, string context, and the evaluation-scoped registry of computed derivations. The `derivation` builtins assemble a `Drv`, then [hash](derivation/hashing.md) it (ATerm serialization → SHA-256 → nixBase32) to compute store paths.
- **store / realization** — turns derivation records and source-path recipes into concrete store actions. It owns the evaluation's `RealizationStore`, lazy derivation cache, source snapshots and NAR encoding, closure planning, realization claims, and nix-daemon protocol/runtime. An explicit executor capability lets evaluator fibers park without making the store depend on evaluator workers.
- **fetchers** — remote source acquisition outside the expression engine: remote-source caching, Git/curl transports, and provider-specific GitHub/GitLab/SourceHut request planning. VM builtins only decode Nix values and map fetch results back to values.

## The module DAG

The source tree has seven durable module groups. `base`, `syntax`, and `runtime` are reusable foundations; `store` owns derivations and concrete store behavior; `fetchers` owns remote source acquisition; `nix` contains the cooperating evaluator subsystems; `cli` is the application layer. Subsystems under each durable root keep their own facades and namespaces, but use ordinary file imports rather than each restating the same graph as a build module.

```
src/base/       base → base_options
                Generic containers, synchronization, fibers, allocators,
                blocking pools, clocks, and memory backing.

src/syntax/     syntax → base, parser_tables
                Scanner, parser, AST; independently benchmarked.

src/runtime/    runtime → base, build_options
                Value, heap, thunk/Future, interning, GC.

src/store/      store → base, runtime
                Derivations, source snapshots, NAR, realization recipes,
                daemon protocol and runtime.

src/fetchers/   fetchers → base, runtime, store, libcurl, libgit2
                Remote-source cache, provider planning, transports.

src/nix/        nix → base, syntax, runtime, store, fetchers, build_options
                Exports bytecode, compiler, evaluator workers, language support, observability,
                probes, VM, and Evaluator.

src/cli/        cli → nix, base
                Commands, options, rendering, debugger.

src/main.zig       → nix, cli, process_support
                Process composition; executable `fix`.
```

`base` is generic enough to be a standalone library. The one place the evaluator would otherwise leak its taxonomy *into* `base` is dependency-inverted: the RSS tracker is `Vma(comptime Tag)`, and `nix` supplies the concrete `MemTag` enum at instantiation, so the generic mechanism never names an application memory bucket.

Within `nix` the layering mirrors the [pipeline](#the-evaluation-pipeline): `compiler/context.zig` and `vm/context.zig` own state, their sibling drivers own recursive dispatch, and `eval.zig` composes those services into `Evaluator`. `eval/workers/` owns the scheduler, fiber workers, fiber-scoped context, and capabilities for parking futures and blocking work away from compute workers; the VM borrows that context and capability without owning worker machinery. `store/realization/daemon_execution.zig` defines the store-facing executor capability, while `eval/workers/daemon_executor.zig` supplies its fiber implementation. `root.zig` is the narrow stable facade visible to ordinary consumers, including typed build/evaluation progress protocols and diagnostic views; commands that intentionally inspect representation details opt into the explicitly unstable `nix.tooling` surface. Deferred-body compilation calls from `vm` into `compiler`, while import orchestration and synthetic corepkgs sources remain evaluator-owned and `eval/imports.zig` owns only the concurrent registry/entry state. See [build](build.md).

Callbacks mark real ownership, policy, or execution-domain changes: CLI debugger/progress/build sinks, heap/scheduler GC dispatch, fiber wakeups, blocking execution, and leaf policies such as NAR filters. File extraction alone is not a boundary. Evaluator helper files therefore receive concrete state views (for example debugger `Context`) or remain evaluator-owned instead of back-calling through opaque “host” bundles. Concurrent progress `Span` handles retain the sink that created them, so a sink replacement cannot misroute an in-flight token.

## Laziness and parallelism are one primitive

The spine of the system is the [thunk / `Future`](runtime/thunks.md). A thunk is a suspended computation; in parallel mode it is *also* a one-shot concurrent cell. Exactly one [fiber](parallel/fibers.md) **claims** it (CAS `unresolved → evaluating`), runs the body, and **publishes** the result; any other fiber that reaches an in-flight thunk **parks** on its waiter list and is **woken** when the result lands. No duplicate execution, no lock held across evaluation. Imports use the same machine (an `ImportEntry` embeds a `Future`).

## The concurrency model

- **[Fibers](parallel/fibers.md)** — stackful user-space coroutines with x86-64 stack-switching. A yielded fiber is fully-captured, movable state, so it can be stolen and resumed on any worker. This is why the engine uses fibers, not OS threads: "steal the work while it waits."
- **[Scheduler](parallel/scheduler.md)** — per-worker work-stealing queues, classed by submission lane: an *urgent* lane (demand-driven fan-out, a lock-free Chase-Lev deque, uncapped) and capped, best-effort *speculative* lanes (a mutex-protected bounded ring). Idle workers steal; parked workers spin then futex-sleep.
- **[Workers](parallel/workers.md)** — N symmetric workers; the main thread runs a top-level fiber and, whenever it parks, joins the others in stealing. It never idle-waits.
- **[Speculation & fan-out](parallel/speculation.md)** — the evaluator forces likely-needed thunks ahead of demand (speculation) and forks a collection's element thunks in parallel (fan-out), gated by [strictness](compiler/strictness.md) and bounded by a bail-on-demand brake so a wrong guess can't extend wall time.

## Why it's shaped this way (performance)

Measured on the NixOS toplevel at `--workers=32`, the main worker runs the **serial critical path** — the drv-hashing DAG and the module-system fixpoint — essentially without ever waiting, while helpers sit ~86% idle offloading ~99.7% of forces *off* the chain. The wall is therefore set by **dependency-chain depth**, not throughput: more parallelism can't lower it, and VM machinery is only ~7% of it. The only lever that moves the wall is eliminating real work *on the chain*. This finding drives nearly every design decision (lean thunks, frameless attr access, layered merges, ATerm bulk-copy). Read [perf/model](perf/model.md) before attempting any optimization — it also catalogs the many measured dead-ends.

## Correctness posture

- **Byte-identical `.drv`** vs Nix C++ is the oracle for every change. See [invariants](invariants.md).
- **The interpreter is the sole execution engine and is canonical.** The [GC](gc.md) is part of every supported build; it bounds RSS and never changes output — evaluation is byte-identical whether it stays dormant or collects.
- **Headroom is measured before it's built.** A suite of [probes](perf/probes.md) (compile-time `-D` flags) quantifies each lever's ceiling first.

## Reading order

1. **This page**, then [invariants](invariants.md) — the cross-cutting rules.
2. **Front end:** [syntax/parsing](syntax/parsing.md) → [syntax/nix-syntax](syntax/nix-syntax.md) → [compiler/pipeline](compiler/pipeline.md) (→ [scopes](compiler/scopes.md), [strictness](compiler/strictness.md), [lazy-compile](compiler/lazy-compile.md)).
3. **Data & engine:** [runtime/values](runtime/values.md) → [heap](runtime/heap.md) → [interning](runtime/interning.md) → [thunks](runtime/thunks.md); then [vm/dispatch](vm/dispatch.md) → [calls](vm/calls.md) → [access](vm/access.md) → [builtins](vm/builtins.md).
4. **Derivations:** [derivation/model](derivation/model.md) → [hashing](derivation/hashing.md) → [context](derivation/context.md).
5. **Parallelism:** [fibers](parallel/fibers.md) → [scheduler](parallel/scheduler.md) → [workers](parallel/workers.md) → [speculation](parallel/speculation.md) → [imports](parallel/imports.md).
6. **Performance & memory:** [perf/model](perf/model.md) → [perf/probes](perf/probes.md); [gc](gc.md).
7. **Operating it:** [build](build.md); [cli](cli.md).

Historical design notes and A/B logs live in [`docs/superpowers/plans/`](superpowers/plans/).
