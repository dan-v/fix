#!/usr/bin/env bash
# Recursive derivation diff: given two .drv store paths that should be
# equivalent, follow the first divergent input-drv pair (matched by drv name)
# down to a derivation whose inputs all agree — the root divergence — and
# print its env/args/outputs diff. Both drvs must be in the local store.
#
#   tools/drv-diff.sh <a.drv> <b.drv>
set -euo pipefail

a="$1"
b="$2"
depth=0

drvname() { basename "$1" | cut -d- -f2-; }

while true; do
  if [[ "$a" == "$b" ]]; then
    echo "identical at depth $depth: $a"
    exit 0
  fi
  echo "[$depth] $(drvname "$a")"
  ja=$(nix derivation show "$a^*" | jq '.[]')
  jb=$(nix derivation show "$b^*" | jq '.[]')

  # Pair input drvs by name; emit "a b" for the first pair whose hashes differ.
  pair=$(jq -n --argjson a "$ja" --argjson b "$jb" -r '
    def byname: .inputDrvs | keys | map({key: (sub(".*/[a-z0-9]{32}-"; "")), value: .}) | from_entries;
    ($a | byname) as $na | ($b | byname) as $nb |
    [ ($na | keys[]) | select($nb[.] != null and $na[.] != $nb[.]) ] | sort | .[0] as $k |
    if $k == null then empty else "\($na[$k]) \($nb[$k])" end
  ')

  if [[ -z "$pair" ]]; then
    echo "=== root divergence: $(drvname "$a") ==="
    echo "--- $a"
    echo "+++ $b"
    diff <(jq -S 'del(.inputDrvs, .inputSrcs)' <<<"$ja") <(jq -S 'del(.inputDrvs, .inputSrcs)' <<<"$jb") || true
    exit 1
  fi

  a=${pair%% *}
  b=${pair##* }
  depth=$((depth + 1))
done
