#!/usr/bin/env bash
# Differential nixpkgs-universe eval: fix vs a reference Nix, compared per-attr
# by drvPath (see outpaths.nix for the universe and comparison rationale).
#
#   test/nixpkgs/run.sh                          # monolithic full universe
#   test/nixpkgs/run.sh --chunk 3/12             # slice 3 of 12 (CI matrix)
#   test/nixpkgs/run.sh --subtree haskellPackages
#   test/nixpkgs/run.sh --workers N --gc-budget MIB --fix PATH
#
# The full universe peaks around 51 GB under fix with default settings; on
# memory-constrained machines use --chunk together with --gc-budget (a
# 2500-name chunk at --gc-budget 1024 peaks under 10 GB).
#
# Oracle results are cached under $FIX_NIXPKGS_EVAL_CACHE (default
# ~/.cache/fix-nixpkgs-eval) keyed on the pinned nixpkgs store path and the
# hermetic-evaluation schema, so either kind of change invalidates them.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fix="$repo/zig-out/bin/fix"
subtree=""
chunk=""
workers=""
gc_budget=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subtree) subtree="$2"; shift 2 ;;
    --chunk) chunk="$2"; shift 2 ;;
    --workers) workers="$2"; shift 2 ;;
    --gc-budget) gc_budget="$2"; shift 2 ;;
    --fix) fix="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$subtree" && -n "$chunk" ]]; then
  echo "--subtree and --chunk are mutually exclusive" >&2
  exit 2
fi
[[ -x "$fix" ]] || { echo "fix binary not found at $fix (build with \`zig build\`)" >&2; exit 2; }

# nixpkgs' drbd expression includes builtins.getEnv "SHELL" in its derivation.
# Pin the ambient input so an oracle made from one login shell remains valid
# when the comparison is later run from another.
export SHELL=/bin/sh
oracle_schema="env-v1"

# Materialize the npins nixpkgs pin (same expression as test/lang's resolvePin).
nixpkgs="$(nix-build --no-out-link --expr "
  let pkgs = import <nixpkgs> {};
      source = (import $repo/npins).nixpkgs;
  in pkgs.runCommand \"fix-lang-nixpkgs\" {} \"cp -R \${source}/. \$out\"")"

cache_dir="${FIX_NIXPKGS_EVAL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/fix-nixpkgs-eval}"
mkdir -p "$cache_dir"
pin="$(basename "$nixpkgs")"

args=(--arg nixpkgs "$nixpkgs")
key="full"
if [[ -n "$subtree" ]]; then
  args+=(--argstr subtree "$subtree")
  key="$subtree"
elif [[ -n "$chunk" ]]; then
  i="${chunk%%/*}"
  n="${chunk##*/}"
  [[ "$i" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ && "$i" -lt "$n" ]] || {
    echo "--chunk wants I/N with 0 <= I < N, got '$chunk'" >&2; exit 2; }

  # The sorted top-level name list defines the chunk boundaries; cached per
  # pin so every chunk of one run slices the same universe.
  names="$cache_dir/$pin-names.json"
  if [[ ! -s "$names" ]]; then
    echo ">> enumerating top-level attr names (cached to $names)" >&2
    nix-instantiate --eval --strict --json --readonly-mode -E "
      builtins.attrNames (import ($nixpkgs + \"/ci/eval/outpaths.nix\") {
        path = $nixpkgs; systems = [ \"x86_64-linux\" ];
      })" >"$names.tmp"
    mv "$names.tmp" "$names"
  fi
  slice="$cache_dir/$pin-chunk-$i-of-$n.names.json"
  jq -c --argjson i "$i" --argjson n "$n" \
    '((length + $n - 1) / $n | floor) as $size | .[$i * $size : ($i + 1) * $size]' \
    "$names" >"$slice"
  args+=(--arg only "builtins.fromJSON (builtins.readFile $slice)")
  key="chunk-$i-of-$n"
fi

oracle="$cache_dir/$pin-$oracle_schema-$key.json"
if [[ ! -s "$oracle" ]]; then
  echo ">> oracle eval (nix-instantiate, cached to $oracle)" >&2
  nix-instantiate --eval --strict --json --readonly-mode \
    "$repo/test/nixpkgs/outpaths.nix" "${args[@]}" >"$oracle.tmp"
  mv "$oracle.tmp" "$oracle"
else
  echo ">> oracle cached: $oracle" >&2
fi

fix_args=()
[[ -n "$workers" ]] && fix_args+=(--workers "$workers")
[[ -n "$gc_budget" ]] && fix_args+=(--gc-budget "$gc_budget")
out="$cache_dir/fix-$key.json"
echo ">> fix eval ($key)" >&2
"$fix" eval --strict --json "${fix_args[@]}" \
  "$repo/test/nixpkgs/outpaths.nix" "${args[@]}" >"$out"

"$repo/test/nixpkgs/compare.sh" "$oracle" "$out"
