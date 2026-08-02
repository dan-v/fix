#!/usr/bin/env bash
# One-shot wall/RSS comparison of the whole-nixpkgs universe eval across
# evaluators: fix, Lix, CppNix, and Determinate Nix (same pins as the
# benchmark harness). Each evaluator runs ONCE — this is a scale probe, not a
# statistical benchmark; use bench.sh/hyperfine for timing claims.
#
#   test/nixpkgs/bench.sh                 # full universe (fix wants ~51 GB)
#   test/nixpkgs/bench.sh --subtree haskellPackages
#
# All reference evaluators run `nix-instantiate --eval --strict --json
# --readonly-mode` (single-threaded, no store writes); fix runs with default
# workers. detsys-autocore additionally exercises Determinate's parallel
# `nix eval --eval-cores 0`.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fix="$repo/zig-out/bin/fix"
subtree=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subtree) subtree="$2"; shift 2 ;;
    --fix) fix="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -x "$fix" ]] || { echo "fix binary not found at $fix (build with \`zig build\`)" >&2; exit 2; }

echo ">> resolving pinned evaluators (cached in the store after the first run)" >&2
nixpkgs="$(nix-build --no-out-link --expr "
  let pkgs = import <nixpkgs> {};
      source = (import $repo/npins).nixpkgs;
  in pkgs.runCommand \"fix-lang-nixpkgs\" {} \"cp -R \${source}/. \$out\"")"
gnu_time="$(nix-build --no-out-link -E \
  "(import (import $repo/npins).nixpkgs {}).time")/bin/time"
lix="$(nix-build --no-out-link -E \
  "(import (import $repo/npins).nixpkgs {}).lix")"
cppnix="$(nix-build --no-out-link -E \
  "(import (import $repo/npins).nixpkgs {}).nixVersions.latest")"
detsys="$(nix-build --no-out-link --extra-experimental-features flakes -E "
  let sources = import $repo/npins;
  in (builtins.getFlake (builtins.unsafeDiscardStringContext (toString sources.determinate-nix)))
    .packages.\${builtins.currentSystem}.nix-cli")"

args=(--arg nixpkgs "$nixpkgs")
[[ -n "$subtree" ]] && args+=(--argstr subtree "$subtree")
expr="$repo/test/nixpkgs/outpaths.nix"

printf '%-16s %10s %12s %8s\n' evaluator wall maxrss attrs

run() { # label command...
  local label="$1"
  shift
  local out stats
  out="$(mktemp)"
  stats="$(mktemp)"
  if "$gnu_time" -f '%e %M' -o "$stats" "$@" >"$out" 2>/dev/null; then
    read -r secs kb <"$stats"
    printf '%-16s %9ss %9s MB %8s\n' "$label" "$secs" "$((kb / 1024))" \
      "$(jq 'length' "$out" 2>/dev/null || echo '?')"
  else
    printf '%-16s %10s\n' "$label" FAILED
  fi
  rm -f "$out" "$stats"
}

run fix "$fix" eval --strict --json "$expr" "${args[@]}"
run lix "$lix/bin/nix-instantiate" --eval --strict --json --readonly-mode "$expr" "${args[@]}"
run nix "$cppnix/bin/nix-instantiate" --eval --strict --json --readonly-mode "$expr" "${args[@]}"
run detsys-1core "$detsys/bin/nix-instantiate" --eval --strict --json --readonly-mode "$expr" "${args[@]}"
# The new CLI has no --readonly-mode; a scratch chroot store keeps the
# logical /nix/store (identical hashing) while any .drv writes land in a
# throwaway root. `nix eval --file` does not apply --arg, so inline the call.
scratch="$(mktemp -d)"
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
call="import $expr { nixpkgs = $nixpkgs; ${subtree:+subtree = \"$subtree\";} }"
run detsys-autocore "$detsys/bin/nix" eval --json --impure --store "local?root=$scratch" --eval-cores 0 --expr "$call"
