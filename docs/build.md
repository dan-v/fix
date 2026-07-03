# Build

*The build graph, module layout, and hygiene that keep the fast paths honest.*

`fix` builds with `zig build` from a single `build.zig`. The build's shape is deliberate: a small ring of genuinely-acyclic subsystems are real Zig modules imported by name, while the coupled evaluator core stays in one module because it has real dependency cycles. The build also forces LLVM (the threaded dispatcher needs it), wires per-module unit tests by hand, and lints module boundaries.

## Model: clean-cut modules vs the coupled core

Zig's `@import("<name>")` reaches a module only through its facade; the compiler then enforces that outside code cannot touch the module's internal files. `fix` uses this to carve out the subsystems that are genuinely tree-shaped from the engine that isn't. See [architecture.md](architecture.md) for the boundary rationale and [plans/cleanup-plan.md](plans/cleanup-plan.md) for the migration history.

| Module | Facade | Imports | Notes |
|---|---|---|---|
| `syntax` | `src/syntax.zig` | — | lexer + parser + AST; no engine deps |
| `runtime` | `src/runtime.zig` | `build_options` | values, heap, interning, thunk representation |
| `parallel` | `src/parallel.zig` | `build_options`, `runtime` | fibers, scheduler, workers; adds arch asm `src/parallel/fiber/swap_x86_64.S` |
| `derivation` | `src/derivation.zig` | `runtime` | derivation model, hashing, context |
| `fix` (core) | `src/root.zig` | all of the above + `build_options` | bytecode, compiler, vm, eval/worker, support/trace, eval/progress, probe |

The core stays monolithic because its cycles are real: chunk↔jit, force↔compiler, worker↔vm. Splitting them would need forward-declared interfaces that buy nothing. Everything else is a named module; reaching into one by relative path is a lint error (below).

The `exe` module (`src/main.zig`) and both root test artifacts pull in `fix` plus the same shared imports via `addSharedImports`.

## Shared `build_options`

Every `-D` flag is folded into one `build_options` module created **once** and injected into `runtime`, `parallel`, `derivation`, `fix`, and `exe`. This is load-bearing: importing the generated options file into two *different* module instances makes Zig treat them as two distinct types, so a single shared instance is the only way every subsystem sees the same flag set (and the same `bool` type for each flag).

### `-D` flag surface

All are `bool`, off unless noted. Probe flags gate `-Dprof-main`-style instrumentation compiled into the core — see [perf/probes.md](perf/probes.md) for what each measures and the workers=1 caveats.

| Group | Flag | Effect |
|---|---|---|
| diagnostics | `vm-opcode-profile` | collect + print VM opcode execution counts |
| | `debug-checks` | VM dispatch invariant assertions (**defaults on** in Debug builds) |
| | `vm-trace` | enable VM execution tracing (surfaced by `--vm-trace`) → [cli.md](cli.md) |
| | `thunks-log` | per-thunk lifecycle event log (surfaced by `--thunks-log`) → [cli.md](cli.md) |
| | `fiber-stack-probe` | sentinel-fill fiber stacks for `maxStackUsedBytes`; forces full RSS commit |
| JIT | `jit` | experimental native-code JIT, x86_64 Linux only → [jit.md](jit.md) |
| | `tjit` | experimental tracing/inlining JIT (record→inline→sink→native + deopt) → [jit.md](jit.md) |
| probes | `prof-main` | rdtsc-time the main thread's hot serial paths → [perf/probes.md](perf/probes.md) |
| | `prof-path` | record the force-call tree + critical path (workers=1) → [perf/probes.md](perf/probes.md) |
| | `trace-probe` | tracing-JIT headroom: per-thunk read-count + body-size histograms → [perf/probes.md](perf/probes.md) |
| | `struct-census` | deforestation headroom: per-list/attrset consume-count histogram → [perf/probes.md](perf/probes.md) |
| | `drv-probe` | derivation-build demand: resolved-ahead vs forced-inline, fanout, DAG depth → [perf/probes.md](perf/probes.md) |
| | `opcode-ngram` | hottest adjacent opcode pairs for superinstruction fusion → [perf/probes.md](perf/probes.md) |
| | `timeline` | wall-clock per-worker event timeline; Perfetto JSON via `--timeline` → [perf/probes.md](perf/probes.md) |
| | `gc` | GC Phase 0: sample live set, report peak-live vs total-allocated → [gc.md](gc.md), [perf/probes.md](perf/probes.md) |
| compilation | `profile` | keep symbols + frame pointers (sets `strip=false`, `omit_frame_pointer=false`) |

Standard `zig build` options apply too: `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` and `-Dtarget=…`. Perf numbers assume `ReleaseFast` (or `ReleaseSafe`); `-Dprofile` only flips symbol/frame-pointer stripping, it does not change the optimize mode.

The `--vm-trace` / `--thunks-log` / `--timeline` runtime flags are inert unless the matching `-D` flag compiled the machinery in (`--timeline` on a non-`-Dtimeline` build prints a warning and is ignored). Probe flags have no runtime toggle — they are build-time only, so exercising a probe means a rebuild.

## Why LLVM is forced (`use_llvm = true`)

The threaded VM dispatcher (`src/vm/run.zig`) chains handlers with `@call(.always_tail)`. Only the LLVM backend implements guaranteed tail calls; the self-hosted backend would emit ordinary calls and the dispatch chain would **unbounded-recurse and blow the stack** — even in Debug. So `use_llvm = true` is pinned on the `exe` *and* on every `addTest` artifact, for all optimize modes.

## Per-module test wiring

`zig build test` (aliased by `check`) walks import graphs — but only a module's *own* `@import` graph. The root test artifacts (`mod_tests` over `fix`, `exe_tests` over `exe`) therefore collect **only** core-module tests; `runtime`, `syntax`, `parallel`, and `derivation` are pulled into `fix` by module *name*, so their unit tests are invisible to the root artifacts. Each clean-cut module needs its own `addTest` step, run explicitly:

```
test → lint, mod_tests, exe_tests, runtime_tests, syntax_tests, parallel_tests, derivation_tests
```

This wiring is easy to get wrong: a gap once silently skipped the `syntax`, `parallel`, and `derivation` unit tests entirely (they compiled, were just never *run*). When adding a clean-cut module, add its test step to `test_step` or its tests never execute.

Integration tests live in the core graph (`src/root/tests`, `src/eval/tests`) so the root artifacts pick them up; `test/*.nix` holds pathology and spec fixtures driven through eval.

## `zig build lint` — module-boundary hygiene

`tools/lint_imports.zig` (`zig build lint`, and a dependency of `test`) enforces the facade pattern. A stray `@import("../runtime/value.zig")` from a core file does **not** fail to compile — it drags that file into a second module instance, silently duplicating its types (`runtime.Value` ≠ the copy's `Value`) and producing baffling mismatches far from the cause. The linter walks every `src/**/*.zig`, resolves each relative `@import`, and errors (with `src/path:line`) if the target lands inside a clean-cut module's files or its facade. A file *inside* `src/<module>/` may import its own module's internals freely; only cross-boundary reaches are rejected. Use `@import("<module>")` across a boundary, always.

## The correctness gate

The oracle for every change is a **byte-identical `.drv`**: the emitted derivation must match Nix C++ exactly, and the interpreter is canonical (the JITs must reproduce it bit-for-bit). Any build option, module split, or optimization that perturbs `.drv` output is wrong regardless of speed. See [invariants.md](invariants.md).

Code: `build.zig` / `tools/lint_imports.zig`
