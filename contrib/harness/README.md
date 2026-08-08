# Proof harness: `fix eval-jobs` vs nix-eval-jobs, without Nix on the host

Every performance or correctness claim about `fix eval-jobs` should come out
of this harness: a Linux container (OrbStack or Docker on macOS) holding a
persistent `/nix` volume, the pinned toolchain from `shell.nix`, a running
`nix-daemon`, and pinned copies of nix-eval-jobs and the measurement tools.
The host needs Docker and git — no Nix install.

## Commands

```sh
contrib/harness/harness.sh build              # build fix (linux, ReleaseFast) in-container
contrib/harness/harness.sh parity             # correctness: fix vs nix-eval-jobs, field by field
contrib/harness/harness.sh bench              # speed + max RSS scoreboard (hyperfine)
contrib/harness/harness.sh ab origin/main     # regression gate: working tree vs baseline ref
contrib/harness/harness.sh fetch-parity       # many-git-inputs flake: store paths fix == nix
contrib/harness/harness.sh fetch-bench        # same, timed across cache states
contrib/harness/harness.sh nej-tests          # nix-eval-jobs' own pytest suite, run against
                                              # both binaries (oracle + candidate legs)
contrib/harness/harness.sh nixpkgs-diff --subtree haskellPackages
                                              # the repo's drvPath differential, in-container
contrib/harness/harness.sh shell              # poke around inside
```

Workload selection for `parity` / `bench` / `ab`:

```sh
--workload small                 # ~500 synthetic drvs, no downloads (default)
--workload nixpkgs --subtree P   # pinned-nixpkgs subtree, e.g. python3Packages
--workers N                      # worker count for BOTH tools (default 4)
--runs N                         # bench repetitions (default 5)
```

## What each check proves

- **parity** — `eval_jobs_diff.py` compares JSONL coverage (same attrs found),
  error records (same attrs fail), and `drvPath`/`name`/`system`/`outputs`.
  Equal drvPath certifies the entire derivation closure agrees, so this is a
  strong correctness oracle, not a smoke test. Fields nix-eval-jobs emits
  that fix doesn't yet (e.g. `meta`) are reported as informational gaps.
- **bench** — hyperfine wall-time distribution plus GNU-time max RSS for both
  tools against the same warmed store and daemon. Note the RSS caveat: for
  nix-eval-jobs the parent's peak excludes forked workers, so its printed
  RSS *understates* true footprint; treat cross-tool RSS as a lower bound
  and rely on the A/B mode for fix-vs-fix memory claims.
- **ab** — the regression gate for changes to fix itself: builds the working
  tree and a baseline ref, requires byte-level field agreement between their
  outputs, then benches both. Run this before claiming a change is a win.

## State and reset

Everything warm lives in two named volumes: `fix-harness-nix` (the store,
daemon state, toolchain) and `fix-harness-home` (zig caches, built fix
binaries, results under `~/.cache/harness-results`). First run downloads the
toolchain; later runs are warm. Reset with:

```sh
docker volume rm fix-harness-nix fix-harness-home
```

The baseline worktree for `ab` is created host-side under `.harness/`
(gitignored).

## Native-macOS iteration

For profiling fix natively (Instruments) while still having a real store:
the container's daemon socket can be exposed and fix pointed at it with a
`tcp://` / `unix://` store URI — see `docs/` on store selectors. Correctness
and benchmark claims should still come from the container: reference Nix and
nix-eval-jobs run Linux-side, and cross-OS comparisons aren't apples to
apples.
