# CLI

*The command surface and the introspection tools that read the machine's mind.*

The command surface lives in the `cli` module (`src/cli/cli.zig` is a module-only facade over `src/cli/`). Its only dependency is the `nix` facade: CLI code cannot import runtime or evaluator internals directly. Commands import their focused siblings rather than reaching back through the facade: `presentation.zig` owns terminal policy and styling, `progress.zig` renders evaluation progress, and `realize.zig` owns the shared evaluation-to-build workflow. `src/main.zig` is composition only; it imports `nix` and `cli`, sets up the allocator, then dispatches to a **required** subcommand. `src/cli/args.zig` owns the shared option grammar, and `src/cli/setup.zig` folds common `Options → Evaluator` configuration through `nix`-owned types. Everything a developer needs to evaluate, disassemble bytecode, snapshot the heap, replay execution, and pinpoint a parallelism divergence lives here.

## Invocation

```
fix <command> [options]
```

A subcommand is **required** (there is no default command). POSIX conventions: `-h`/`--help` prints help to **stdout** and exits `0`; a missing/unknown command or a bad argument prints usage to **stderr** and exits nonzero (`2`). `fix <command> -h` prints that command's scoped help.

## Subcommands

Each is a self-contained tool with its own `-h`. `eval`/`repl` share the compiler/VM and the standard evaluate-and-render path; `instantiate`/`build`/`run`/`shell` evaluate the same way but then realize the resulting derivation to the store through the nix-daemon worker protocol; the rest are introspection tools.

| Subcommand | Purpose | Link |
|---|---|---|
| `eval` | evaluate an expression/file/flake output → render value (the `-e`/`--file`/`--flake` flags live here) | — |
| `instantiate` | evaluate to a derivation and add its `.drv` closure to the store (à la `nix-instantiate`) | [derivation/model.md](derivation/model.md) |
| `build` | evaluate to a derivation, build its outputs via the nix-daemon, and link `./result` | [derivation/model.md](derivation/model.md) |
| `run` | build a derivation and run a program from its output | — |
| `shell` | build a derivation and open a shell with its `bin/` on `PATH` (`-p NAMES...` pulls packages from `<nixpkgs>`) | — |
| `store` | query the nix-daemon directly (protocol version, path validity) | — |
| `repl` | interactive read-eval loop | — |
| `disasm` | decompile bytecode per-chunk with source-span, constant, and local/upvalue-name annotation | [compiler/pipeline.md](compiler/pipeline.md), [vm/dispatch.md](vm/dispatch.md) |
| `inspect` | post-eval heap size / intern stats / chunk count; `--top N` longest interned strings | [runtime/interning.md](runtime/interning.md) |
| `trace dump PATH` / `trace diff A B` | read binary VM-execution trace files: `dump` pretty-prints one as text; `diff` walks two in lockstep to the first divergent event | [vm/dispatch.md](vm/dispatch.md) |
| `thunks diff A B` | diff two thunk-resolution logs → first divergence by source location | below |

Note: `derivation-debug` is **not** a subcommand — derivation records are filtered/rendered inline via the `--debug-derivation*` flags below. See [derivation/model.md](derivation/model.md).

## The repl

`fix repl` (`src/cli/repl.zig` + `src/cli/repl/`) has two strictly separated modes, decided once at startup:

- **Interactive** — stdin *and* stdout are a tty and `--bare` was not given. A hand-rolled raw-mode line editor: emacs-style editing (C-a/C-e/C-k/C-u/C-w/C-y + kill ring, M-b/M-f word motion), persistent history (`$XDG_STATE_HOME/fix/repl-history`, multiline entries round-trip) with C-r incremental search, Tab completion, bracketed paste (pasted text never triggers completion or submission), SIGWINCH-aware minimal-repaint rendering, and C-z suspend/resume. Raw mode is restored on **every** exit path — orderly return, panic (SIGABRT), fatal signal — via a saved-termios global + chained signal handlers (`repl/term.zig`).
- **Bare** — `--bare`, or any non-tty end: a plain read-a-line loop with zero escape sequences (prompts only when stdin is a tty), for pipes and expect-style automation. Lines still accumulate until they parse as a complete expression, so multiline scripts pipe fine.

**Smart-enter.** Enter submits only when the input parses as a complete expression (the real parser decides: an error at EOF means "more is coming"); otherwise it opens a continuation line (`...>` prompt). Alt-Enter submits as-is; C-o inserts a newline. Multiline history entries recall as multiline; Up/Down move within lines before browsing history.

**Completion (Tab).** Readline model: common prefix first, candidate menu on the second Tab. Sources by context: `:` commands; scope bindings + keywords + globally-visible builtins for bare identifiers; attribute paths (`foo.ba<TAB>`) resolved through **already-forced** values only — the completer never starts evaluation; file paths inside string/path literals.

**Scope.** `name = expr` binds; the last printed value is `it`; `:l PATH` merges a file's attrset into scope (auto-calling a top-level function with `{}`); `:r` reloads. Inputs compile inside an ambient scope attrset (the `scopedImport` mechanism), so bound values are *shared*, never re-evaluated.

**GC.** A collection runs between inputs (`Evaluator.collectNow`: the standard STW barrier driven from outside an evaluation), so session memory tracks the live bindings rather than accreting. Repl-held values are precise GC roots (`Evaluator.gcSetExternalRoots` → `gc_extra_roots` in the root set). `:gc` collects on demand and reports reserved bytes.

**Commands** (`:?` shows this table in-repl): `:?`/`:help`, `:q`/`:quit`/`:exit`, `:l`/`:load PATH`, `:r`/`:reload`, `:t`/`:type EXPR`, `:p`/`:print EXPR` (deep-force), `:i`/`:inspect EXPR` (kind, thunk state + backing chunk, closure chunk/arity), `:d`/`:disasm EXPR`, `:env`, `:gc`.

**`:d` — the disassembly browser.** Finds the chunk behind an expression (a closure or unforced thunk exposes its own chunk; otherwise the expression's compiled chunk) and opens it in an alternate-screen pager where every chunk mention (`chunk[0xN]` in listings, `chunk #N` on references pages) is a link: Tab/Shift-Tab select, Enter follows, `b`/`f` walk the visit history, `r` shows a references page (outgoing + incoming, from a lazily built whole-registry reverse index), `/` + `n`/`N` search, `?` help. In bare mode `:d` prints the listing plus an outgoing-references footer.

## The debugger

`fix eval --debugger` (and `fix repl --debugger`) pauses evaluation into an interactive console — Nix's `--debugger` model — at three points:

- **`builtins.break x`** — a break in the source. `break` is otherwise the identity on `x`, so it can be dropped anywhere: `let y = builtins.break (f a); in ...`.
- **a source-line breakpoint** — `break FILE:LINE` from the console. See [Source-line breakpoints](#source-line-breakpoints).
- **an evaluation error** — an uncaught `throw`, `abort`, or failed `assert` pauses at the origin (call frames still live) *before* the error unwinds and prints. Errors caught by `builtins.tryEval` do **not** pause.

`--debugger` forces `--workers=1` and disables speculation so the pause point is deterministic — a single demand fiber, no helper racing ahead of the break. The console reads commands from stdin and writes to stderr, so a redirected stdout still receives only the final value. Under `fix repl` the console runs in-line during each input's evaluation, then returns you to the prompt.

**Console commands.** A bare line is a **Nix expression** evaluated in the pause's scope; a command word alone runs the command (so `n + base` evaluates but `n` steps), and a leading `:` forces command interpretation.

| command | effect |
|---|---|
| `<expr>` | evaluate an expression in the breakpoint's scope (see below) |
| `bt` / `backtrace` | the call stack, innermost first, with `file:line:col`, chunk name, and `#chunk` id |
| `l` / `locals` | in-scope named locals and upvalues, grouped per frame |
| `v` / `value` | the value passed to `builtins.break` (or the error subject) |
| `break FILE:LINE` | set a source-line breakpoint |
| `breakpoints` / `delete N` | list / remove breakpoints |
| `n` / `next` | step to the next line, over calls |
| `s` / `step` | step to the next line, into calls |
| `finish` | run until the current frame returns |
| `c` / `continue` | resume evaluation |
| `q` / `quit` | abort evaluation |
| `help` | command list |

Frames show names when chunk-name capture is on (`--debugger` enables it), so a backtrace reads like `pkgs/hello.nix:12:3 hello (chunk #42)`. Console expressions run on a fresh nested VM sharing the registry, heap, and intern table, so inspecting a value never disturbs the pause point.

**Source snippet & color.** Each pause prints the source line at the current span (a line of context on each side, `▶` on the current line, a caret under the span), syntax-highlighted through the `syntax` scanner — keywords magenta, strings/paths green, numbers yellow. The source comes from the FileCache (imported files) or the stashed `-e` entry text. Rendered values are colored in the same palette (green strings, yellow numbers, magenta `true`/`false`/`null`, cyan attr names) whenever the terminal takes color — the same `writeValue` coloring `fix eval`/`fix repl` use for their output. All of it no-ops under `--no-color`.

**Scope-accurate evaluation.** A console expression resolves the breakpoint's lexical bindings — `let` bindings, lambda params, captured upvalues, and `with`-scopes — not just globals. The compiler records a slot→name table per chunk (gated on the same capture flag, so normal builds pay nothing), and the console reconstructs an ambient scope from the frame stack: named locals and upvalues (inner frames shadow outer), plus each in-effect `with` attrset merged at lowest precedence (a `with` subject is a nameless local slot or a `"\x00with"` upvalue; lexical bindings shadow it, inner `with` shadows outer), plus `it` = the break value. Because a break often lands in a small argument thunk whose own frame has no locals, the scope merges *all* live frames, so `base`, a param `n`, or an attr `hello` from `with pkgs;` all resolve.

### Source-line breakpoints

`break FILE:LINE` pauses whenever execution reaches that line — set it during any pause (drop a `builtins.break` near the entry to get an initial one). It's implemented by **patching the bytecode**, not by a per-instruction check: the opcode byte at the line's first instruction is overwritten with a dedicated `breakpoint` opcode that pauses the debugger and then chains to the saved original opcode (its operands are untouched). The hot dispatch loop is byte-for-byte unchanged and pays nothing until a patched instruction actually runs — so this ships in the default binary with no build flag. `delete N` restores the original bytes. Because bodies compile lazily (imports, deferred attrs register mid-evaluation), a per-registry hook re-patches pending breakpoints onto each newly registered chunk.

The compiler emits a source-map entry per expression node, so essentially every line is breakpointable; a requested line still resolves to the nearest line carrying code (reported when it differs). One caveat: a single source line can compile into several chunks (e.g. a call and its argument thunk), so a breakpoint may report multiple sites and pause at each. Breakpoints force `--workers=1`, so patched bytecode is never shared across threads.

### Stepping

`next`, `step`, and `finish` reuse the breakpoint mechanism: each **arms temporary bytecode patches** and resumes; the next pause is the landing point. `next` patches every next-line site in the current chunk plus the caller's return point and stops at the current frame depth or shallower (so it doesn't stop inside a deeper recursion). `step` additionally patches the entry of every chunk the current one may call or force, and stops at any depth. `finish` patches only the caller's return point. `BreakpointTable.hit` applies the depth guard: a permanent breakpoint always pauses, a step temp only at the target depth; the console clears the step's temps at the next pause.

One honest caveat: this is a **lazy** language, so stepping follows *demand* order, not source order. Stepping "over" a line whose value is a thunk lands wherever that thunk is actually forced — often a different binding or file — and a value already forced (memoised) is skipped. `step` into a call typically lands in the argument thunk first (Nix forces arguments on demand). Stepping is most intuitive as "step into this call and see where evaluation goes next," less so as classic line-by-line imperative stepping. Results are always preserved — a step patch chains to the original opcode.

**Source locations.** A frame's `ip` is resolved with `disasm.frameSpan` — the narrowest covering source span, but with an *inclusive* end and a `body_span` fallback. The inclusive end matters for a caller frame, whose `ip` points *past* the call it's suspended on (exactly at the covering span's exclusive end); plain `bestSpan` (used by `fix disasm` for the instruction about to execute) would miss it and the frame would show no location. This is why a backtrace reads `f.nix:11:8 f ← 13:42 ← 13:3` rather than blank caller lines.

**Architecture.** The engine exposes a neutral break seam so the layering stays down-only: `vm.BreakSink` on the VM (null in every normal run — `builtins.break` is then a plain identity, zero cost off the debug path), the `breakpoint` opcode + `bytecode.BreakpointTable` (patch/restore, lazy re-patch via `ChunkRegistry.breakpoint_sink`), a `fix.DebugSession` facade over the paused VM (backtrace, scope, evaluate-in-place, value rendering, breakpoint set/list/delete, stepping), and `Evaluator.setDebugUi`. The `cli` layer supplies the console (`src/cli/debugger.zig`) through that facade and never names a `vm` type.

## Key flags

The data-driven `Spec` table in `src/cli/args.zig` is the source of truth: it drives parsing *and* per-command `--help` visibility (each spec lists the subcommands it applies to). Defaults shown; `[=X]` means the value is optional.

### Source selection (`eval`/`instantiate`/`build`/`run`/`shell`/`disasm`)

| Flag | Meaning |
|---|---|
| `PATH` (positional) | evaluate a file; without any source, `./default.nix` (or the flake `.` under `--flake`) |
| `-e, --expr EXPR` | evaluate expression text |
| `--file PATH` | evaluate a file (same as a bare PATH; mutually exclusive with `-e`) |
| `--flake [INSTALLABLE]` | evaluate a flake output `<flakeref>[#<attrpath>]` (default flakeref `.`); lowered to `(builtins.getFlake "<ref>").<attrpath>`. `.`/relative refs resolve against cwd; `github:`/`path:`/… pass through. Requires the `flakes` feature. |
| `-A, --attr ATTR` | select attribute path ATTR from the result |
| `--arg NAME EXPR` / `--argstr NAME STR` | pass an expression / a string as top-level function argument NAME |
| `-I, --include PATH` | prepend a search-path entry (as in `NIX_PATH`; `prefix=path` form allowed). Repeatable. |
| `--option NAME VALUE` | override a nix.conf setting |

### Evaluation / output

| Flag | Meaning |
|---|---|
| `--json` / `--xml` | render the value as JSON / XML instead of Nix |
| `--strict` | recursively force attr values + list items before writing |
| `--experimental-features FEATS` / `--extra-experimental-features FEATS` | space-separated experimental features to enable (replace / append), Nix-style. Available: `pipe-operators` — the `\|>` / `<\|` pipe operators (sugar for application) → [syntax/nix-syntax.md](syntax/nix-syntax.md); `fetch-tree` — gates a direct `builtins.fetchTree` call; `flakes` — gates the flake builtins (`getFlake`, `parseFlakeRef`, `flakeRefToString`) and the `--flake` installable, and implies `fetch-tree`. All off by default; a disabled builtin raises a hard (tryEval-uncatchable) error. |
| `--workers N` | worker threads; default `min(8, cpu_count)` (1 if single-threaded) → [parallel/workers.md](parallel/workers.md) |
| `--max-memory SIZE` | GC budget before collection kicks in (MiB, or a `k`/`m`/`g` suffix; `0` = never collect; default half of `MemAvailable`) → [gc.md](gc.md) |
| `--hugetlb auto\|on\|off` | back the evaluation heap with explicit 2 MB huge pages (default `auto`: only when the kernel pool has ≥256 MB unreserved capacity). Provision the pool with `sysctl vm.nr_hugepages=N` → [perf/hugetlb.md](perf/hugetlb.md) |
| `--show-trace` | full evaluation traces on error |
| `--debugger` (eval, repl) | pause into the interactive debug console at `builtins.break` and on evaluation errors; forces `--workers=1`. See [The debugger](#the-debugger). |
| `--color[=auto\|always\|never]` / `--no-color` | color diagnostics |
| `--progress[=auto\|always\|never]` / `--no-progress` | eval progress on stderr |
| `--debug-derivations[=summary\|full]` | write derivation debug records to stderr |
| `--debug-derivation-filter TEXT` | only derivations whose name/path/input mentions TEXT |
| `--debug-derivation-name NAME` | only the derivation with exactly NAME |
| `--debug-derivation-drv PATH` | only the derivation with exactly PATH |
| `--bare` (repl) | plain line-based input: no editor, no escape sequences — for pipes and expect-style automation |

### Store links & realization (`instantiate`/`build`/`run`/`shell`)

| Flag | Meaning |
|---|---|
| `-o, --out-link NAME` | name of the result symlink (`build`; default `result`); `--no-out-link` (alias `--no-link`) skips it |
| `--drv-link NAME` / `--add-drv-link` | name of / also create the `.drv` symlink (`build`/`instantiate`; default `derivation`) |
| `--add-root PATH` / `--indirect` | create the link at PATH and register it as a (optionally indirect) GC root (`build`/`instantiate`) |
| `--check` / `--repair` | rebuild and verify outputs are unchanged / repair corrupted store paths |
| `-j, --max-jobs N\|auto` / `--cores N` | daemon build parallelism (folded into `--option` overrides, applied via the worker protocol) |
| `--fallback` | build from source if a substitute fails |
| `-K, --keep-failed` | keep the build tree of failed builds |
| `--max-silent-time SECS` / `--timeout SECS` | abort builds silent/running too long (`0` = no limit) |
| `-v, --verbose` | increase daemon build verbosity (repeatable) |
| `-p, --packages NAMES...` | (`shell`) packages (attr paths) from `<nixpkgs>`, e.g. `-p ripgrep jq` |

### Introspection / trace flags

| Flag | Meaning |
|---|---|
| `--vm-trace[=PATH]` | record VM execution (default `-`, i.e. stderr); needs a `-Dvm-trace` build |
| `--vm-trace-format text\|binary` | trace encoding (default `text`) |
| `--vm-trace-max-events N` | cap recorded events (default `0` = unlimited) |
| `--vm-trace-main-only` | record only the main thread's fiber |
| `--thunks-log PATH` | per-thunk lifecycle log (PATH required — `--thunks-log PATH` or `=PATH`; needs a `-Dthunks-log` build) |
| `--timeline[=PATH]` | Perfetto wall-clock timeline (default `fix-timeline.json`) |
| `--print-sched-stats` | after eval, print scheduler / chunk-registry / deferred-table / speculation-census counters, plus worker busy/idle time summed across all workers and the resulting average utilisation, plus any `-Dprof-main` / `-Dprof-path` reports |
| `--mem-report[=dump]` | print peak-RSS attribution at teardown; `dump` also lists registered VMAs |
| `--gc-report` | print the collection/pause/live-set summary at teardown |

### Parallelism debug toggles

Speculation and fan-out are **on by default** (worth ~20–32% wall at `--workers>1`); these toggles turn them off for A/B and divergence isolation.

| Flag | Meaning |
|---|---|
| `--no-spec-thunks` | disable speculative thunk evaluation → [parallel/speculation.md](parallel/speculation.md) |
| `--no-fanout` | disable strict-argument fan-out → [parallel/speculation.md](parallel/speculation.md) |
| `--timeline-flows=N\|off\|all` | steal-arrow flow-event density in the `--timeline` trace (default `all`; `off` drops flows; `N` keeps 1/N) |

Use the disable toggles to isolate whether a wrong parallel result (or a hang) comes from speculation vs fan-out: rerun with each disabled and see which one restores correctness.

## Using the debug tools

- **`disasm`** — read what the compiler emitted per chunk, with source spans and constant-pool annotation. The first stop when a bytecode-level bug is suspected; pair with [compiler/pipeline.md](compiler/pipeline.md) to map source→ops and [vm/dispatch.md](vm/dispatch.md) to map ops→handlers. Flags: `--eval` (evaluate first, then disassemble every chunk that compiled), `--stats` (corpus statistics instead of a listing), `--chunk N`, `--no-recurse`, `--no-source`, `--no-constants`, `--no-bytes`, `--no-pager`.
- **`inspect`** — post-eval heap/intern census; `--top N` lists the N longest interned strings (string-table bloat).
- **`--vm-trace` + `trace`** — capture a VM event stream (`--vm-trace-format binary` for volume, `--vm-trace-main-only` to drop helper noise), then inspect it with the `trace` subcommand: `trace dump` pretty-prints the binary trace as text, `trace diff` walks two binary traces to the first divergent event. The `trace` subcommand reads the binary format only.
- **`--thunks-log` + `fix thunks diff`** — the divergence workflow. When a `--workers=N` run gives a wrong answer a `--workers=1` run doesn't, record `--thunks-log` for both, then `fix thunks diff A B`. It keys thunk outcomes by the joint `(creator, target)` source-location pair — each a `(file, line, col)` triple, stable across runs even though chunk/thunk ids are not; creator alone collides across let-bindings sharing an outer span and target alone collides at synthetic `?:0:0` spans, so the pair is unique per thunk-creation site — and reports the earliest locations whose resolve/errored/reset outcome multisets differ. Filters narrow it further: `--asymmetric` (one side produced an outcome the other never did — the speculation-race smoking gun), `--novel-in b` (only where B forced something A never reached), `--by-kind` (compare by kind+discriminant, ignoring value contents, to suppress iteration-order noise), `--max-divergences N` (default 30), `--max-outcomes N` (default 5). See [runtime/thunks.md](runtime/thunks.md).
- **`--timeline`** — emits a Perfetto JSON timeline (parse/compile/import phases, per-worker fiber-run quanta, idle parks). Load it in Perfetto to *see* the serial critical path that bounds wall time → [perf/model.md](perf/model.md).

The `--vm-trace` and `--thunks-log` flags only do anything on a build compiled with the matching `-D` probe (`-Dvm-trace`, `-Dthunks-log`); the `-Dprof-main` / `-Dprof-path` reports surface through `--print-sched-stats`. `--timeline` needs no rebuild — the timeline probe is always compiled in and runtime-gated. Exercising a `-Dprof-*` probe means a rebuild. See [perf/probes.md](perf/probes.md) and [build.md](build.md).

Code: `src/main.zig` / `src/cli/`
