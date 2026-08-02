#!/usr/bin/env bash
# Recursive derivation diff: given two .drv store paths that should be
# equivalent, follow the first divergent input-drv pair (matched by drv name)
# down to a derivation whose inputs all agree — the root divergence — and
# print its diff. Works on the ATerm bytes directly, so it needs no Nix
# commands and reports inputs present on only one side (which name-pairing
# alone would miss). Both drvs must be in the local store.
#
#   tools/drv-diff.sh <a.drv> <b.drv>
set -euo pipefail

a="$1"
b="$2"
depth=0

drvname() { basename "$1" | cut -d- -f2-; }

# Referenced .drv paths (any occurrence in the ATerm), excluding the file's
# own path, as "name<TAB>path" lines sorted by name.
refs() {
  local drv="$1"
  grep -oE '/nix/store/[a-z0-9]{32}-[^"!,)]+\.drv' "$drv" | sort -u |
    while read -r p; do
      [[ "$p" == "$drv" ]] && continue
      printf '%s\t%s\n' "$(drvname "$p")" "$p"
    done | sort
}

while true; do
  if [[ "$a" == "$b" ]]; then
    echo "identical at depth $depth: $a"
    exit 0
  fi
  echo "[$depth] $(drvname "$a")"
  refs "$a" >/tmp/drv-diff-a.$$
  refs "$b" >/tmp/drv-diff-b.$$

  only_a=$(comm -23 <(cut -f1 /tmp/drv-diff-a.$$) <(cut -f1 /tmp/drv-diff-b.$$) | head -5)
  only_b=$(comm -13 <(cut -f1 /tmp/drv-diff-a.$$) <(cut -f1 /tmp/drv-diff-b.$$) | head -5)
  [[ -n "$only_a" ]] && printf 'inputs only in %s:\n%s\n' "$a" "$only_a"
  [[ -n "$only_b" ]] && printf 'inputs only in %s:\n%s\n' "$b" "$only_b"

  pair=$(join -t $'\t' /tmp/drv-diff-a.$$ /tmp/drv-diff-b.$$ |
    awk -F'\t' '$2 != $3 { print $2 " " $3; exit }')
  rm -f /tmp/drv-diff-a.$$ /tmp/drv-diff-b.$$

  if [[ -z "$pair" ]]; then
    echo "=== root divergence: $(drvname "$a") ==="
    echo "--- $a"
    echo "+++ $b"
    # Comma-split the ATerms so the diff lands on individual fields.
    diff <(tr ',' '\n' <"$a") <(tr ',' '\n' <"$b") || true
    exit 1
  fi

  a=${pair%% *}
  b=${pair##* }
  depth=$((depth + 1))
done
