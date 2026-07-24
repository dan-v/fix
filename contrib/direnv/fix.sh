# direnv integration for `fix` — a `use nix` / `use flake` replacement.
#
# Install one of:
#   * copy this file to ~/.config/direnv/lib/fix.sh   (auto-loaded), or
#   * add `source /path/to/fix.sh` to ~/.config/direnv/direnvrc
#
# Then in a project `.envrc`:
#   use fix                     # loads ./shell.nix (or ./default.nix)
#   use fix ./dev-shell.nix     # an explicit file
#   use fix -E '(import <nixpkgs> {}).hello'
#   use fix_flake               # loads .#devShells.<system>.default
#   use fix_flake .#my-shell
#
# Mechanism: `fix print-dev-env` reproduces the derivation's build environment
# (buildInputs on PATH, CFLAGS, shellHook, …) WITHOUT building the derivation,
# emitting a flat bash script. We cache it, re-run only when inputs change, and
# append your original PATH so personal tools still resolve (dev tools first).
#
# Caveats: no GC roots yet — a `nix-collect-garbage` can drop the realized
# inputs, and the next `cd` rebuilds them. __structuredAttrs shells are not yet
# supported. See contrib/direnv/README.md.

use_fix() {
  local -a spec=("$@")
  if [ ${#spec[@]} -eq 0 ]; then
    if [ -f shell.nix ]; then spec=(./shell.nix)
    elif [ -f default.nix ]; then spec=(./default.nix)
    else
      log_error "use fix: no argument and no ./shell.nix or ./default.nix"
      return 1
    fi
  fi
  _fix_dev_env "fix-shell" "${spec[@]}"
}

use_fix_flake() {
  local installable="${1:-.#devShells.default}"
  _fix_dev_env "fix-flake" --flake "$installable"
}

_fix_dev_env() {
  local tag="$1"
  shift
  local fixbin
  fixbin="$(command -v fix)" || {
    log_error "use fix: 'fix' not found in PATH"
    return 1
  }

  # Cache invalidates when the fix binary changes or the arguments change.
  local key
  key="$(printf '%s %s %s' "$fixbin" "$(stat -c '%Y' "$fixbin" 2>/dev/null || echo 0)" "$*" | sha1sum | cut -c1-32)"
  local cache=".direnv/${tag}-${key}.env"
  mkdir -p .direnv

  # Re-run when any obvious input file changes.
  watch_file shell.nix default.nix flake.nix flake.lock 2>/dev/null || true
  local f
  for f in "$@"; do [ -f "$f" ] && watch_file "$f"; done

  if [ ! -e "$cache" ] || _fix_inputs_newer "$cache"; then
    log_status "fix: computing dev environment ($*)…"
    if ! "$fixbin" print-dev-env "$@" >"$cache.tmp"; then
      rm -f "$cache.tmp"
      log_error "fix print-dev-env failed"
      return 1
    fi
    mv -f "$cache.tmp" "$cache"
  fi

  local orig_path="$PATH"
  # shellcheck disable=SC1090
  eval "$(cat "$cache")"
  # The dev PATH is authoritative (like `nix develop`); append yours so your
  # own tools still resolve after the dev-shell tools.
  export PATH="${PATH}:${orig_path}"
}

_fix_inputs_newer() {
  local cache="$1" f
  for f in shell.nix default.nix flake.nix flake.lock; do
    [ -e "$f" ] && [ "$f" -nt "$cache" ] && return 0
  done
  return 1
}
