# Engine benchmarks

The benchmark harness has three independent suites:

- `torture`: synthetic evaluator hot paths;
- `realworld`: NixOS and Home Manager scalar evaluations; and
- `json`: wide result trees evaluated and serialized as JSON.

Each suite compares one row per evaluator, each in its best default
configuration: `fix (warm)` / `fix (cold)` (automatic worker count, with the
persistent compile cache warm or wiped before every timed run), `nix`, `lix`,
and `detsys` (`--eval-cores 0`). The realworld suite adds an `all-configs`
workload — every configuration on one command line, where a parallel
evaluator can overlap independent evaluations.

These fixtures are also reused for a *correctness* check, separate from the
timing harness: `zig build test-bench-fixtures` evaluates every workload under
`fix` and a reference Nix (`--eval --strict --json`) and compares the results
structurally, so a divergence on any fixture is a visible failure. Filter with
e.g. `zig build test-bench-fixtures -- torture`.

Everything benchmark lives in this directory: `run` (the entry point),
`harness.nix` (the Nix-contained Hyperfine harness, `-A bench`), `render.py`
(the chart renderer), `workloads/`, and `results/` — the committed output
the top-level README links to.

One command reruns the whole benchmark and rewrites `results/` in place:

```console
$ ./bench/run
```

With no suite argument, all suites run (`./bench/run torture` etc. narrows).
The result tree contains `provenance.md` (date, CPU/memory/kernel, run
settings, tool versions, pinned inputs, and the measured commit — published
numbers should always cite it), transparent light/dark summary charts
(`summary.png` / `summary-dark.png`, served by the README via `<picture>`),
and per-suite directories of Hyperfine Markdown and JSON. Useful
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
- With no `TOOLS` selector, all five rows run. `TOOLS` selects rows by group
  (`fix`, `detsys`), exact name (`TOOLS='fix (warm)',lix`), or `/ERE/` regex;
  a leading `-` excludes (`TOOLS=-lix`). `./bench/run` recognizes fix-only
  selector lists and builds the lightweight `benchFix` harness, so unrelated
  evaluator packages are not realized before filtering. During focused
  development, set `TOOLS=fix` and a small `WORKLOADS` selection.
- `WORKLOADS=call-heavy,string-heavy` selects workloads by basename
  (`all-configs` selects the realworld combined lane).
- `OUT=/path` redirects output for a scratch run; the default is
  `bench/results/` via `./bench/run` (a bare `fix-bench` uses a `/tmp`
  mktemp directory).
- `BENCH_NIX_PATH` overrides the harness's pinned source search path.

The summary charts are small multiples: one panel per workload, one bar per
evaluator in fixed order, each labeled with rank, relative multiple, and
absolute time on a per-panel scale from zero. A bar past 3× the panel's
fastest tears off, with its true numbers in the label.

## Running workloads directly

Real-world and nixpkgs-backed JSON workloads resolve their sources through
`NIX_PATH`; no benchmark-specific string substitution is required:

```console
$ NIX_PATH="nixpkgs=/path/to/nixpkgs:home-manager=/path/to/home-manager" \
    nix-instantiate --eval --strict bench/workloads/realworld/nixos-minimal.nix
```

The development shell supplies both entries using the repository's pins.
