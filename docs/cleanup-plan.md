# Source-tree cleanup — module reorganization

Goal: slice the codebase at its real joints. One enforced convention for
cross-subsystem references (named `build.zig` modules — `@import("runtime")`,
not `@import("../../runtime/value.zig")`), no inline `@import` in function
bodies, a top-level `main.zig` that is pure composition, and files/functions
that each do one thing.

## Mechanism (decided 2026-06-26, revised)

NOT "every subsystem is a build module" — that acyclic constraint distorted the
design (invented a `support` junk-drawer sink; collapsed compiler/vm/jit into one
blob). Instead:

- **Real `build.zig` modules only at the genuinely-acyclic clean cuts**:
  `syntax`, `runtime`, `derivation`, `parallel`. These don't participate in the
  engine's dependency cycle, so they isolate cleanly and get `@import("syntax")`.
- **One facade-organized module for the coupled engine** (`core`) + the
  orchestrator (`evaluate`). The engine is a genuine strongly-connected
  component (chunk↔jit, force↔compiler, worker↔vm), so it stays one module;
  Zig allows file cycles within a module.
- **The exposure pattern (one rule)**: a file imports only (a) files in its own
  subsystem folder, or (b) another subsystem's facade file — never another
  subsystem's internals. Enforced by a small lint test, not the build graph.
- Deep `../../facade.zig` paths are fine as long as they target a facade.

### Module map

| module | kind | contents |
|---|---|---|
| `syntax` | build module (leaf) | token, scanner, string_syntax, diagnostic, ast, parser/ |
| `runtime` | build module (leaf) | value, types, heap, thunk, intern, numeric, int, hash, version, nar, regex, toml, paths, worker_id, stable_segments, file_cache, fetch_cache, builtins, struct_census, prof, prof_path, timeline |
| `derivation` | build module | drv, aterm, store, paths, sort, types, value, debug_record, source_path |
| `parallel` | build module | scheduler, fiber |
| `core` | one module, facades inside | bytecode/, compiler/(+deferred_table), jit/(jit, jit_linear, tjit/, hot), vm/(+force, closures), worker, trace(EvalTrace), progress, thunk_trace, ngram_probe, trace_probe |
| `evaluate` | one module | evaluator (was eval.zig), imports, search_path, print, run |
| `cli` | exe-side | args, run, render, repl, style, stats, subcommands, derivation_debug |
| `main` | exe root | composition only |

Order of work: reorganize folders + facades first (single module, green per
subsystem), then flip the four clean cuts to real build modules last (avoids
rewriting imports twice).

## (superseded) earlier 9-module DAG

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
- [x] **P2a — `syntax` build module** (commit 36c8883): token/scanner/string_syntax/
      diagnostic/ast/parser → src/syntax/ + facade; ~44 sites → `@import("syntax")`.
- [x] **P2b — `runtime` build module** (commit d93e22b): + builtins/file_cache/
      fetch_cache moved in; ~250 sites → `@import("runtime")`. Shared build_options module.
- [x] **P2c — `parallel` build module** (commit de530b9): scheduler/fiber + swap asm.
- [x] **P2d — `derivation` build module** (commit 28b32bb): renderer debug.zig → cli.
- [x] **P4 — slim main.zig** (commit faf6291): 824 → 151 lines, composition only.
      Extracted cli/{args,stats,render,run,trace_setup} + repl driver into cli/repl.
- [x] **P5 — kill inline @imports** (commits 3c0cdf1, 929ee68): production code now
      has ZERO @import in function bodies / struct-field types. Confirmed the
      vm↔jit and intra-compiler file cycles resolve lazily within a module.
- [x] **P2g — import lint** (commit): tools/lint_imports.zig + `zig build lint`,
      depended on by `test`. Catches relative imports into a clean-cut module.
      Negative-tested. The facade convention is now self-enforcing.
- [x] **P2e — JIT + instrumentation consolidation** (commits): jit.zig +
      jit_linear.zig + tjit/ → `src/jit/`; prof + prof_path + timeline +
      ngram_probe + trace_probe + thunk_trace → `src/probe/`. All cross-refs
      recomputed by resolving against old layout. Default/-Djit/-Dtjit/all-probe
      builds green. Surfaced + fixed two pre-existing `-Dthunks-log` rot bugs
      (partial_app switch case; `*const`→`*ObjectHeap` after layered-merge made
      getAttrs non-const).
- [ ] **P2f — `evaluate` module** (optional, delicate): would give a 5th enforced
      boundary, but needs `worker` (SCC-coupled with vm/force) and `progress`
      relocated out of eval/ into the engine first. Higher risk, marginal gain.
- [ ] **P6 — split overgrown files** (optional): compile-time files (ops.zig
      1208, attrs.zig 829) are safe-ish; heap.zig/thunk.zig/vm/run.zig are hot —
      leave the dispatch loop alone. Judgment-heavy, marginal structural gain.
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
