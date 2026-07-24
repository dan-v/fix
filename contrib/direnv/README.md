# `fix` + direnv (`use fix`)

`fix print-dev-env` is a `nix print-dev-env` analogue: it reproduces a
derivation's **build environment** (buildInputs on `PATH`, `NIX_CFLAGS_COMPILE`,
`shellHook`, …) *without building the derivation itself*, emitting a flat,
side-effect-free bash script. That's exactly what direnv needs to replace
`use nix` / `use flake`.

## Install

```sh
mkdir -p ~/.config/direnv/lib
cp contrib/direnv/fix.sh ~/.config/direnv/lib/fix.sh
```

(direnv auto-loads every `*.sh` under `~/.config/direnv/lib/`. Alternatively
`source` it from `~/.config/direnv/direnvrc`.)

## Use

In a project `.envrc`:

```sh
use fix                       # ./shell.nix, else ./default.nix
use fix ./dev-shell.nix       # an explicit file
use fix -E '(import <nixpkgs> {}).hello'
use fix_flake                 # .#devShells.<system>.default
use fix_flake .#my-shell
```

then `direnv allow`.

## How it works

1. `fix print-dev-env <src>` evaluates the derivation, recovers its build
   environment, **realizes only its input derivations** (stdenv + buildInputs —
   not the derivation), then runs the derivation's own bash to
   `source $stdenv/setup` and dump the resulting environment.
2. The `use fix` function caches that script under `.direnv/`, re-running
   `fix print-dev-env` only when the fix binary or the input files change
   (`watch_file`).
3. It `eval`s the cached script, then appends your original `PATH` so your
   personal tools still resolve after the dev-shell tools.

## Try it without direnv

```sh
eval "$(fix print-dev-env ./shell.nix)"   # enter the dev shell in-place
```

## Caveats / not-yet

- **No GC roots.** A `nix-collect-garbage` can drop the realized inputs; the
  next `cd`/reload rebuilds them. (A future `fix print-dev-env --add-root` would
  register roots like `nix-direnv`.)
- **`__structuredAttrs` derivations are not yet supported** (the env is emitted
  as a single `__json` blob rather than individual variables). `fix
  print-dev-env` reports this and exits non-zero.
- The dev environment is impure (host bash runs `$stdenv/setup`), matching
  classic `nix-shell` semantics.
