# Language conformance suite

Runs the [Lix][lix] and [snix][snix] language test corpora against `fix` to
check that fix implements the Nix language the way the reference evaluators do.
Each case is a tiny Nix program with golden output; the runner drives it through
`fix` and diffs against the golden file.

This is a **differential** suite, separate from `zig build test` (the unit
tests). It is a complete, **no-skip** inventory: every case is *attempted*, and
every divergence from the reference evaluator is a `FAIL`. Any `FAIL` exits
non-zero. There is no known-failures list: any future conformance gap stays
visible instead of being papered over. `fix` currently passes both pinned suites.

## Running

```sh
zig build test-lang                    # both suites against zig-out/bin/fix
zig build test-lang -- --suite lix     # one suite
zig build test-lang -- --suite snix    # snix only
```

The runner is a self-contained Zig program (`test/lang/*.zig`, built by the
`test-lang` step). Its only hard requirement is **Nix**, to resolve the pinned
corpora. It reads pyyaml's block-YAML goldens directly (`yaml.zig`) and compares
each `parse-okay` AST to `fix parse --json` *structurally* — no python or pyyaml
dependency.

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
  --json`, AST compared structurally against the golden; `parse-fail` is
  attempted but a visible fail), and 7 custom-adapter dirs (79 cases:
  `builtins.getEnv`/`pathExists`/`readDir`/`readFileType`/`err_context` = 1 each,
  `parser-token-whitespace` = 68, `search-path` = 6; see `lix_custom.zig`),
  driven as explicit fix adapters using the upstream fixtures/goldens.
- **snix** — `contrib/nix-language-test-suite/`, an explicitly
  cross-implementation suite (116 `.kdl` cases; `meta.kdl` is docs). `.nix` input
  + `.kdl` descriptor + `.exp` (golden value) or `.err` (an error *kind*, matched
  by substring against fix's stderr, requiring `rc == 1`).

## Inventory guard

Discovery (`lix.zig`, `snix.zig`) attempts every case and does not carry a
known-failures list, so drift shows up rather than hiding: a missing input or
golden makes the case a visible `FAIL`, and a python-backed dir the adapter
dispatch (`lix_custom.zig`) does not recognise is reported as a `FAIL` (pin
drift) instead of being dropped.

## Scope / caveats

- `parse-fail` error *text* is not reproduced (attempted, reported fail).
  `eval-fail` error text is not compared either — the Lix side asserts `rc == 1`,
  the snix side matches the declared error *kind* by substring with `rc == 1`.
- `-A` / `--arg` wrap the source, so those cases lose exact source positions (see
  `src/cli/eval_support.zig`); they still compare values.

[lix]: https://git.lix.systems/lix-project/lix
[snix]: https://git.snix.dev/snix/snix
