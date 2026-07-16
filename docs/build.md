# Build

*The build graph, module layout, and hygiene that keep the fast paths honest.*

`fix` builds with `zig build` from a single `build.zig`. Every subsystem is a real Zig module imported by name, arranged as an acyclic dependency graph and topped by the `engine` API and `cli` application layer. The installed artifact is named `fix`; there is no second `fix` module or executable. The build also forces LLVM (the threaded dispatcher needs it), wires per-module unit tests by hand, and lints module boundaries.

## Module model

Zig's `@import("<name>")` reaches a module only through its facade; the compiler then enforces that outside code cannot touch the module's internal files. The source is three tiers — `src/base/` (generic infra), `src/nix/` (the evaluator), `src/cli/` (the app) — arranged as an acyclic dependency graph. See [architecture.md](architecture.md) for the rationale.

| Module | Facade | Imports | Notes |
|---|---|---|---|
| `base` | `src/base/base.zig` | `base_options` | generic infra, no Nix coupling: containers, fibers, synchronization, allocators, regex, TOML |
| `syntax` | `src/nix/syntax.zig` | `base`, `parser_tables` | lexer + LALR(1) parser + AST |
| `runtime` | `src/nix/runtime.zig` | `build_options`, `base` | Nix value model, heap, interning, thunk/Future, GC tracer, the `MemTag` taxonomy |
| `host` | `src/nix/host.zig` | `runtime`, `base` | concrete file/fetch caches, NAR serialization, daemon connections and pool |
| `observ` | `src/nix/observ.zig` | `syntax` | progress sink + error-trace collector — the sinks the VM writes to |
| `scheduler` | `src/nix/scheduler.zig` | `build_options`, `runtime`, `base` | the evaluator's work-stealing scheduler (urgent/novel/spec lanes) |
| `derivation` | `src/nix/derivation.zig` | `runtime`, `base` | derivation model, hashing, string context, evaluation registry |
| `realization` | `src/nix/realization.zig` | `derivation`, `host`, `runtime`, `base` | source recipes, closure planning, store writes, build claims |
| `bytecode` | `src/nix/bytecode.zig` | `build_options`, `runtime`, `base` | instruction set, chunk encoding/registry, disassembler |
| `probe` | `src/nix/probe.zig` | `build_options`, `runtime`, `base`, `bytecode` | opt-in profilers, timeline, thunk-trace |
| `compiler` | `src/nix/compiler.zig` | `build_options`, `runtime`, `base`, `syntax`, `bytecode`, `probe` | single-pass AST → bytecode lowering |
| `vm` | `src/nix/vm.zig` | compiler and the required language/runtime/service modules | interpreter: dispatch, thunk forcing, the fiber worker pool, builtins |
| `engine` | `src/nix/root.zig` | all evaluator modules + `build_options` | app-facing `Evaluator` API and orchestration |
| `cli` | `src/cli/cli.zig` | `engine` | command surface, arg parsing, subcommands, rendering, progress |

Fourteen modules are lint-guarded; `engine` (`src/nix/root.zig`) is the evaluator's app-facing orchestration layer and `cli` sits above it. The graph is acyclic, and the lint enforces both a **down-only** rule and an explicit edge allowlist. A module cannot import an unrelated module merely because it happens to be lower. What could look like an `Evaluator`/VM cycle is avoided by placement: deferred-body compilation calls down from `vm` into `compiler`, while the fiber worker that drives forcing lives inside `vm` next to the force path.

`cli` imports only `engine`, so command code consumes evaluator capabilities through one stable facade instead of assembling runtime pieces itself. The executable module (`src/main.zig`) imports only `engine` and `cli`; it creates process-level resources and dispatches. The artifact is named `fix`, which is distinct from both internal module names.

## Parser-table codegen

The LALR parser tables are expensive to construct at comptime, so a standalone codegen tool builds them once and emits a plain `.zig` of literal arrays. `src/nix/syntax/gen_parser_tables.zig` is compiled into the `gen-parser-tables` host executable, run as a build step whose single output file is fed to the `syntax` module as the anonymous import `parser_tables`. The build system caches the run and only re-executes it when the grammar or generator changes, keeping the table-construction cost off every ordinary rebuild. `zig build gen-parser-tables` runs it explicitly. Because the parser imports the generated `parser_tables`, `zig test src/nix/syntax/parser.zig` cannot resolve it standalone — use `zig build test-syntax` for fast lexer/parser/AST iteration.

## Build options

Evaluator-specific `-D` flags are folded into one shared `build_options` module and injected only where they are used. Generic `base` does not see that application-wide option surface. It receives a separate, narrow `base_options` module containing `fiber_stack_probe` and `fiber_census`; `build.zig` maps the relevant application probes onto those generic capabilities.

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

The threaded VM dispatcher (`src/nix/vm/run.zig`) chains handlers with `@call(.always_tail)`. Only the LLVM backend implements guaranteed tail calls; the self-hosted backend would emit ordinary calls and the dispatch chain would **unbounded-recurse and blow the stack** — even in Debug. So `use_llvm = true` is pinned on the `exe` *and* on every `addTest` artifact, for all optimize modes.

## Per-module test wiring

`zig build test` (aliased by `check`) walks import graphs — but only a module's *own* `@import` graph. The root test artifacts (`mod_tests` over `engine`, `exe_tests` over the executable module) therefore collect only their own tests; a module pulled in by name has unit tests invisible to those artifacts. Each module needs its own `addTest` step, run explicitly:

```
test → lint, mod_tests, exe_tests,
       base_tests, syntax_tests, runtime_tests, host_tests,
       scheduler_tests, derivation_tests, realization_tests,
       bytecode_tests, probe_tests, compiler_tests, vm_tests, cli_tests
```

This wiring is easy to get wrong: a module whose test step is missing from `test_step` still compiles but is never *run*. When adding a module, add its test step to `test_step` or its tests never execute. `zig build test-syntax` runs the `syntax` tests alone for fast lexer/parser/AST iteration; `zig build bench -- <file.nix>` runs the parse microbenchmark against the `syntax` module.

Evaluator integration tests live under `src/nix/root/tests` and `src/nix/eval/tests`. Socket-backed realization tests use `src/nix/realization_test_root.zig`, keeping the fake daemon out of production modules. `test/*.nix` holds pathology and spec fixtures driven through evaluation.

## `zig build lint` — module-boundary hygiene

`tools/lint_imports.zig` (`zig build lint`, and a dependency of `test`) enforces the facade pattern. A stray `@import("../runtime/value.zig")` from a core file does **not** fail to compile — it drags that file into a second module instance, silently duplicating its types (`runtime.Value` ≠ the copy's `Value`) and producing baffling mismatches far from the cause. The linter walks every `src/**/*.zig`, resolves each relative `@import`, and errors (with `src/path:line`) if the target lands inside another module's files or its facade. A file *inside* a module's directory may import its own module's internals freely; only cross-boundary reaches are rejected. Use `@import("<module>")` across a boundary, always.

It also enforces the declared graph. `module_levels` assigns each module its longest-path depth (`base` = 0 through `engine` = 6 and `cli` = 7), rejecting up- and sideways-imports. `module_deps` then rejects undeclared imports even when the target is lower. Engine composition files under `src/nix/root*` and `src/nix/eval*` are owned by the `engine` lint module; only `src/main.zig` remains composition outside the checked module set.

## The correctness gate

The oracle for every change is a **byte-identical `.drv`**: the emitted derivation must match Nix C++ exactly, and the interpreter is canonical. Any build option, module split, or optimization that perturbs `.drv` output is wrong regardless of speed — including `-Dgc`, whose collection must leave output bit-for-bit identical. See [invariants.md](invariants.md).

Code: `build.zig` / `tools/lint_imports.zig`
