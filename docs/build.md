# Build

*The build graph, module layout, and hygiene that keep the fast paths honest.*

`fix` builds with `zig build` from a single `build.zig`. The build's shape is deliberate: every subsystem is a real Zig module imported by name, arranged as an acyclic dependency graph and topped by the `fix` evaluator layer. The build also forces LLVM (the threaded dispatcher needs it), wires per-module unit tests by hand, and lints module boundaries.

## Module model

Zig's `@import("<name>")` reaches a module only through its facade; the compiler then enforces that outside code cannot touch the module's internal files. The source is three tiers — `src/base/` (generic infra), `src/nix/` (the evaluator), `src/cli/` (the app) — arranged as an acyclic dependency graph. See [architecture.md](architecture.md) for the rationale.

| Module | Facade | Imports | Notes |
|---|---|---|---|
| `base` | `src/base/base.zig` | `build_options` | generic infra, no Nix coupling: deque + cache-line isolation, the stackful fiber (inline-asm context switch, vendored from std.Io.fiber), spin/blocking mutexes, segmented + flat stores, the `Vma(Tag)` RSS tracker, the block-cache allocator, a regex engine, a TOML parser |
| `syntax` | `src/nix/syntax.zig` | `parser_tables` | lexer + LALR(1) parser + AST |
| `runtime` | `src/nix/runtime.zig` | `build_options`, `base` | Nix value model, heap, interning, thunk/Future, GC tracer, the `MemTag` taxonomy |
| `observ` | `src/nix/observ.zig` | `syntax` | progress sink + error-trace collector — the sinks the VM writes to |
| `scheduler` | `src/nix/scheduler.zig` | `build_options`, `runtime`, `base` | the evaluator's work-stealing scheduler (urgent/novel/spec lanes) |
| `derivation` | `src/nix/derivation.zig` | `runtime`, `base` | derivation model, hashing, string context |
| `bytecode` | `src/nix/bytecode.zig` | `build_options`, `runtime`, `base` | instruction set, chunk encoding/registry, disassembler |
| `probe` | `src/nix/probe.zig` | `build_options`, `runtime`, `base`, `bytecode` | opt-in profilers, timeline, thunk-trace |
| `compiler` | `src/nix/compiler.zig` | `build_options`, `runtime`, `base`, `syntax`, `bytecode`, `probe` | single-pass AST → bytecode lowering |
| `vm` | `src/nix/vm.zig` | `runtime`, `base`, `syntax`, `scheduler`, `derivation`, `observ`, `bytecode`, `compiler`, `probe`, `build_options` | interpreter: dispatch, thunk forcing, the fiber worker pool, builtins |
| `fix` | `src/nix/root.zig` | all of the above + `build_options` | the `Evaluator` orchestration layer (imports, GC orchestration, config) |
| `cli` | `src/cli/cli.zig` | `fix` + the shared set | command surface, arg parsing, subcommands, rendering, progress |

Eleven modules are lint-guarded; `fix` (`src/nix/root.zig`) is the top orchestration layer. The graph is acyclic and the lint enforces a **down-only** rule (below): every module carries a longest-path level and may only import a strictly lower one. What could look like an `Evaluator`/VM cycle is avoided by placement: the VM's on-demand compilation of a deferred thunk body calls *down* into `compiler`, and the fiber worker that drives forcing lives *inside* the `vm` module next to the force path, so force↔worker is intra-module. Reaching into any module by relative path is a lint error (below).

`cli` imports `fix` by name — plus the same shared leaf set as everyone else (below) — so the command tools see the engine and the leaf subsystems at facade granularity only, never a module's internal files; the engine-only modules (`bytecode`, `probe`, `compiler`, `vm`) are not importable from `cli` at all. The `exe` module (`src/main.zig`) imports both `fix` and `cli`. `addSharedImports` gives `fix`, `cli`, and `exe` the identical leaf set — `build_options`, `base`, `syntax`, `runtime`, `scheduler`, `derivation`, `observ` — while the engine modules (`bytecode`, `probe`, `compiler`, `vm`) are wired to `fix` and to each other explicitly, bottom-up.

## Parser-table codegen

The LALR parser tables are expensive to construct at comptime, so a standalone codegen tool builds them once and emits a plain `.zig` of literal arrays. `src/nix/syntax/gen_parser_tables.zig` is compiled into the `gen-parser-tables` host executable, run as a build step whose single output file is fed to the `syntax` module as the anonymous import `parser_tables`. The build system caches the run and only re-executes it when the grammar or generator changes, keeping the table-construction cost off every ordinary rebuild. `zig build gen-parser-tables` runs it explicitly. Because the parser imports the generated `parser_tables`, `zig test src/nix/syntax/parser.zig` cannot resolve it standalone — use `zig build test-syntax` for fast lexer/parser/AST iteration.

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

The threaded VM dispatcher (`src/nix/vm/run.zig`) chains handlers with `@call(.always_tail)`. Only the LLVM backend implements guaranteed tail calls; the self-hosted backend would emit ordinary calls and the dispatch chain would **unbounded-recurse and blow the stack** — even in Debug. So `use_llvm = true` is pinned on the `exe` *and* on every `addTest` artifact, for all optimize modes.

## Per-module test wiring

`zig build test` (aliased by `check`) walks import graphs — but only a module's *own* `@import` graph. The root test artifacts (`mod_tests` over `fix`, `exe_tests` over `exe`) therefore collect **only** the `fix`-layer tests; a module pulled in by *name* has its own unit tests invisible to the root artifacts. Each module needs its own `addTest` step, run explicitly:

```
test → lint, mod_tests, exe_tests,
       base_tests, syntax_tests, runtime_tests, scheduler_tests,
       derivation_tests, bytecode_tests, probe_tests,
       compiler_tests, cli_tests
```

This wiring is easy to get wrong: a module whose test step is missing from `test_step` still compiles but is never *run*. When adding a module, add its test step to `test_step` or its tests never execute. `zig build test-syntax` runs the `syntax` tests alone for fast lexer/parser/AST iteration; `zig build bench -- <file.nix>` runs the parse microbenchmark against the `syntax` module.

Integration tests live in the core graph (`src/root/tests`, `src/eval/tests`) so the root artifacts pick them up; `test/*.nix` holds pathology and spec fixtures driven through eval.

## `zig build lint` — module-boundary hygiene

`tools/lint_imports.zig` (`zig build lint`, and a dependency of `test`) enforces the facade pattern. A stray `@import("../runtime/value.zig")` from a core file does **not** fail to compile — it drags that file into a second module instance, silently duplicating its types (`runtime.Value` ≠ the copy's `Value`) and producing baffling mismatches far from the cause. The linter walks every `src/**/*.zig`, resolves each relative `@import`, and errors (with `src/path:line`) if the target lands inside another module's files or its facade. A file *inside* a module's directory may import its own module's internals freely; only cross-boundary reaches are rejected. Use `@import("<module>")` across a boundary, always.

It also enforces the **down-only** rule. `module_levels` assigns each module its longest-path depth in the graph (`base`/`syntax` = 0 … `vm` = 5, `cli` = 7); a by-name `@import("X")` from a file in module M is an error unless `level(X) < level(M)`. Because longest-path levels make every legitimate edge strictly decreasing, this rejects exactly the up- and sideways-imports — so "what may I safely import here?" is a located error, not tribal knowledge. (The `fix` core — `nix/root*`, `nix/eval*` — and `main.zig` own no lint module; they are the top and aren't level-checked.)

## The correctness gate

The oracle for every change is a **byte-identical `.drv`**: the emitted derivation must match Nix C++ exactly, and the interpreter is canonical. Any build option, module split, or optimization that perturbs `.drv` output is wrong regardless of speed — including `-Dgc`, whose collection must leave output bit-for-bit identical. See [invariants.md](invariants.md).

Code: `build.zig` / `tools/lint_imports.zig`
