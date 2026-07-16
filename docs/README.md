# `fix` developer docs

*A parallel evaluator for the Nix expression language, in Zig. These docs describe the system you're about to modify.*

`fix` parses and evaluates Nix expressions to values and derivations, aiming for **byte-identical `.drv` output** to `nix-instantiate` while evaluating **in parallel** — idle cores force lazy thunks ahead of demand without changing any result. ~56k lines of Zig.

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
- [lazy-compile](compiler/lazy-compile.md) — deferred compilation + trivial-body elision

**Runtime** — [`runtime/`](runtime/)
- [values](runtime/values.md) — NaN-boxed `Value` + Nix-parity numerics
- [heap](runtime/heap.md) — object store + layered `//` merge
- [interning](runtime/interning.md) — string/symbol table
- [thunks](runtime/thunks.md) — **the laziness + concurrency primitive**

**VM** — [`vm/`](vm/)
- [dispatch](vm/dispatch.md) — threaded interpreter + bytecode format
- [calls](vm/calls.md) — closures, currying, call-site strictness
- [access](vm/access.md) — attr/list access, merge, equality, strings
- [builtins](vm/builtins.md) — the primops and how they're dispatched

**Derivations** — [`derivation/`](derivation/)
- [model](derivation/model.md) — the `Drv` and how `derivation` builds one
- [hashing](derivation/hashing.md) — ATerm → store paths; the byte-identity oracle
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
- [hugetlb](perf/hugetlb.md) — 2 MB huge-page heap backing (`--hugetlb`, w=1 −8.3%)

**Memory** — the interpreter stays canonical
- [gc](gc.md) — non-moving generational collector that bounds RSS; never changes output

**Operating**
- [build](build.md) — module layout, `-D` flags, lint, tests
- [cli](cli.md) — commands + introspection tools

## Conventions

- Docs describe **the system** — mechanisms, data flow, invariants, and the *why* — not the text of specific `.zig` files. Each doc ends with a `Code:` pointer to its area.
- The **interpreter is the sole engine and is canonical**; collection and diagnostic probes never change output. Byte-identical `.drv` is the ground truth for correctness.
- Historical plans and the living A/B performance log are in [`plans/`](plans/) — design intent and status, kept separate from these system docs.
