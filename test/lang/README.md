# Language conformance suite

Runs the [Lix][lix] and [snix][snix] language test corpora against `fix` to
check that fix implements the Nix language the way the reference evaluators do.
Each case is a tiny Nix program with golden output; the runner evaluates it with
`fix eval` and diffs against the golden file.

This is a **differential** suite, separate from `zig build test` (the unit
tests). Every divergence from the reference evaluator is a `FAIL`, and any
`FAIL` exits non-zero. There is no known-failures list: the conformance gap is
meant to be visible — a red run — not papered over. `fix` does **not** pass the
suite yet.

## Running

```sh
zig build test-lang                      # both suites against zig-out/bin/fix
zig build test-lang -- --suite lix -v    # one suite, with expected/actual diffs
bash test/lang/run.sh --show-skips       # also list cases the harness can't drive
```

Requirements: Nix (to resolve the pinned corpora) and a `python3` — the wrapper
borrows one from `nix-shell -p python3` when none is on `PATH`.

## Where the corpora come from

Both are pinned via [npins](../../npins/sources.json) and resolved to
`/nix/store` paths on demand, so nothing third-party is vendored here. Bump them
with `npins update lix snix`.

- **Lix** — `tests/functional2/lang/`. TOML-driven; each directory is a group of
  `eval-okay` / `eval-fail` (and `parse-*`, which we skip) runners. `eval-okay`
  is `nix-instantiate --eval --strict in.nix` compared to `<name>.out.exp`.
- **snix** — `contrib/nix-language-test-suite/`, an explicitly
  cross-implementation suite: `.nix` input + `.kdl` descriptor + `.exp` (golden
  value) or `.err` (an error *kind*, matched by substring against fix's stderr).

## What `skip` means

`skip` is **only** for cases the harness cannot drive — not for language
behavior fix gets wrong (those are `FAIL`s). A case is skipped when it:

- needs a running store/daemon or network (`.kdl` `network` / `nix-store`);
- requires a flag fix doesn't have (e.g. Lix's `--no-location` for XML) or an
  experimental feature fix doesn't implement;
- needs a fixture fix's harness can't create without privileges (device / fifo /
  socket nodes); or
- Lix's `parse-okay` / `parse-fail` runners, which dump Lix's internal AST as
  YAML — not a portable target.

## Scope / caveats

- Only the `eval` runners are exercised. Lix `parse-*` cases are skipped.
- For `eval-fail`, fix's error *text* isn't compared (it differs by design); the
  Lix side asserts only that evaluation fails, and the snix side matches the
  declared error *kind* by substring — mirroring snix's own reference runner.
- `-A` / `--arg` wrap the source, so those cases lose exact source positions
  (see `src/cli/run.zig`); they still compare values.

[lix]: https://git.lix.systems/lix-project/lix
[snix]: https://git.snix.dev/snix/snix
