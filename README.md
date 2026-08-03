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
repeatability or debugging matters more than throughput. Memory is managed by
a parallel generational garbage collector.

The core concurrency protocols — future wait, fiber dispatch, shutdown, and
the GC barrier — are [modeled in TLA+](model/README.md) and checked for
safety, deadlock freedom, and liveness. A nightly CI lane evaluates real
configurations in parallel against a reference Nix under ThreadSanitizer.

### Compatibility you can measure

Compatibility is a target backed by several kinds of tests:

- Derivation tests cover canonical ATerm serialization, hashing, string
  context, and expected `.drv` and output store paths.
- The pinned Lix and snix language suites compare evaluation and parse results.
- A separate differential test evaluates every benchmark fixture with `fix`
  and a reference Nix, then compares the strict JSON results structurally.
- A whole-nixpkgs differential evaluates the entire nixpkgs CI job universe
  (`ci/eval/outpaths.nix`, about 80,000 derivations) with `fix` and a
  reference Nix and compares every `.drv` store path. A drvPath match
  certifies the complete derivation that produced it — inputs, environment,
  and builder, transitively.
- `fix parse` emits the same JSON-shaped syntax tree used by
  `nix-instantiate --parse`.

The current pinned language suites pass, and the pinned nixpkgs universe
evaluates to identical derivation paths (80,586 of 80,586 attributes,
including agreement on which attributes fail to evaluate). See
[the language-test documentation](test/lang/README.md) for exactly what is
run. The nixpkgs differential runs monolithically with
`zig build test-nixpkgs` (it wants a large-memory machine and caches the
reference results per pin) and as a sharded matrix in CI.

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

`fix` is alpha-quality software under active development. Development currently
takes place on x86_64 Linux; other platforms have not received the same level
of use.

Nix is not required to build `fix`. A direct build requires Zig 0.16,
`pkg-config`, libcurl, and libgit2:

```console
$ git clone https://github.com/psyclyx/fix
$ cd fix
$ zig build --release=fast
```

The executable is `zig-out/bin/fix`. Alternatively, Nix can provide the pinned
build environment and dependencies:

```console
$ nix-shell --run 'zig build --release=fast'
```

Evaluation does not require a Nix or Lix executable; store-writing commands
need a reachable Nix or Lix daemon. Tagged releases publish optimized build
archives for x86_64 Linux, aarch64 Linux, and aarch64 macOS.

```console
$ ./zig-out/bin/fix eval -E '1 + 2'
3

$ ./zig-out/bin/fix build -A fix

$ ./zig-out/bin/fix repl
```

The package also includes shell completions for Bash, Fish, and Zsh.

### Nix and Lix runtime compatibility

`fix` speaks the stable Nix worker protocol to CppNix and Lix daemons
(Nix ≥ 2.4) over `daemon`, `unix://`, `tcp://`, and `ssh-ng://` stores.
`local`/`auto` stores and Lix's experimental `lix-xp-1` protocol are not
implemented and fail explicitly — nothing falls back to an installed Nix.
The selector matrix and configuration details are in
[Nix/Lix store compatibility](docs/store-compatibility.md).

`<nixpkgs>` and other lookup paths resolve like Nix's: from `-I`, then
`$NIX_PATH`, and — when neither is set — from the user and root channel
profiles, so a machine configured purely through `nix-channel` works without
any environment setup.

`builtins.nixVersion` deliberately reports `2.18.3`: it is the evaluator
compatibility baseline, not the version of the connected daemon. Supported
experimental and deprecated language switches are listed in
[the CLI reference](docs/cli.md#evaluation--output).

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

Commands accept expressions, file paths, attribute paths, and repeated mixed
inputs. File paths are positional, and omitting the source uses `./default.nix`:

```console
$ fix eval -E '{ answer = 6 * 7; }' -A answer
42

$ fix eval --strict --json packages.nix

$ fix instantiate -A fix
/nix/store/...-fix.drv

$ fix build -A fix
```

Arguments can be supplied with `--arg` and `--argstr`. Evaluation can produce
Nix, JSON, XML, or raw output, and can be made strict. Builds can target direct
Unix-socket, SSH, and TCP daemon endpoints.

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
`build`, and `dry-activate` actions. When supplied, the action must be the first
argument after `fix switch`.

```console
$ fix switch --nixos

$ fix switch build --home-manager --flake .#me
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
removes one. `:gc` runs a full collection while preserving the paused session's
values and refreshes the heap views.

Both tools also have bounded text output for non-interactive use. Start the REPL
with `fix repl --no-tui` when an alternate-screen interface is undesirable.

## Performance

The chart below compares wall-clock evaluation time across synthetic stress
tests, real NixOS and Home Manager configurations, and JSON-producing
workloads. Each cell is relative to the fastest evaluator for that workload;
`1.00×` is fastest. The harness defaults to five recorded runs.

![fix evaluator benchmark](demo/benchmark.png)

<details>
<summary>Full benchmark tables</summary>

### Torture

#### `attrset-heavy`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 64.2 ± 1.5 | 62.4 | 65.7 | 1.00 ± 0.07 |
| `fix-autocore` | 72.3 ± 3.3 | 67.9 | 75.8 | 1.13 ± 0.09 |
| `nix` | 64.1 ± 4.2 | 59.7 | 70.5 | 1.00 |
| `lix` | 77.7 ± 2.3 | 75.1 | 80.8 | 1.21 ± 0.09 |
| `detsys-1core` | 83.8 ± 10.6 | 75.6 | 101.5 | 1.31 ± 0.19 |
| `detsys-autocore` | 75.9 ± 0.8 | 75.1 | 77.2 | 1.18 ± 0.08 |

#### `call-heavy`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 222.2 ± 5.8 | 216.3 | 231.1 | 1.00 |
| `fix-autocore` | 224.2 ± 2.9 | 220.3 | 227.6 | 1.01 ± 0.03 |
| `nix` | 330.6 ± 12.1 | 323.9 | 352.1 | 1.49 ± 0.07 |
| `lix` | 307.6 ± 1.4 | 305.3 | 308.6 | 1.38 ± 0.04 |
| `detsys-1core` | 507.7 ± 2.8 | 505.1 | 512.3 | 2.29 ± 0.06 |
| `detsys-autocore` | 502.9 ± 15.0 | 476.3 | 511.6 | 2.26 ± 0.09 |

#### `fixpoint-heavy`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 18.6 ± 0.7 | 17.5 | 19.5 | 1.00 |
| `fix-autocore` | 22.9 ± 0.4 | 22.4 | 23.3 | 1.23 ± 0.05 |
| `nix` | 24.9 ± 2.0 | 21.4 | 26.6 | 1.34 ± 0.12 |
| `lix` | 22.7 ± 0.7 | 21.6 | 23.7 | 1.22 ± 0.06 |
| `detsys-1core` | 31.0 ± 1.2 | 29.1 | 32.4 | 1.67 ± 0.09 |
| `detsys-autocore` | 31.4 ± 3.7 | 25.1 | 34.5 | 1.69 ± 0.21 |

#### `list-heavy`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 115.1 ± 3.4 | 111.6 | 120.7 | 1.00 |
| `fix-autocore` | 128.5 ± 8.8 | 121.0 | 143.8 | 1.12 ± 0.08 |
| `nix` | 151.6 ± 2.4 | 149.1 | 154.7 | 1.32 ± 0.04 |
| `lix` | 135.2 ± 2.7 | 132.1 | 139.3 | 1.18 ± 0.04 |
| `detsys-1core` | 216.3 ± 1.0 | 215.4 | 217.7 | 1.88 ± 0.06 |
| `detsys-autocore` | 218.5 ± 2.8 | 215.9 | 223.3 | 1.90 ± 0.06 |

#### `math-heavy`

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 1.127 ± 0.010 | 1.117 | 1.143 | 1.00 |
| `fix-autocore` | 1.185 ± 0.016 | 1.170 | 1.205 | 1.05 ± 0.02 |
| `nix` | 1.329 ± 0.030 | 1.295 | 1.377 | 1.18 ± 0.03 |
| `lix` | 1.149 ± 0.008 | 1.140 | 1.161 | 1.02 ± 0.01 |
| `detsys-1core` | 2.012 ± 0.039 | 1.949 | 2.055 | 1.79 ± 0.04 |
| `detsys-autocore` | 2.036 ± 0.014 | 2.014 | 2.049 | 1.81 ± 0.02 |

#### `spec-pathology`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 44.7 ± 2.4 | 41.9 | 48.1 | 1.03 ± 0.06 |
| `fix-autocore` | 79.2 ± 3.9 | 75.6 | 85.7 | 1.82 ± 0.11 |
| `nix` | 50.9 ± 2.2 | 48.3 | 53.4 | 1.17 ± 0.06 |
| `lix` | 43.5 ± 1.4 | 41.9 | 45.5 | 1.00 |
| `detsys-1core` | 63.1 ± 2.0 | 60.0 | 64.9 | 1.45 ± 0.07 |
| `detsys-autocore` | 64.1 ± 2.4 | 61.5 | 66.9 | 1.47 ± 0.07 |

#### `string-heavy`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 88.8 ± 1.1 | 87.7 | 90.5 | 1.00 |
| `fix-autocore` | 121.9 ± 4.6 | 117.4 | 129.1 | 1.37 ± 0.05 |
| `nix` | 92.3 ± 1.4 | 91.0 | 94.3 | 1.04 ± 0.02 |
| `lix` | 95.8 ± 2.4 | 93.7 | 98.5 | 1.08 ± 0.03 |
| `detsys-1core` | 130.2 ± 34.1 | 113.6 | 191.1 | 1.47 ± 0.38 |
| `detsys-autocore` | 116.0 ± 1.5 | 114.3 | 118.1 | 1.31 ± 0.02 |

### Real-world configurations

#### `hm-profile`

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 1.304 ± 0.002 | 1.302 | 1.308 | 1.60 ± 0.04 |
| `fix-autocore` | 0.815 ± 0.019 | 0.789 | 0.835 | 1.00 |
| `nix` | 1.372 ± 0.009 | 1.364 | 1.386 | 1.68 ± 0.04 |
| `lix` | 1.309 ± 0.014 | 1.295 | 1.330 | 1.61 ± 0.04 |
| `detsys-1core` | 1.673 ± 0.035 | 1.642 | 1.728 | 2.05 ± 0.06 |
| `detsys-autocore` | 1.654 ± 0.029 | 1.623 | 1.686 | 2.03 ± 0.06 |

#### `nixos-desktop`

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 2.727 ± 0.020 | 2.715 | 2.760 | 2.88 ± 0.05 |
| `fix-autocore` | 0.947 ± 0.016 | 0.923 | 0.965 | 1.00 |
| `nix` | 2.702 ± 0.029 | 2.660 | 2.727 | 2.85 ± 0.06 |
| `lix` | 2.547 ± 0.030 | 2.514 | 2.585 | 2.69 ± 0.05 |
| `detsys-1core` | 3.331 ± 0.040 | 3.295 | 3.394 | 3.52 ± 0.07 |
| `detsys-autocore` | 3.335 ± 0.024 | 3.316 | 3.377 | 3.52 ± 0.06 |

#### `nixos-hm`

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 2.978 ± 0.023 | 2.945 | 3.005 | 2.91 ± 0.04 |
| `fix-autocore` | 1.022 ± 0.011 | 1.004 | 1.033 | 1.00 |
| `nix` | 3.015 ± 0.030 | 2.978 | 3.048 | 2.95 ± 0.04 |
| `lix` | 2.898 ± 0.034 | 2.871 | 2.946 | 2.84 ± 0.04 |
| `detsys-1core` | 3.720 ± 0.023 | 3.692 | 3.754 | 3.64 ± 0.04 |
| `detsys-autocore` | 3.681 ± 0.022 | 3.662 | 3.708 | 3.60 ± 0.04 |

#### `nixos-minimal`

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 2.144 ± 0.030 | 2.106 | 2.183 | 3.57 ± 0.10 |
| `fix-autocore` | 0.600 ± 0.015 | 0.579 | 0.617 | 1.00 |
| `nix` | 2.167 ± 0.042 | 2.132 | 2.231 | 3.61 ± 0.11 |
| `lix` | 2.080 ± 0.051 | 2.021 | 2.151 | 3.47 ± 0.12 |
| `detsys-1core` | 2.701 ± 0.005 | 2.692 | 2.706 | 4.50 ± 0.11 |
| `detsys-autocore` | 2.738 ± 0.038 | 2.701 | 2.781 | 4.56 ± 0.13 |

### JSON

#### `nested-records`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 21.3 ± 0.2 | 21.1 | 21.6 | 1.00 |
| `fix-autocore` | 30.4 ± 0.8 | 29.2 | 31.3 | 1.43 ± 0.04 |
| `nix` | 38.2 ± 0.7 | 37.3 | 38.9 | 1.79 ± 0.04 |
| `lix` | 39.5 ± 0.9 | 38.1 | 40.2 | 1.85 ± 0.04 |
| `detsys-1core` | 48.3 ± 3.5 | 45.6 | 54.2 | 2.27 ± 0.17 |
| `detsys-autocore` | 49.4 ± 0.8 | 48.2 | 50.3 | 2.32 ± 0.04 |

#### `nixpkgs-package-metadata`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 608.8 ± 12.0 | 601.8 | 630.1 | 1.44 ± 0.03 |
| `fix-autocore` | 424.2 ± 3.2 | 420.1 | 427.7 | 1.00 |
| `nix` | 1077.9 ± 21.2 | 1055.2 | 1106.7 | 2.54 ± 0.05 |
| `lix` | 1234.5 ± 31.1 | 1203.3 | 1286.6 | 2.91 ± 0.08 |
| `detsys-1core` | 1136.0 ± 22.6 | 1110.7 | 1171.3 | 2.68 ± 0.06 |
| `detsys-autocore` | 834.4 ± 14.9 | 822.5 | 859.9 | 1.97 ± 0.04 |

#### `wide-call-tree`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 445.2 ± 10.9 | 432.9 | 462.4 | 3.58 ± 0.10 |
| `fix-autocore` | 165.2 ± 1.6 | 163.2 | 167.5 | 1.33 ± 0.02 |
| `nix` | 654.9 ± 16.1 | 643.0 | 680.8 | 5.26 ± 0.15 |
| `lix` | 617.9 ± 15.6 | 605.6 | 642.4 | 4.97 ± 0.14 |
| `detsys-1core` | 998.8 ± 40.2 | 957.4 | 1041.6 | 8.03 ± 0.34 |
| `detsys-autocore` | 124.4 ± 1.6 | 122.4 | 126.5 | 1.00 |

#### `wide-list-pipelines`

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `fix-1core` | 334.6 ± 2.8 | 330.4 | 337.3 | 3.82 ± 0.12 |
| `fix-autocore` | 87.7 ± 2.7 | 85.4 | 92.0 | 1.00 |
| `nix` | 448.0 ± 10.8 | 436.4 | 461.3 | 5.11 ± 0.20 |
| `lix` | 395.4 ± 6.0 | 384.7 | 398.5 | 4.51 ± 0.15 |
| `detsys-1core` | 653.8 ± 5.2 | 647.0 | 659.0 | 7.46 ± 0.23 |
| `detsys-autocore` | 661.2 ± 16.2 | 641.3 | 686.2 | 7.54 ± 0.29 |

</details>

These results are point-in-time measurements from pinned inputs, not a claim
that `fix` wins every workload. The timing harness uses Hyperfine, with separate
warmup and measured runs and optional cache reclamation between runs.
Correctness is checked separately by `zig build test-bench-fixtures`; it is not
part of the timing script. See [the benchmark documentation](bench/README.md)
for the workloads and reproduction commands.

### A less rigorous benchmark
`fix` runs [nixboy](https://github.com/psyclyx/nixboy), a Game Boy emulator written in Nix.

<details>
<summary>Pokemon Red (every third frame, playback 2x speed)</summary>

https://github.com/user-attachments/assets/0353b17c-f196-4dda-ba19-1329b651d9ae

</details>

<details>
<summary>Bad Apple!! (every frame, playback 5x speed)</summary>
  
https://github.com/user-attachments/assets/3e3e44af-03dc-4c4d-89aa-e64eddf847cc

</details>

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

`fix` is alpha-quality software under active development. Compatibility is a
concrete target and is continuously tested, but this is not yet a promise that
every Nix program or workflow is supported. Development currently takes place
on x86_64 Linux; release builds also cover aarch64 Linux and aarch64 macOS.
Keep Nix installed: it is a runtime requirement because `fix` uses the Nix
daemon for store operations and builds.

If `fix` produces a different value, derivation, or store path from Nix for
supported input, that is a bug. Releases are documented in
[the changelog](CHANGELOG.md).

## Development

Enter the pinned development environment and build an optimized binary with:

```console
$ nix-shell --run 'zig build --release=fast'
```

The result is `zig-out/bin/fix`. Useful checks include:

```console
$ zig build test
$ zig build check
$ zig build test-lang
$ zig build test-bench-fixtures
$ zig build test-nixpkgs
```

Start with [the developer documentation](docs/README.md) for the architecture,
runtime invariants, testing strategy, and performance model.
