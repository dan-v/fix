# `fix` + direnv (`use fix`)

`fix print-dev-env` is a `nix print-dev-env` analogue: it reproduces a
derivation's **build environment** (buildInputs on `PATH`, `NIX_CFLAGS_COMPILE`,
`shellHook`, …) *without building the derivation itself*, emitting a Bash
export script for `use nix` / `use flake`-style environments.

## Install

### With the Nix modules (recommended)

`default.nix` exposes `nixosModules.fix`, `homeManagerModules.fix`, and
`darwinModules.fix`. Import the one for your setup, enable fix, and the direnv
integration turns on automatically wherever `programs.direnv` is enabled:

```nix
{
  imports = [ (import fixSrc {}).homeManagerModules.fix ];   # or nixosModules / darwinModules
  programs.direnv.enable = true;   # `programs.direnv.fix.enable` follows this
}
```

The `use fix` integration lives at `programs.direnv.fix.enable`, alongside
`programs.direnv.{nix-direnv,mise}`. It auto-enables with direnv and installs
`fix` for you (so `use fix` resolves the CLI), sourcing `fix.sh` from the
direnvrc each module system manages — `programs.direnv.stdlib` on home-manager,
`programs.direnv.direnvrcExtra` on NixOS/nix-darwin. Set it to `false` to opt
out. To install the CLI standalone (no direnv), use `programs.fix.enable`.

### Manually

```sh
mkdir -p ~/.config/direnv/lib
cp contrib/direnv/fix.sh ~/.config/direnv/lib/fix.sh
```

(direnv auto-loads every `*.sh` under `~/.config/direnv/lib/`. Alternatively
`source` it from `~/.config/direnv/direnvrc`. The packaged copy lives at
`$out/share/fix/direnv/fix.sh`.)

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

1. `fix print-dev-env <src>` evaluates the derivation, then builds a **get-env
   derivation** — a variant of the target whose builder sources `$stdenv/setup`,
   runs the `shellHook`, and dumps the resulting environment to `$out` (matching
   `nix develop`). Because the env is computed *inside the build*, this is pure
   and works against a remote store; `$out` is read back off local disk, or via
   the daemon (`NarFromPath`) for a remote store.
2. The `use fix` function caches that script under `.direnv/`. The cache key
   includes the `fix` path, its mtime, and the command arguments.
   `shell.nix`, `default.nix`, `flake.nix`, and `flake.lock` invalidate an
   existing cache entry when newer; explicit file arguments are registered
   with direnv's `watch_file`, but are not currently part of the cache-mtime
   check.
3. It `eval`s the cached script, then appends your original `PATH` so your
   personal tools still resolve after the dev-shell tools.

## Try it without direnv

```sh
eval "$(fix print-dev-env ./shell.nix)"   # enter the dev shell in-place
```

## Caveats / not-yet

- **No GC roots.** A `nix-collect-garbage` can drop realized inputs referenced
  by a cached environment. Remove the corresponding `.direnv/fix-*.env` cache
  entry to recompute it. (A future `fix print-dev-env --add-root` would
  register roots like `nix-direnv`.)
- **`__structuredAttrs` derivations are not yet supported** (the env is emitted
  as a single `__json` blob rather than individual variables). `fix
  print-dev-env` reports this and exits non-zero.
- The env is computed by building a get-env derivation (pure), so the first run
  pays a small build; it's content-addressed, so the daemon caches it, and
  direnv caches the emitted script.
