# Language conformance suite

Runs the [Lix][lix] and [snix][snix] language test corpora against `fix` to
check that fix implements the Nix language the way the reference evaluators do.
Each case is a tiny Nix program with golden output; the runner drives it through
`fix` and diffs against the golden file.

This is a **differential** suite, separate from `zig build test`. The runner
discovers the pinned corpora and attempts each discovered case. A divergence,
an unsupported case, or an unrecognised custom test directory is a `FAIL`, and
any failure makes the command exit non-zero. There is no known-failures list.
`fix` currently passes both pinned suites.

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
  missing / malformed fixture or golden, a process-launch failure, a
  `parse-fail` case that does not fail at the expected line, or a `parse-okay`
  case whose AST JSON differs. **Any fail exits non-zero.**
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

- **Lix** — `tests/functional2/lang/`. Declarative `eval-okay`/`eval-fail`
  cases run through `fix eval --strict`. `parse-okay` ASTs are compared
  structurally, while `parse-fail` checks for an error and compares its line
  when both outputs provide one. Python-backed upstream directories are driven
  by explicit adapters in `lix_custom.zig`; an unrecognised one fails.
- **snix** — `contrib/nix-language-test-suite/`, an explicitly
  cross-implementation suite. Each `.kdl` descriptor selects a `.nix` input
  and either an `.exp` golden value or an `.err` error kind, matched by
  substring against `fix`'s stderr with exit status 1.

## Inventory guard

Discovery (`lix.zig`, `snix.zig`) attempts every case and does not carry a
known-failures list, so drift shows up rather than hiding: a missing input or
golden makes the case a visible `FAIL`, and a python-backed dir the adapter
dispatch (`lix_custom.zig`) does not recognise is reported as a `FAIL` (pin
drift) instead of being dropped.

## Scope / caveats

- `parse-fail` error text is not compared; the harness checks exit status,
  absence of an AST, and the error line when both sides expose one. `eval-fail`
  error text is not compared either — the Lix side asserts `rc == 1`, while the
  snix side matches the declared error kind by substring with `rc == 1`.
- `-A` / `--arg` wrap the source, so those cases lose exact source positions (see
  `src/cli/eval_support.zig`); they still compare values.

[lix]: https://git.lix.systems/lix-project/lix
[snix]: https://git.snix.dev/snix/snix
