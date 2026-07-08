# CLI

*The command surface and the introspection tools that read the machine's mind.*

The command surface lives in the `cli` module (`src/cli.zig` facade over `src/cli/`), which imports the `fix` core by name and reaches the engine only through its public facade — the tools never poke at engine internals ([build.md](build.md)). `src/main.zig` is composition only: it wires `cli` and `fix` together, dispatches subcommands, then parses options and drives an `Evaluator`. `src/cli/args.zig` owns the option grammar. Everything a developer needs to disassemble bytecode, snapshot the heap, replay execution, and pinpoint a parallelism divergence lives here.

## Invocation

```
fix [options] (-e EXPR | --file PATH)
fix <subcommand> [args]
```

The **first argument** is checked against the subcommand table *before* normal option parsing. If it names a subcommand, that command runs and the process exits; otherwise the first arg is fed back into `args.parse` and `fix` evaluates.

## Subcommands

Each is a self-contained tool with its own `-h`. They share the compiler/VM but bypass the normal evaluate-and-render path.

| Subcommand | Purpose | Link |
|---|---|---|
| *(none)* / `-e` / `--file` | compile → evaluate → render value (default) | — |
| `--repl` | interactive read-eval loop (an option, not a subcommand) | — |
| `disasm` | decompile bytecode per-chunk with source-span + constant annotation | [compiler/pipeline.md](compiler/pipeline.md), [vm/dispatch.md](vm/dispatch.md) |
| `inspect` | post-eval heap size / intern stats / chunk count; `--top N` longest interned strings | [runtime/interning.md](runtime/interning.md) |
| `trace dump PATH` / `trace diff A B` | read binary VM-execution trace files: `dump` pretty-prints one as text; `diff` walks two in lockstep to the first divergent event | [vm/dispatch.md](vm/dispatch.md) |
| `thunks diff A B` | diff two thunk-resolution logs → first divergence by source location | below |

Note: `derivation-debug` is **not** a subcommand — derivation records are filtered/rendered inline via the `--debug-derivation*` flags below. See [derivation/model.md](derivation/model.md).

## Key flags

Parsed in `src/cli/args.zig`. Defaults shown; `[=X]` means the value is optional.

| Flag | Meaning |
|---|---|
| `-e, --expr EXPR` | evaluate expression text |
| `--file PATH` | evaluate a file (mutually exclusive with `-e`) |
| `--repl` | interactive loop; rejects a source arg |
| `--json` / `--xml` | render the value as JSON / XML instead of Nix |
| `--strict` | recursively force attr values + list items before writing |
| `--pipe-operators` | enable the `\|>` / `<\|` pipe operators (sugar for application; off by default) → [syntax/nix-syntax.md](syntax/nix-syntax.md) |
| `--workers N` | worker threads; default `min(8, cpu_count)` (1 if single-threaded) → [parallel/workers.md](parallel/workers.md) |
| `--max-memory SIZE` | GC budget before collection kicks in (MiB, or a `k`/`m`/`g` suffix; `0` = never collect; default half of `MemAvailable`). Effective only on a `-Dgc` build → [gc.md](gc.md) |
| `--show-trace` | full evaluation traces on error |
| `--color[=auto\|always\|never]` / `--no-color` | color diagnostics |
| `--progress[=auto\|always\|never]` / `--no-progress` | eval progress on stderr |
| `--debug-derivations[=summary\|full]` | write derivation debug records to stderr |
| `--debug-derivation-filter TEXT` | only derivations whose name/path/input mentions TEXT |
| `--debug-derivation-name NAME` | only the derivation with exactly NAME |
| `--debug-derivation-drv PATH` | only the derivation with exactly PATH |

### Introspection / trace flags

| Flag | Meaning |
|---|---|
| `--vm-trace[=PATH]` | record VM execution (default `-`, i.e. stderr); needs a `-Dvm-trace` build |
| `--vm-trace-format text\|binary` | trace encoding (default `text`) |
| `--vm-trace-max-events N` | cap recorded events (default `0` = unlimited) |
| `--vm-trace-main-only` | record only the main thread's fiber |
| `--thunks-log=PATH` | per-thunk lifecycle log (PATH required, no bare form; needs a `-Dthunks-log` build) |
| `--timeline[=PATH]` | Perfetto wall-clock timeline (default `fix-timeline.json`); needs a `-Dtimeline` build |
| `--print-sched-stats` | after eval, print scheduler / chunk-registry / deferred-table / speculation-census counters, plus worker busy/idle time summed across all workers and the resulting average utilisation, plus any `-Dprof-main` / `-Dprof-path` reports |

### Parallelism debug toggles

Speculation and fan-out are **on by default** (worth ~20–32% wall at `--workers>1`); these toggles turn them off for A/B and divergence isolation.

| Flag | Meaning |
|---|---|
| `--no-spec-thunks` | disable speculative thunk evaluation → [parallel/speculation.md](parallel/speculation.md) |
| `--speculate` | force speculation back on (it is the default; kept for explicit A/B) |
| `--no-fanout` | disable strict-argument fan-out → [parallel/speculation.md](parallel/speculation.md) |
| `--timeline-flows=N\|off\|all` | steal-arrow flow-event density in the `--timeline` trace (default `all`; `off` drops flows; `N` keeps 1/N) |

Use the disable toggles to isolate whether a wrong parallel result (or a hang) comes from speculation vs fan-out: rerun with each disabled and see which one restores correctness.

## Using the debug tools

- **`disasm`** — read what the compiler emitted per chunk, with source spans and constant-pool annotation. The first stop when a bytecode-level bug is suspected; pair with [compiler/pipeline.md](compiler/pipeline.md) to map source→ops and [vm/dispatch.md](vm/dispatch.md) to map ops→handlers.
- **`inspect`** — post-eval heap/intern census; `--top N` lists the N longest interned strings (string-table bloat).
- **`--vm-trace` + `trace`** — capture a VM event stream (`--vm-trace-format binary` for volume, `--vm-trace-main-only` to drop helper noise), then inspect it with the `trace` subcommand: `trace dump` pretty-prints the binary trace as text, `trace diff` walks two binary traces to the first divergent event. The `trace` subcommand reads the binary format only.
- **`--thunks-log` + `fix thunks diff`** — the divergence workflow. When a `--workers=N` run gives a wrong answer a `--workers=1` run doesn't, record `--thunks-log` for both, then `fix thunks diff A B`. It keys thunk outcomes by the joint `(creator, target)` source-location pair — each a `(file, line, col)` triple, stable across runs even though chunk/thunk ids are not; creator alone collides across let-bindings sharing an outer span and target alone collides at synthetic `?:0:0` spans, so the pair is unique per thunk-creation site — and reports the earliest locations whose resolve/errored/reset outcome multisets differ. Filters narrow it further: `--asymmetric` (one side produced an outcome the other never did — the speculation-race smoking gun), `--novel-in b` (only where B forced something A never reached), `--by-kind` (compare by kind+discriminant, ignoring value contents, to suppress iteration-order noise), `--max-divergences N` (default 30), `--max-outcomes N` (default 5). See [runtime/thunks.md](runtime/thunks.md).
- **`--timeline`** — emits a Perfetto JSON timeline (parse/compile/import phases, per-worker fiber-run quanta, idle parks). Load it in Perfetto to *see* the serial critical path that bounds wall time → [perf/model.md](perf/model.md).

The `--vm-trace` and `--thunks-log` flags only do anything on a build compiled with the matching `-D` probe (`-Dvm-trace`, `-Dthunks-log`); the `-Dprof-main` / `-Dprof-path` reports surface through `--print-sched-stats`. `--timeline` needs no rebuild — the timeline probe is always compiled in and runtime-gated. Exercising a `-Dprof-*` probe means a rebuild. See [perf/probes.md](perf/probes.md) and [build.md](build.md).

Code: `src/main.zig` / `src/cli/`
