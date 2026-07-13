# Language conformance suite

Runs the [Lix][lix] and [snix][snix] language test corpora against `fix` to
check that fix implements the Nix language the way the reference evaluators do.
Each case is a tiny Nix program with golden output; the runner drives it through
`fix` and diffs against the golden file.

This is a **differential** suite, separate from `zig build test` (the unit
tests). It is a complete, **no-skip** inventory: every case is *attempted*, and
every divergence from the reference evaluator is a `FAIL`. Any `FAIL` exits
non-zero. There is no known-failures list — the conformance gap is meant to be
visible (a red run), not papered over. `fix` does **not** pass the suite yet.

## Running

```sh
zig build test-lang                      # both suites against zig-out/bin/fix
zig build test-lang -- --suite lix -v    # one suite, with expected/actual diffs
bash test/lang/run.sh --suite snix       # snix only
bash test/lang/run-unit.sh               # inventory / no-skip / false-green unit tests
```

Hard requirements: **Nix** (to resolve the pinned corpora) and a **python3 with
pyyaml** — the wrapper borrows one from `nix-shell -p python3
python3Packages.pyyaml` when none is on `PATH`. pyyaml normalizes `fix parse
--json` output the way the Lix lang-runner does.

## Status model

Every case ends in exactly one of three states:

- **pass** — fix matches the reference evaluator.
- **fail** — a real conformance gap, *or* a case the harness cannot honestly
  drive: an unsupported flag / experimental feature (translation failure), a
  missing / malformed fixture or golden, a process-launch failure, a `parse-fail`
  case (attempted, but we do not reproduce Nix's exact parser error strings), or
  a `parse-okay` case whose AST JSON differs. **Any fail exits non-zero.**
- **blocked** — the case's *external* dependency is provably absent, and there is
  nothing fix could do about it here: no nix-daemon / writable store
  (`nix-store` cases), or no rootless user+mount namespace / system device for a
  device fixture. `blocked` is **always printed** with its reason, is **never**
  counted as a pass, and does **not** fail the build.

There is no `skip`. Anything that "can't be driven" for a reason *within* fix's
control (unsupported feature, malformed case) is a `fail`, not `blocked`.

## Where the corpora come from

Both are pinned via [npins](../../npins/sources.json) and resolved to
`/nix/store` paths on demand, so nothing third-party is vendored here. Bump them
with `npins update lix snix`.

- **Lix** — `tests/functional2/lang/`. 211 declarative `eval-okay`/`eval-fail`
  cases (`fix eval --strict`), 67 declarative `parse-*` cases (`fix parse
  --json`, JSON→YAML normalized vs the golden; `parse-fail` is attempted but a
  visible fail), and the 7 python-backed custom dirs (79 cases:
  `builtins.getEnv`/`pathExists`/`readDir`/`readFileType`/`err_context` = 1 each,
  `parser-token-whitespace` = 68, `search-path` = 6), driven as explicit fix
  adapters using the upstream fixtures/goldens.
- **snix** — `contrib/nix-language-test-suite/`, an explicitly
  cross-implementation suite (116 `.kdl` cases; `meta.kdl` is docs). `.nix` input
  + `.kdl` descriptor + `.exp` (golden value) or `.err` (an error *kind*, matched
  by substring against fix's stderr, requiring `rc == 1`).

## Inventory guard

`run-unit.sh` runs unittest-style tests that independently re-scan the corpora
and assert the counts (211 eval, 67 parse, 79 custom = 1/1/1/1/1/68/6, 116 snix),
that discovery omits nothing, that the false-green sites stay closed (eval-fail
requires `rc == 1`, missing goldens fail, unsupported flags/features fail), and
that `blocked` does not fail the build while any other non-pass status does. A
pin bump that changes an inventory count or adds an unrecognised case fails these.

## Scope / caveats

- `parse-fail` error *text* is not reproduced (attempted, reported fail).
  `eval-fail` error text is not compared either — the Lix side asserts `rc == 1`,
  the snix side matches the declared error *kind* by substring with `rc == 1`.
- `-A` / `--arg` wrap the source, so those cases lose exact source positions (see
  `src/cli/run.zig`); they still compare values.

[lix]: https://git.lix.systems/lix-project/lix
[snix]: https://git.snix.dev/snix/snix
