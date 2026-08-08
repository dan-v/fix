# Engine benchmarks

The benchmark harness has three independent suites:

- `torture`: synthetic evaluator hot paths;
- `realworld`: NixOS and Home Manager scalar evaluations; and
- `json`: wide result trees evaluated and serialized as JSON.

By default, each suite compares 1-core and automatic profiles for Fix and
Determinate alongside the other applicable evaluators. Full core-count sweeps
remain available through explicit `TOOLS` selectors.

These fixtures are also reused for a *correctness* check, separate from the
timing harness: `zig build test-bench-fixtures` evaluates every workload under
`fix` and a reference Nix (`--eval --strict --json`) and compares the results
structurally, so a divergence on any fixture is a visible failure. Filter with
e.g. `zig build test-bench-fixtures -- torture`.

Build the contained harness and run one or more suites:

```console
$ nix-build -A bench
$ TOOLS=fix-1core RUNS=3 ./result/bin/fix-bench torture
$ RUNS=3 ./result/bin/fix-bench realworld json
```

With no suite, all suites run. `bench.sh` is a convenience wrapper that builds
the harness without creating a `result` link. Every result tree includes a
`provenance.md` recording the date, CPU/memory/kernel, run settings, tool
versions, and pinned inputs of the measurement (plus the fix commit when
launched via `bench.sh`); published numbers should always cite it. Useful
environment variables are:

- `RUNS` and `WARMUP` control Hyperfine sampling. They default to 5 measured
  runs and 1 warmup.
- `RECLAIM_MEMORY=0` disables the default per-run `sudo` preparation, which
  drops reclaimable caches and compacts normal memory before every measured
  run. The harness obtains credentials once with `sudo -v`; explicit hugetlb
  pages remain in the configured pool and are reused after each evaluator exits.
- `HUGETLB_MIN_AVAILABLE` sets the minimum number of unreserved free 2 MiB
  hugetlb pages required before each run when a pool is configured. It defaults
  to 1024 (2 GiB); set it to 0 to disable the capacity check. Other programs may
  use the pool as long as this much capacity remains available.
- With no `TOOLS` selector, the harness runs 1-core and automatic profiles for
  Fix and Determinate, plus the available Nix and Lix rows.
  `TOOLS=nix,lix,fix-1core` selects exact evaluator rows. `fix` and `detsys`
  select their complete 1, 2, 8, 16, and automatic parameterized groups for a
  deliberate scaling sweep; individual rows can still be excluded, as in
  `TOOLS=fix,-fix-16core`.
- During focused development, always set `TOOLS` explicitly (normally
  `TOOLS=fix-1core`, optionally plus one relevant parallel Fix row). The `fix`
  group expands to every worker profile and is intended for a deliberate full
  matrix, not a routine refactor check. `bench.sh` recognizes Fix-only selector
  lists and builds the lightweight `benchFix` harness, so unrelated evaluator
  packages are not realized before filtering.
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
