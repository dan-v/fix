# Source-tree cleanup — module reorganization

Goal: slice the codebase at its real joints. One enforced convention for
cross-subsystem references (named `build.zig` modules — `@import("runtime")`,
not `@import("../../runtime/value.zig")`), no inline `@import` in function
bodies, a top-level `main.zig` that is pure composition, and files/functions
that each do one thing.

## Validated module DAG (bottom → top, provably acyclic)

Verified by static import analysis (2026-06-26): with the assignment below,
**zero** cross-module back-edges against this order.

```
support → frontend → runtime → derivation → concurrency → core → eval → cli → main
```

- **support** — leaves, depend on nothing (or each other within order):
  `token`, `diagnostic`, `trace` (EvalTrace), `progress`, `worker_id`,
  `stable_segments`, `prof`, `timeline`.
- **frontend** — `scanner`, `string_syntax`, `ast`, `parser/`.
- **runtime** — `value`, `types`, `heap`, `thunk`, `intern`, `int`, `numeric`,
  `hash`, `version`, `nar`, `regex`, `toml`, `paths`, `file_cache`,
  `fetch_cache`, `struct_census`, `builtins` (value registry), `hot` (per-chunk
  JIT hot-counter, was `tjit/hot.zig`), `prof_path`.
- **derivation** — `derivation/`, `source_path`, `debug_record`.
- **concurrency** — `scheduler`, `fiber`.
- **core** — the execution engine (one organ, see below): `bytecode/`,
  `compiler/` (incl. `deferred_table`), `jit` + `jit_linear` + `tjit/`, `vm/`,
  `worker`, `thunk_trace`, `ngram_probe`, `trace_probe`.
- **eval** — `evaluator` (was `eval.zig`), `imports`, `search_path`, `print`, `run`.
- **cli** — `args`, `run`, `render`, `repl`, `style`, `stats`, subcommands,
  `derivation_debug` (was `derivation/debug.zig`, a terminal renderer).
- **main** — composition only.

### Why `core` is one module (cycle analysis, 2026-06-26)

A finer grouping (separate `compile`/`vm`/`jit`) produced cross-module cycles
that are *real*, not misfilings: `bytecode/chunk.zig` embeds
`jit.CompiledFn` pointers and `ChunkRegistry` drives `jit.compile()` on
registration; `jit` reads `vm/force`; `vm/force` calls `compiler/deferred` for
lazy per-attr compilation; `worker` drives the VM and `vm/force` calls back
into `worker`. bytecode + compiler + jit + vm + worker form one
strongly-connected component. Intra-module file cycles are fine in Zig, so they
live in one `core` module with internal `bytecode/ compiler/ jit/ vm/` folders.
A future refinement *could* split `compiler` out by making the chunk→jit pointer
opaque and routing lazy-compile-on-force through a callback — deferred, not done.

Misfilings that needed relocation (done in P1):

- `runtime/source_path.zig` (store-path aware) → `derivation/source_path.zig`.
- `deferred.zig` (the deferred-compile `Table`) → `compiler/deferred_table.zig`.
- `eval/trace.zig` (EvalTrace, needs only `diagnostic`) → `support/trace.zig`.
- `worker.zig` (out of the false `concurrency` grouping) → `eval/worker.zig`
  (its true module is `core`; P2 places it under `core/`).

Reclassifications realized as folder moves in P2: `builtins.zig`→runtime,
`prof_path`→runtime, `tjit/hot.zig`→runtime, `eval/progress.zig`→support,
`derivation/debug.zig`→cli, `int`/`numeric`/`hash`/`version` stay runtime.

## Phases (each leaves the build green; one commit each)

- [x] **P1 — cycle-dissolving relocations** (single module, no build.zig change):
      moved the 4 misfiled files. Static analysis confirms the 9-module
      assignment is a clean DAG. No `BuiltinId` extraction needed (builtins is a
      runtime file; its apparent cycles were intra-runtime).
- [ ] **P2 — folder hierarchy**: move remaining files into `support/ frontend/
      runtime/ derivation/ concurrency/ core/ eval/ cli/`. Fix relative imports.
- [ ] **P3 — named modules**: register the 9 modules in `build.zig`, rewrite
      cross-module `@import` to `@import("<module>")`. Compiler enforces the DAG.
- [ ] **P4 — slim main.zig**: extract `cli/args`, `cli/run`, `cli/render`,
      `cli/stats`; each subsystem exposes its own `reportStats(writer)`.
- [ ] **P5 — kill inline `@import`**: hoist the 96 in-body imports to top-of-file
      (or module facade) decls.
- [ ] **P6 — split overgrown files** that do several things (NOT the hot dispatch
      loop): focused single-purpose files, small functions.

## Invariants

- `zig build` and `zig build test` green after every phase.
- `.drv` output byte-identical (this is a perf-tuned evaluator; reorg must be
  behavior-preserving). Spot-check with `test/nixos_toplevel.nix`.
</content>
