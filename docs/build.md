# Build

*The build graph, module layout, and hygiene that keep the fast paths honest.*

`fix` builds with `zig build` from a single `build.zig`. The build's shape is deliberate: a small ring of genuinely-acyclic subsystems are real Zig modules imported by name, while the coupled evaluator core stays in one module because it has real dependency cycles. The build also forces LLVM (the threaded dispatcher needs it), wires per-module unit tests by hand, and lints module boundaries.

## Model: clean-cut modules vs the coupled core

Zig's `@import("<name>")` reaches a module only through its facade; the compiler then enforces that outside code cannot touch the module's internal files. `fix` uses this to carve out the subsystems that are genuinely tree-shaped from the engine that isn't. See [architecture.md](architecture.md) for the boundary rationale.

| Module | Facade | Imports | Notes |
|---|---|---|---|
| `containers` | `src/containers.zig` | — | lock-free work-stealing deques + cache-line isolation; bottom of the graph, depends only on `std` |
| `syntax` | `src/syntax.zig` | `parser_tables` | lexer + parser + AST; no engine deps |
| `runtime` | `src/runtime.zig` | `build_options`, `containers` | values, heap, interning, thunk representation, GC tracer |
| `parallel` | `src/parallel.zig` | `build_options`, `runtime`, `containers` | fibers, scheduler, workers; adds arch asm `src/parallel/fiber/swap_x86_64.S` |
| `derivation` | `src/derivation.zig` | `runtime` | derivation model, hashing, context |
| `fix` (core) | `src/root.zig` | all of the above + `build_options` | bytecode, compiler, vm, eval/worker, eval/progress, eval/gc, probe |
| `cli` | `src/cli.zig` | `fix` + the shared set | command surface, arg parsing, subcommands, rendering, progress |

`containers`, `syntax`, `runtime`, `parallel`, `derivation`, and `cli` are the six clean-cut modules the linter guards. The core stays one module because its cycles are real: `vm/force ↔ compiler/deferred` (forcing a thunk can trigger compilation of its deferred body) and `eval/worker ↔ vm/force` (the worker drives the VM, whose force path re-enters the worker to schedule/steal). Splitting them would need forward-declared interfaces that buy nothing. Reaching into any named module by relative path is a lint error (below).

`cli` is its own module rather than part of the core: it imports `fix` by name, so the command tools reach the engine through its public facade instead of poking at engine internals. The `exe` module (`src/main.zig`) imports both `fix` and `cli`; it and every test artifact receive the same shared module set via `addSharedImports`.

## Parser-table codegen

The LALR parser tables are expensive to construct at comptime, so a standalone codegen tool builds them once and emits a plain `.zig` of literal arrays. `src/syntax/gen_parser_tables.zig` is compiled into the `gen-parser-tables` host executable, run as a build step whose single output file is fed to the `syntax` module as the anonymous import `parser_tables`. The build system caches the run and only re-executes it when the grammar or generator changes, keeping the table-construction cost off every ordinary rebuild. `zig build gen-parser-tables` runs it explicitly. Because the parser imports the generated `parser_tables`, `zig test src/syntax/parser.zig` cannot resolve it standalone — use `zig build test-syntax` for fast lexer/parser/AST iteration.

## Shared `build_options`

Every `-D` flag is folded into one `build_options` module created **once** and injected into `runtime`, `parallel`, `derivation`, `fix`, `cli`, and `exe`. This is load-bearing: importing the generated options file into two *different* module instances makes Zig treat them as two distinct types, so a single shared instance is the only way every subsystem sees the same flag set (and the same `bool` type for each flag).

### `-D` flag surface

All are `bool` and off unless noted. These are exactly the flags `build.zig` defines; there are no others. Profiling probes gate instrumentation compiled into the core — see [perf/probes.md](perf/probes.md) for what each measures and the workers=1 caveats.

| Group | Flag | Effect |
|---|---|---|
| diagnostics | `vm-opcode-profile` | collect + print VM opcode execution counts |
| | `debug-checks` | VM dispatch invariant assertions (**defaults on** in Debug builds) |
| | `vm-trace` | enable VM execution tracing (surfaced by `--vm-trace`) → [cli.md](cli.md) |
| | `thunks-log` | per-thunk lifecycle event log (surfaced by `--thunks-log`) → [cli.md](cli.md) |
| | `fiber-stack-probe` | sentinel-fill fiber stacks for `maxStackUsedBytes`; forces full RSS commit |
| profiling | `prof-main` | rdtsc-time the main thread's hot serial paths; reported via `--print-sched-stats` → [perf/probes.md](perf/probes.md) |
| | `prof-path` | record the force-call tree + critical path (workers=1); reported via `--print-sched-stats` → [perf/probes.md](perf/probes.md) |
| | `timeline` | wall-clock per-worker event timeline; Perfetto JSON via `--timeline` → [perf/probes.md](perf/probes.md) |
| memory | `gc` | include the generational collector (`--max-memory`-budgeted; dormant below half-budget, ~2% rooting tax). **Defaults on**; `-Dgc=false` builds the collector-free evaluator → [gc.md](gc.md) |
| compilation | `profile` | keep symbols + frame pointers (sets `strip=false`, `omit_frame_pointer=false`) |

Standard `zig build` options apply too: `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` and `-Dtarget=…`. Perf numbers assume `ReleaseFast` (or `ReleaseSafe`); `-Dprofile` only flips symbol/frame-pointer stripping, it does not change the optimize mode.

The `--vm-trace` / `--thunks-log` runtime flags are inert unless the matching `-D` flag compiled the machinery in. `--timeline` is a special case: the timeline probe is always compiled in and runtime-gated, so `--timeline[=path]` arms it with no rebuild. The `-Dprof-*` reports have no runtime toggle — they are build-time only, so exercising one means a rebuild, and its output surfaces through `--print-sched-stats`.

## Why LLVM is forced (`use_llvm = true`)

The threaded VM dispatcher (`src/vm/run.zig`) chains handlers with `@call(.always_tail)`. Only the LLVM backend implements guaranteed tail calls; the self-hosted backend would emit ordinary calls and the dispatch chain would **unbounded-recurse and blow the stack** — even in Debug. So `use_llvm = true` is pinned on the `exe` *and* on every `addTest` artifact, for all optimize modes.

## Per-module test wiring

`zig build test` (aliased by `check`) walks import graphs — but only a module's *own* `@import` graph. The root test artifacts (`mod_tests` over `fix`, `exe_tests` over `exe`) therefore collect **only** core-module tests; a clean-cut module is pulled into `fix` by module *name*, so its unit tests are invisible to the root artifacts. Each clean-cut module needs its own `addTest` step, run explicitly:

```
test → lint, mod_tests, exe_tests,
       runtime_tests, syntax_tests, parallel_tests,
       derivation_tests, containers_tests, cli_tests
```

This wiring is easy to get wrong: a clean-cut module whose test step is missing from `test_step` still compiles but is never *run*. When adding a clean-cut module, add its test step to `test_step` or its tests never execute. `zig build test-syntax` runs the `syntax` tests alone for fast lexer/parser/AST iteration; `zig build bench -- <file.nix>` runs the parse microbenchmark against the `syntax` module.

Integration tests live in the core graph (`src/root/tests`, `src/eval/tests`) so the root artifacts pick them up; `test/*.nix` holds pathology and spec fixtures driven through eval.

## `zig build lint` — module-boundary hygiene

`tools/lint_imports.zig` (`zig build lint`, and a dependency of `test`) enforces the facade pattern. A stray `@import("../runtime/value.zig")` from a core file does **not** fail to compile — it drags that file into a second module instance, silently duplicating its types (`runtime.Value` ≠ the copy's `Value`) and producing baffling mismatches far from the cause. The linter walks every `src/**/*.zig`, resolves each relative `@import`, and errors (with `src/path:line`) if the target lands inside a clean-cut module's files or its facade. A file *inside* `src/<module>/` may import its own module's internals freely; only cross-boundary reaches are rejected. Use `@import("<module>")` across a boundary, always.

## The correctness gate

The oracle for every change is a **byte-identical `.drv`**: the emitted derivation must match Nix C++ exactly, and the interpreter is canonical. Any build option, module split, or optimization that perturbs `.drv` output is wrong regardless of speed — including `-Dgc`, whose collection must leave output bit-for-bit identical. See [invariants.md](invariants.md).

Code: `build.zig` / `tools/lint_imports.zig`
