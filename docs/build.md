# Build

*The build graph, module layout, and hygiene that keep the fast paths honest.*

`fix` builds with `zig build` from a single `build.zig`. Seven durable groups are Zig modules; subsystems beneath those roots are ordinary file namespaces. An executable-only `process_support` module composes allocator policy without adding it to the engine API. The installed artifact is named `fix`. The build also forces LLVM because the threaded dispatcher needs it.

## Module model

The build-module graph follows independently reusable or consumed groups. Within the `nix` group, normal relative file imports keep one canonical instance of every internal type without restating the subsystem graph in `build.zig`.

| Module | Facade | Imports | Notes |
|---|---|---|---|
| `base` | `src/base/base.zig` | `base_options` | generic containers, fibers, synchronization, blocking pools, allocators, clocks, memory backing |
| `syntax` | `src/syntax/syntax.zig` | `base`, `parser_tables` | independently consumed lexer, parser, and AST |
| `runtime` | `src/runtime/runtime.zig` | `build_options`, `base` | value model, heap, interning, thunk/Future, GC, memory tags |
| `store` | `src/store/root.zig` | `base`, `runtime` | derivations, file snapshots, NAR, realization, daemon protocol/runtime |
| `fetchers` | `src/fetchers/root.zig` | `base`, `runtime`, `store`, libcurl, libgit2 | forge planning, remote-source cache and transports |
| `nix` | `src/nix/root.zig` | `build_options`, `base`, `syntax`, `runtime`, `store`, `fetchers` | narrow evaluator API plus explicit `tooling` access to internal subsystems |
| `cli` | `src/cli/cli.zig` | `nix`, `base` | command surface, argument parsing, rendering, progress |
| `process_support` | `src/process_support.zig` | `base`, `runtime` | executable-only allocator composition |

`nix` exports a narrow evaluator API, including stable build/evaluation progress protocols, diagnostic views, memory configuration parsing, and language policy. The CLI's ordinary path does not import daemon wire, syntax, or evaluator implementation namespaces. Diagnostics that intentionally inspect representation details use `nix.tooling`, which exposes bytecode, compiler, evaluator workers, store derivation/realization views, probes, VM, and observability. Compatibility aliases retain the old `scheduler`, `execution`, and `host` tooling names during extraction.

`cli` imports `nix` plus generic synchronization from `base`; ordinary workflows use the stable evaluator API while diagnostics opt into `nix.tooling`. The executable (`src/main.zig`) imports `nix`, `cli`, and the private `process_support` composition module.

## Parser-table codegen

The LALR parser tables are expensive to construct at comptime, so a standalone codegen tool builds them once and emits a plain `.zig` of literal arrays. `src/syntax/gen_parser_tables.zig` is compiled into the `gen-parser-tables` host executable, run as a build step whose single output file is fed to the `syntax` module as the anonymous import `parser_tables`. The build system caches the run and only re-executes it when the grammar or generator changes. `zig build gen-parser-tables` runs it explicitly. Because the parser imports the generated `parser_tables`, `zig test src/syntax/parser.zig` cannot resolve it standalone — use `zig build test-syntax`.

## Build options

Evaluator-specific `-D` flags are folded into one shared `build_options` module and injected only where they are used. Generic `base` does not see that application-wide option surface. It receives a separate, narrow `base_options` module containing only the profiler-backed fiber census.

### `-D` flag surface

All are `bool` and off unless noted. These are exactly the flags `build.zig` defines; there are no others. Profiling probes gate instrumentation compiled into the core — see [perf/probes.md](perf/probes.md) for what each measures and the workers=1 caveats.

| Group | Flag | Effect |
|---|---|---|
| diagnostics | `debug-checks` | VM dispatch invariant assertions (**defaults on** in Debug builds) |
| | `vm-trace` | enable VM execution tracing (surfaced by `--vm-trace`) → [cli.md](cli.md) |
| | `thunks-log` | per-thunk lifecycle event log (surfaced by `--thunks-log`) → [cli.md](cli.md) |
| profiling | `prof-main` | rdtsc-time the main thread's hot serial paths; reported via `--print-sched-stats` → [perf/probes.md](perf/probes.md) |
| | `prof-path` | record the force-call tree + critical path (workers=1); reported via `--print-sched-stats` → [perf/probes.md](perf/probes.md) |
| compilation | `profile` | keep symbols + frame pointers (sets `strip=false`, `omit_frame_pointer=false`) |

Standard `zig build` options apply too: `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` and `-Dtarget=…`. Perf numbers assume `ReleaseFast` (or `ReleaseSafe`); `-Dprofile` only flips symbol/frame-pointer stripping, it does not change the optimize mode.

The `--vm-trace` / `--thunks-log` runtime flags are inert unless the matching `-D` flag compiled the machinery in. `--timeline` is a special case: the timeline probe is always compiled in and runtime-gated, so `--timeline[=path]` arms it with no rebuild. The `-Dprof-*` reports have no runtime toggle — they are build-time only, so exercising one means a rebuild, and its output surfaces through `--print-sched-stats`.

## Why LLVM is forced (`use_llvm = true`)

The threaded VM dispatcher (`src/nix/vm/run.zig`) chains handlers with `@call(.always_tail)`. Only the LLVM backend implements guaranteed tail calls; the self-hosted backend would emit ordinary calls and the dispatch chain would **unbounded-recurse and blow the stack** — even in Debug. So `use_llvm = true` is pinned on the `exe` *and* on every `addTest` artifact, for all optimize modes.

## Group test wiring

`zig build test` runs one test artifact for each durable group. `zig build check` runs that suite plus `zig fmt --check` over `build.zig`, `src/`, and `tools/`:

```
test → base_tests, syntax_tests, runtime_tests, store_tests, fetchers_tests, nix_tests, cli_tests
```

Relative imports inside `nix` let its single test artifact discover subsystem tests recursively. `zig build test-syntax` runs the front-end tests alone; `zig build bench -- <file.nix>` runs the parse microbenchmark against `syntax`.

Evaluator integration tests live under `src/nix/root/tests` and `src/nix/eval/tests`. Compiler and VM tests live with those subsystems, while the store realization facade owns its socket-backed tests and fake daemon. `test/*.nix` holds pathology and spec fixtures driven through evaluation.

## The correctness gate

The oracle for every change is a **byte-identical `.drv`**: the emitted derivation must match Nix C++ exactly, and the interpreter is canonical. Any build option, module split, collector run, or optimization that perturbs `.drv` output is wrong regardless of speed. See [invariants.md](invariants.md).

Code: `build.zig`
