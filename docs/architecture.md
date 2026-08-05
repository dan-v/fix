# Architecture

*The whole system in one pass: what `fix` is, how an expression becomes a derivation, and how the pieces fit.*

`fix` is a from-scratch evaluator for the Nix expression language, written in
Zig. It targets the same evaluated values, derivation text, and store paths as
`nix-instantiate`. Its runtime can force thunks on multiple worker threads,
including work submitted ahead of demand.

Read this page first, then follow the reading order at the bottom.

## The evaluation pipeline

```
source text
  → scanner ─ tokens ─ LALR(1) parser        → AST            [syntax]
  → bytecode compiler + analyses              → bytecode Chunk [compiler + bytecode]
  → threaded VM forces lazy thunks            → Value          [vm + runtime]
  → derivation builtins serialize and hash    → .drv text + store paths [derivation]
  → realization recipes + nix-daemon client  → .drv files in the store, built
                                                outputs, result links  [store]
```

The compiler uses thunks at lazy positions. The VM normally forces them on
demand; the scheduler may also submit eligible thunks speculatively.

- **[syntax](syntax/parsing.md)** — a streaming scanner and a table-driven LALR(1) parser build an arena-allocated AST. Nix's awkward corners (interpolation, indented strings, paths, `inherit`, attr patterns, dynamic attrs) are handled here → [nix-syntax](syntax/nix-syntax.md).
- **[compiler](compiler/pipeline.md)** — recursively lowers the AST to
  **bytecode chunks**, with separate name, reference, and
  [strictness](compiler/strictness.md) analyses where needed. It resolves names
  to stack slots and [upvalue captures](compiler/scopes.md), decides what to
  make lazy, eager, or [deferred](compiler/lazy-compile.md), and — per `let` —
  runs a scoped rewrite that [places bindings](compiler/let-float.md) at their
  demand point before classifying what's left.
- **[runtime](runtime/values.md)** — the data model: an 8-byte NaN-boxed [`Value`](runtime/values.md), a flat [object heap](runtime/heap.md), string [interning](runtime/interning.md), and the [thunk](runtime/thunks.md) that carries laziness.
- **[vm](vm/dispatch.md)** — a direct-threaded bytecode interpreter that [forces thunks](runtime/thunks.md), [calls closures](vm/calls.md), [reads attrsets/lists](vm/access.md), and runs the [builtins](vm/builtins.md).
- **[store / derivation](derivation/model.md)** — the domain model: `Drv`, canonical hashing and paths, string context, and the evaluation-scoped registry of computed derivations. The `derivation` builtins assemble a `Drv`, then [hash](derivation/hashing.md) it (ATerm serialization → SHA-256 → nixBase32) to compute store paths.
- **store / realization** — turns derivation records and source-path recipes into concrete store actions. It owns the evaluation's `RealizationStore`, lazy derivation cache, source snapshots and NAR encoding, closure planning, realization claims, and nix-daemon protocol/runtime. An explicit executor capability lets evaluator fibers park without making the store depend on evaluator workers.
- **fetchers** — remote source acquisition outside the expression engine. `FetchService` owns cache/transport lifecycle; `fetch/` owns borrowed configuration, request/result values, authentication, and narrow URL/Git/Mercurial views. VM builtins only decode Nix values and map fetch results back to values.

## The module DAG

The source tree has seven durable module groups. `base`, `syntax`, and `runtime` are reusable foundations; `store` owns derivations and concrete store behavior; `fetchers` owns remote source acquisition; `expr` owns the expression engine; and `cli` is the application layer. Subsystems under each durable root keep their own facades and namespaces, but use ordinary file imports rather than each restating the same graph as a build module.

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

src/expr/       expr → base, syntax, runtime, store, fetchers, build_options
                Bytecode, compiler, builtins, VM, evaluator workers,
                language support, observability, and probes.

src/cli/        cli → base, expr, runtime, syntax, store
                Commands, options, rendering, debugger.

src/main.zig       → cli, process_support
                Process composition; executable `fix`.
```

`base` is generic enough to be a standalone library. The one place the evaluator would otherwise leak its taxonomy *into* `base` is dependency-inverted: the RSS tracker is `Vma(comptime Tag)`, and the runtime supplies the concrete `MemTag` enum at instantiation, so the generic mechanism never names an application memory bucket.

Within `expr` the layering mirrors the [pipeline](#the-evaluation-pipeline): `compiler/context.zig` and `vm/context.zig` own state, their sibling drivers own recursive dispatch, and `evaluator.zig` composes those services into `Engine`. Construction takes one borrowed `EngineConfig` value. Engine helper files receive narrow state or execution capabilities at real ownership boundaries; callers use concrete Engine operations instead of whole-object forwarding views. `eval/workers/` owns the scheduler, fiber workers, fiber-scoped context, and capabilities for parking futures and blocking work away from compute workers; queue mechanics live below scheduler policy in `eval/workers/scheduler/`. The VM borrows worker capabilities without owning worker machinery. `store/realization/daemon_execution.zig` defines the store-facing executor capability, while `expr/eval/workers/daemon_executor.zig` supplies its fiber implementation. The CLI consumes `expr`, `runtime`, `syntax`, and `store` directly instead of routing them through an umbrella module. Deferred-body compilation calls from `vm` into `compiler`, while import orchestration and synthetic corepkgs sources remain engine-owned and `eval/imports.zig` owns only the concurrent registry/entry state. See [build](build.md).

Callbacks mark real ownership, policy, or execution-domain changes: CLI debugger/progress/build sinks, heap/scheduler GC dispatch, fiber wakeups, blocking execution, and leaf policies such as NAR filters. File extraction alone is not a boundary. Engine helper files therefore receive concrete state views (for example debugger `Context`) or remain engine-owned instead of back-calling through opaque “host” bundles. Concurrent progress `Span` handles retain the sink that created them, so a sink replacement cannot misroute an in-flight token.

The VM explorer is one private UI state machine split into focused implementation
modules. Calls within a module are direct; `Explorer.Ops.<subsystem>` spelling is
reserved for cross-subsystem coordination and import-cycle breaking. The
registry is deliberately not presented as a capability boundary.

## Ownership and state changes

Ownership is represented in types, not parallel flags. Text that may be
borrowed or heap-owned uses `base.TextRef`; `deinit` consumes a pointer and frees
only the `.owned` case. Owned configuration replacement is transactional:
allocate/parse the replacement first, then swap it into live state and release
the old value. A failed update therefore leaves the previous configuration
intact.

Long-lived mutable owners are kept few and explicit (`Engine`, `FetchService`,
`ObjectHeap`, `Scheduler`). `ObjectHeap` alone owns its segmented stores and
immutable failure store; evaluator and CLI code use counts, snapshots, and
semantic failure operations. Read-only heap projection types, object summaries,
post-evaluation censuses, and probe reporting live in `runtime/heap/inspection.zig`,
separate from allocation and collection. Their inputs and intermediate decisions are values:
`EngineConfig`/`FetchConfig`, parsed source units, `LetPlan` (and the
[let-float](compiler/let-float.md) immutable `Graph` plus rewrite `Plan` it consumes),
derivation artifacts, and validated REPL command invocations. Orchestrators sequence those
values through named phases; mechanisms such as heap range reuse, inspection
projections, scheduler queues, and CLI option application live in focused
subdirectories. This preserves mutation where identity or concurrency requires
it without making mutation the default modeling tool.

## Laziness and parallelism are one primitive

The spine of the system is the [thunk / `Future`](runtime/thunks.md). A thunk is
a suspended computation; in parallel mode it is also a concurrent cell. One
[fiber](parallel/fibers.md) at a time claims an unresolved thunk and runs its
body. Other fibers reaching that attempt can park on its waiter list. A
successful result or deterministic error is memoized; explicitly transient
failures reset the thunk for a later attempt. Imports use the same `Future`
protocol in an `ImportEntry`.

## The concurrency model

- **[Fibers](parallel/fibers.md)** — stackful user-space coroutines with x86-64 and AArch64 stack-switching. A yielded fiber carries its evaluation state and can be stolen and resumed by another worker; OS-thread-local services are resolved again through non-inlined accessors after migration.
- **[Scheduler](parallel/scheduler.md)** — per-worker work-stealing queues, classed by submission lane: an *urgent* lane (demand-driven fan-out, a fixed-capacity lock-free Chase-Lev deque) and capped, best-effort *speculative* lanes (a mutex-protected bounded ring). Idle workers steal; parked workers spin then futex-sleep.
- **[Workers](parallel/workers.md)** — N workers; the main thread runs the
  top-level fiber and participates in the drain loop while that fiber is
  parked.
- **[Speculation & fan-out](parallel/speculation.md)** — the evaluator forces likely-needed thunks ahead of demand (speculation) and forks a collection's element thunks in parallel (fan-out), gated by [strictness](compiler/strictness.md) and bounded by bail-on-demand and per-task budgets.

## Why it's shaped this way (performance)

On the NixOS workload recorded in [perf/model](perf/model.md), scaling is
bounded by a serial critical path through module evaluation and derivation
hashing. That observation motivated lean thunks, frameless attr access, layered
merges, and bulk ATerm construction. It is a measured workload result, not a
property asserted for every Nix expression.

## Correctness posture

- Matching derivation text and store paths is a compatibility target covered by
  derivation tests and differential workloads. See [invariants](invariants.md).
- The interpreter is the execution engine. The [GC](gc.md) is part of every
  supported build and must preserve evaluator results while reclaiming storage.
- **Headroom is measured before it's built.** A suite of [probes](perf/probes.md) (compile-time `-D` flags) quantifies each lever's ceiling first.

## Reading order

1. **This page**, then [invariants](invariants.md) — the cross-cutting rules.
2. **Front end:** [syntax/parsing](syntax/parsing.md) → [syntax/nix-syntax](syntax/nix-syntax.md) → [compiler/pipeline](compiler/pipeline.md) (→ [scopes](compiler/scopes.md), [strictness](compiler/strictness.md), [lazy-compile](compiler/lazy-compile.md)).
3. **Data & engine:** [runtime/values](runtime/values.md) → [heap](runtime/heap.md) → [interning](runtime/interning.md) → [thunks](runtime/thunks.md); then [vm/dispatch](vm/dispatch.md) → [calls](vm/calls.md) → [access](vm/access.md) → [builtins](vm/builtins.md).
4. **Derivations:** [derivation/model](derivation/model.md) → [hashing](derivation/hashing.md) → [context](derivation/context.md).
5. **Parallelism:** [fibers](parallel/fibers.md) → [scheduler](parallel/scheduler.md) → [workers](parallel/workers.md) → [speculation](parallel/speculation.md) → [imports](parallel/imports.md).
6. **Performance & memory:** [perf/model](perf/model.md) → [perf/probes](perf/probes.md); [gc](gc.md).
7. **Operating it:** [build](build.md); [cli](cli.md).
