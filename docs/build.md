# Build

*The build graph, module layout, and hygiene that keep the fast paths honest.*

`fix` builds with `zig build` from a single `build.zig`. The build's shape is deliberate: every subsystem is a real Zig module imported by name, arranged as an acyclic dependency graph and topped by the `fix` evaluator layer. The build also forces LLVM (the threaded dispatcher needs it), wires per-module unit tests by hand, and lints module boundaries.

## Module model

Zig's `@import("<name>")` reaches a module only through its facade; the compiler then enforces that outside code cannot touch the module's internal files. `fix` arranges every subsystem as an acyclic dependency graph of such modules — the layering mirrors the evaluation pipeline. See [architecture.md](architecture.md) for the rationale.

| Module | Facade | Imports | Notes |
|---|---|---|---|
| `containers` | `src/containers.zig` | — | lock-free work-stealing deques + cache-line isolation; depends only on `std` |
| `syntax` | `src/syntax.zig` | `parser_tables` | lexer + LALR(1) parser + AST |
| `runtime` | `src/runtime.zig` | `build_options`, `containers` | values, heap, interning, thunk/Future, GC tracer |
| `parallel` | `src/parallel.zig` | `build_options`, `runtime`, `containers` | fibers + scheduler; adds arch asm `src/parallel/fiber/swap_x86_64.S` |
| `derivation` | `src/derivation.zig` | `runtime` | derivation model, hashing, string context |
| `observ` | `src/observ.zig` | `syntax` | progress sink + error-trace collector — the sinks the VM writes to |
| `bytecode` | `src/bytecode.zig` | `build_options`, `runtime` | instruction set, chunk encoding/registry, disassembler |
| `probe` | `src/probe.zig` | `build_options`, `runtime`, `parallel`, `bytecode` | opt-in profilers, timeline, thunk-trace |
| `compiler` | `src/compiler.zig` | `build_options`, `runtime`, `syntax`, `bytecode`, `probe` | single-pass AST → bytecode lowering |
| `vm` | `src/vm.zig` | `bytecode`, `compiler`, `runtime`, `parallel`, `derivation`, `observ`, `probe`, `syntax`, `build_options` | interpreter: dispatch, thunk forcing, the fiber worker pool, builtins |
| `fix` | `src/root.zig` | all of the above + `build_options` | the `Evaluator` orchestration layer (imports, GC orchestration, config) |
| `cli` | `src/cli.zig` | `fix` + the shared set | command surface, arg parsing, subcommands, rendering, progress |

Eleven modules are lint-guarded (`containers`, `syntax`, `runtime`, `parallel`, `derivation`, `observ`, `bytecode`, `probe`, `compiler`, `vm`, `cli`); `fix` (`src/root.zig`) is the top orchestration layer. The graph is acyclic — every import points down. What could look like an `Evaluator`/VM cycle is avoided by placement: the VM's on-demand compilation of a deferred thunk body calls *down* into `compiler`, and the fiber worker that drives forcing lives *inside* the `vm` module next to the force path, so force↔worker is intra-module. Reaching into any module by relative path is a lint error (below).

`cli` imports `fix` by name, so the command tools reach the engine through its public facade instead of poking at internals. The `exe` module (`src/main.zig`) imports both `fix` and `cli`. `addSharedImports` gives `fix`, `cli`, and `exe` the identical leaf set — `build_options`, `syntax`, `runtime`, `parallel`, `derivation`, `containers`, `observ` — while the engine modules (`bytecode`, `probe`, `compiler`, `vm`) are wired to `fix` and to each other explicitly, bottom-up.

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

`zig build test` (aliased by `check`) walks import graphs — but only a module's *own* `@import` graph. The root test artifacts (`mod_tests` over `fix`, `exe_tests` over `exe`) therefore collect **only** the `fix`-layer tests; a module pulled in by *name* has its own unit tests invisible to the root artifacts. Each module needs its own `addTest` step, run explicitly:

```
test → lint, mod_tests, exe_tests,
       runtime_tests, syntax_tests, parallel_tests,
       derivation_tests, containers_tests, cli_tests,
       bytecode_tests, probe_tests, compiler_tests
```

This wiring is easy to get wrong: a module whose test step is missing from `test_step` still compiles but is never *run*. When adding a module, add its test step to `test_step` or its tests never execute. `zig build test-syntax` runs the `syntax` tests alone for fast lexer/parser/AST iteration; `zig build bench -- <file.nix>` runs the parse microbenchmark against the `syntax` module.

Integration tests live in the core graph (`src/root/tests`, `src/eval/tests`) so the root artifacts pick them up; `test/*.nix` holds pathology and spec fixtures driven through eval.

## `zig build lint` — module-boundary hygiene

`tools/lint_imports.zig` (`zig build lint`, and a dependency of `test`) enforces the facade pattern. A stray `@import("../runtime/value.zig")` from a core file does **not** fail to compile — it drags that file into a second module instance, silently duplicating its types (`runtime.Value` ≠ the copy's `Value`) and producing baffling mismatches far from the cause. The linter walks every `src/**/*.zig`, resolves each relative `@import`, and errors (with `src/path:line`) if the target lands inside another module's files or its facade. A file *inside* `src/<module>/` may import its own module's internals freely; only cross-boundary reaches are rejected. Use `@import("<module>")` across a boundary, always.

## The correctness gate

The oracle for every change is a **byte-identical `.drv`**: the emitted derivation must match Nix C++ exactly, and the interpreter is canonical. Any build option, module split, or optimization that perturbs `.drv` output is wrong regardless of speed — including `-Dgc`, whose collection must leave output bit-for-bit identical. See [invariants.md](invariants.md).

Code: `build.zig` / `tools/lint_imports.zig`
