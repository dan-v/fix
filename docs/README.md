# `fix` developer documentation

*A parallel evaluator for the Nix expression language, in Zig.*

`fix` parses and evaluates Nix expressions to values and derivations. It targets
the same derivation text and store paths as `nix-instantiate`, and can schedule
thunk evaluation across worker threads. The pages introduce the system before
describing the invariants that changes must preserve.

**Start with [architecture](architecture.md)** for the whole system in one pass and the recommended reading order, then [invariants](invariants.md) for the cross-cutting rules every change must respect.

## Map

**Overview** — [architecture](architecture.md) · [invariants](invariants.md)

**Front end** — [`syntax/`](syntax/)
- [parsing](syntax/parsing.md) — scanner + LALR(1) table-driven parser + arena AST
- [nix-syntax](syntax/nix-syntax.md) — strings, paths, `inherit`, patterns, operators

**Compiler** — [`compiler/`](compiler/)
- [pipeline](compiler/pipeline.md) — AST → bytecode chunks
- [scopes](compiler/scopes.md) — locals, upvalue captures, `with`
- [strictness](compiler/strictness.md) — compile-time must-force analysis
- [let-float](compiler/let-float.md) — demand-driven `let` binding placement rewrite
- [full-laziness](compiler/full-laziness.md) — floating param-independent bindings and MFEs out of lambdas
- [lazy-compile](compiler/lazy-compile.md) — deferred compilation + trivial-body elision
- [chunk-cache](compiler/chunk-cache.md) — persistent per-unit compiled-bytecode cache

**Runtime** — [`runtime/`](runtime/)
- [values](runtime/values.md) — NaN-boxed `Value` + numeric semantics
- [heap](runtime/heap.md) — object store + layered `//` merge
- [interning](runtime/interning.md) — string/symbol table
- [thunks](runtime/thunks.md) — **the laziness + concurrency primitive**
- [concurrency verification](concurrency-testing.md) — deterministic races,
  TLA+, TSan, and reproducible seeded stress

**VM** — [`vm/`](vm/)
- [dispatch](vm/dispatch.md) — threaded interpreter + bytecode format
- [calls](vm/calls.md) — closures, currying, call-site strictness
- [access](vm/access.md) — attr/list access, merge, equality, strings
- [builtins](vm/builtins.md) — the primops and how they're dispatched

**Derivations** — [`derivation/`](derivation/)
- [model](derivation/model.md) — the `Drv` and how `derivation` builds one
- [hashing](derivation/hashing.md) — ATerm serialization, hashing, and store paths
- [context](derivation/context.md) — string context tracking

**Parallelism** — [`parallel/`](parallel/)
- [fibers](parallel/fibers.md) — stackful, stealable coroutines
- [scheduler](parallel/scheduler.md) — work-stealing deques, urgent/spec queues
- [workers](parallel/workers.md) — worker model + eval driver
- [speculation](parallel/speculation.md) — speculation + fan-out ahead of demand
- [imports](parallel/imports.md) — import dedup + the discovery floor

**Performance** — [`perf/`](perf/)
- [model](perf/model.md) — **cost model, critical-path floor, measured dead-ends**
- [probes](perf/probes.md) — the `-D` headroom-measurement suite
- [hugetlb](perf/hugetlb.md) — 2 MB huge-page heap backing (`--hugetlb`)

**Memory management**
- [gc](gc.md) — non-moving generational collector used to reclaim evaluator
  heap storage

**Operating**
- [build](build.md) — module layout, `-D` flags, lint, tests
- [cli](cli.md) — commands + introspection tools
- [store-compatibility](store-compatibility.md) — daemon protocol client + Nix store interop

## Conventions

- Docs describe **the system** — mechanisms, data flow, invariants, and the
  reason each exists — rather than narrating edits or refactors. Subsystem docs
  finish with a `Code:` pointer to the relevant implementation area.
- The interpreter is the execution engine. Collection and diagnostic probes
  must not change language results. Derivation text and store paths are covered
  by focused tests and differential workload checks.
