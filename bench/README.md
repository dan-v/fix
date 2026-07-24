# Evaluator benchmarks

The benchmark harness has three independent suites:

- `torture`: synthetic evaluator hot paths, with explicit 1/2/automatic-core
  rows where the evaluator supports them.
- `realworld`: NixOS and Home Manager scalar evaluations, including evaluator
  scaling rows where available.
- `json`: wide result trees evaluated and serialized as JSON, including
  Determinate Nix and fix scaling rows.

These fixtures are also reused for a *correctness* check, separate from the
timing harness: `zig build test-bench-fixtures` evaluates every workload under
`fix` and a reference Nix (`--eval --strict --json`) and compares the results
structurally, so a divergence on any fixture is a visible failure. Filter with
e.g. `zig build test-bench-fixtures -- torture`.

Build the contained harness and run one or more suites:

```console
$ nix-build -A bench
$ RUNS=3 ./result/bin/fix-bench torture
$ RUNS=3 ./result/bin/fix-bench realworld json
```

With no suite, all suites run. `bench.sh` is a convenience wrapper that builds
the harness without creating a `result` link. Useful environment variables are:

- `RUNS` and `WARMUP` control Hyperfine sampling.
- `RECLAIM_MEMORY=0` disables the default per-run `sudo` preparation, which
  drops reclaimable caches and compacts normal memory before every measured
  run. The harness obtains credentials once with `sudo -v`; explicit hugetlb
  pages remain in the configured pool and are reused after each evaluator exits.
- `TOOLS=nix,lix,fix-1core` selects evaluator rows. `fix` and `detsys` select
  their complete parameterized groups; individual rows can still be excluded,
  as in `TOOLS=fix,-fix-16core`. Fix profiles use 1, 2, 8, 16, and automatic
  workers. Determinate uses 1 and automatic evaluator cores in scalar suites,
  adding 2, 8, and 16 cores for JSON.
- `WORKLOADS=call-heavy,string-heavy` selects workloads by basename.
- `OUT=/path` selects the result directory instead of `/tmp/fix-bench.XXXXXX`.
- `BENCH_NIX_PATH` overrides the harness's pinned source search path.

The result root contains a compact landscape `summary.svg` / `summary.png`
covering every selected suite. Its comparison matrix shows relative wall time
per evaluator and the absolute best time for each workload. Parameter sweeps,
such as Fix workers and Determinate evaluator cores, remain expanded but are
visually grouped. Each suite directory contains Hyperfine Markdown and JSON, an
SVG and PNG for each workload, and its own detailed `summary.svg` /
`summary.png`. When one evaluator would flatten the rest of a detailed bar
chart, the renderer marks and uses a broken time axis while keeping the exact
times and relative ratios.

## Running workloads directly

Real-world and nixpkgs-backed JSON workloads resolve their sources through
`NIX_PATH`; no benchmark-specific string substitution is required:

```console
$ NIX_PATH="nixpkgs=/path/to/nixpkgs:home-manager=/path/to/home-manager" \
    nix-instantiate --eval --strict bench/workloads/realworld/nixos-minimal.nix
```

The development shell supplies both entries using the repository's pins.
