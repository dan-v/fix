![fix](demo/banner.svg)

# fix

`fix` is a fast, parallel evaluator and command-line tool for the Nix language,
written in Zig.

It is a from-scratch implementation, not a wrapper around the Nix evaluator.
`fix` parses Nix source, compiles it to bytecode, evaluates expressions lazily,
computes derivations and store paths, and speaks the Nix daemon protocol for
store operations and builds. It is intended to run existing Nix expressions
and produce the same values and derivations while making evaluation faster.

`fix` also treats the evaluator as something you should be able to inspect. It
includes a heap and bytecode explorer, a source-level debugger, an interactive
REPL, evaluation statistics, and Perfetto-compatible traces.

![Exploring a running evaluation with fix](demo/explorer.gif)

## What is different

### Parallel lazy evaluation

`fix` can evaluate thunk work on multiple worker threads. A thunk contains a
`Future`: one fiber claims an unresolved thunk, while another fiber that reaches
the same in-flight thunk can park and let its worker run something else.
Speculative forcing and strict-demand fan-out provide work for otherwise idle
workers; both can be disabled when diagnosing parallel behavior.

The worker count is configurable, including a single-worker mode when
repeatability or debugging matters more than throughput.

### Compatibility you can measure

Compatibility is a target backed by several kinds of tests:

- Derivation tests cover canonical ATerm serialization, hashing, string
  context, and expected `.drv` and output store paths.
- The pinned Lix and snix language suites compare evaluation and parse results.
- A separate differential test evaluates every benchmark fixture with `fix`
  and a reference Nix, then compares the strict JSON results structurally.
- `fix parse` emits the same JSON-shaped syntax tree used by
  `nix-instantiate --parse`.

The current pinned language suites pass. See
[the language-test documentation](test/lang/README.md) for exactly what is run.

### An evaluator you can look inside

The VM explorer and debugger are part of `fix`, rather than separate
instrumented builds. They operate on the real compiler, bytecode, stacks,
thunks, and heap used by ordinary evaluations.

The explorer can move from source expressions to compiled chunks and
instructions, inspect heap objects and their references, search stores, and set
breakpoints. Large chunk and object collections are represented with range
nodes and bounded queries rather than one UI row per entry.

The debugger supports:

- pending and resolved source-line breakpoints;
- `builtins.break` and stops on evaluation errors;
- step, next, finish, and continue;
- lexical locals, captured values, the operand stack, and annotated bytecode;
- evaluating a Nix expression in the scope of the current pause; and
- opening the VM explorer without leaving the debugging session.

`fix eval --debugger` and `fix repl --debugger` use one worker. A transient
`:debug` session in an ordinary REPL temporarily disables parallel submissions.

![A source breakpoint in the fix debugger](demo/debugger.gif)

This demo first evaluates a NixOS toplevel, then starts a debugger session while
that evaluation's heap remains available to inspect.

![Debugging after a NixOS evaluation with a large retained heap](demo/nixos-debugger.gif)

## Quick start

The packaged build currently targets Linux. Nix is required to build `fix`, and
commands that write to or realize the store require a reachable Nix daemon.
Build it from the repository with:

```console
$ git clone https://github.com/psyclyx/fix
$ cd fix
$ nix-build -A fix
```

The executable is `result/bin/fix`:

```console
$ ./result/bin/fix eval -E '1 + 2'
3

$ ./result/bin/fix build -f default.nix -A fix

$ ./result/bin/fix repl
```

The package also includes shell completions for Bash, Fish, and Zsh.

## What it can do

`fix` covers the common path from evaluating an expression to realizing and
running its output:

| Command | Purpose |
| --- | --- |
| `fix eval` | Evaluate expressions, files, attributes, or flake outputs |
| `fix instantiate` | Evaluate derivations and write their `.drv` files |
| `fix build` | Evaluate and build derivations, with result links and GC roots |
| `fix run` | Build an installable and run its declared program |
| `fix shell` | Enter a shell containing selected packages |
| `fix print-dev-env` | Emit a derivation's build environment as a shell script |
| `fix repl` | Evaluate interactively and enter the explorer or debugger |
| `fix parse` | Parse Nix and emit a compatible JSON syntax tree |
| `fix disasm` | Compile an expression and print its bytecode |
| `fix flake` | Show, check, lock, update, and inspect flake metadata |
| `fix switch` | Build and activate a system or user configuration |
| `fix completions` | Generate shell completions |

Run `fix <command> --help` for the documented inputs and options.

### Evaluate, instantiate, and build

Commands accept expressions, files, attribute paths, and repeated mixed inputs:

```console
$ fix eval -E '{ answer = 6 * 7; }' -A answer
42

$ fix eval --strict --json ./packages.nix

$ fix instantiate -f default.nix -A fix
/nix/store/...-fix.drv

$ fix build -f default.nix -A fix
```

Arguments can be supplied with `--arg` and `--argstr`. Evaluation can produce
Nix, JSON, XML, or raw output, and can be made strict. Builds can target the
local daemon or remote `ssh-ng://` and `tcp://` stores.

### Run programs and open temporary shells

```console
$ fix run --flake nixpkgs#hello

$ fix shell -p ripgrep jq
```

`fix run` builds the selected installable and chooses its executable from
`meta.mainProgram`, `pname`, or `name`. `fix shell` constructs and realizes an
environment containing the requested packages.

Flake commands require Nix's `flakes` experimental feature. Enable it in
`nix.conf`, or pass it for an invocation:

```console
$ fix flake show . --extra-experimental-features flakes
```

### Development environments and direnv

`fix print-dev-env` evaluates a derivation and prints a Bash program that
reconstructs its build environment without building the derivation:

```console
$ eval "$(fix print-dev-env ./shell.nix)"
```

The included direnv integration provides `use fix` and `use fix_flake`. See
[the direnv documentation](contrib/direnv/README.md) for installation and
options.

### `fix switch`

`fix switch` can build and activate NixOS configurations. It also implements
the conventional nix-darwin and Home Manager activation paths, although those
two have not been verified locally. It supports `switch`, `boot`, `test`,
`build`, and `dry-activate` actions, as well as remote activation with
`--target-host`. When supplied, the action must be the first argument after
`fix switch`.

```console
$ fix switch --nixos

$ fix switch build --home-manager --flake .#me

$ fix switch --nixos --target-host host.example
```

This command is intentionally experimental. I am still thinking about what
exactly `fix switch` should be—its scope, its interface, and its relationship to
the existing rebuild tools—and it will likely change in the future. Treat the
current command as a useful prototype, not a stable automation interface.

## Explorer and debugger

Start the REPL with `fix repl`. From there:

- `:vm` opens the full-screen VM explorer;
- `:d EXPR` evaluates an expression in the debugger; and
- `:help` lists the available REPL commands.

The debugger can also be enabled directly on an evaluation:

```console
$ fix eval --debugger ./expression.nix
```

Inside the debugger, `break FILE:LINE` adds a source breakpoint. A breakpoint
may remain pending until that source is compiled; it resolves automatically
when the matching code appears. `breakpoints` lists breakpoints and `delete N`
removes one.

Both tools also have bounded text output for non-interactive use. Start the REPL
with `fix repl --no-tui` when an alternate-screen interface is undesirable.

## Performance

The chart below compares wall-clock evaluation time across synthetic stress
tests, real NixOS and Home Manager configurations, and JSON-producing
workloads. Each cell is relative to the fastest evaluator for that workload;
`1.00×` is fastest. The harness defaults to ten recorded runs.

![fix evaluator benchmark](demo/benchmark.png)

These results are point-in-time measurements from pinned inputs, not a claim
that `fix` wins every workload. The timing harness uses Hyperfine, with separate
warmup and measured runs and optional cache reclamation between runs.
Correctness is checked separately by `zig build test-bench-fixtures`; it is not
part of the timing script. See [the benchmark documentation](bench/README.md)
for the workloads and reproduction commands.

## Installing through a module

The repository exports modules for NixOS, nix-darwin, and Home Manager:

```nix
let
  fixSource = /path/to/a/pinned/fix;
  fixProject = import fixSource {};
in {
  imports = [
    fixProject.homeManagerModules.fix
  ];

  programs.fix.enable = true;
}
```

Use `nixosModules.fix` or `darwinModules.fix` in the corresponding module
system. Enabling `programs.direnv` enables the bundled integration by default
and installs `fix`; it can be controlled explicitly with
`programs.direnv.fix.enable`. Use `programs.fix.enable` when you want the CLI
without direnv.

## Project status

`fix` is under active development. Compatibility is a concrete target and is
continuously tested, but this is not yet a promise that every Nix program or
workflow is supported. Linux is the primary and currently packaged target.
Keep Nix installed: `fix` uses the Nix daemon for store operations and builds.

If `fix` produces a different value, derivation, or store path from Nix for
supported input, that is a bug.

## Development

Enter the pinned development environment and build an optimized binary with:

```console
$ nix-shell --run 'zig build -Doptimize=ReleaseFast'
```

The result is `zig-out/bin/fix`. Useful checks include:

```console
$ zig build test
$ zig build check
$ zig build test-lang
$ zig build test-bench-fixtures
```

Start with [the developer documentation](docs/README.md) for the architecture,
runtime invariants, testing strategy, and performance model.
