#!/usr/bin/env bash
# Interleaved RSS-vs-wall curve across --max-memory settings.
# Usage: ab_curve.sh <workers> <rounds> <budget>...   (budget "nongc" = non-gc build, "default" = no flag)
set -uo pipefail
w="$1"; rounds="$2"; shift 2
TIME=/run/current-system/sw/bin/time
file=test/nixos_toplevel.nix

for i in $(seq 1 "$rounds"); do
  for b in "$@"; do
    if [ "$b" = "nongc" ]; then
      out=$($TIME -f "%e %M" ./zig-out-nongc/bin/fix --file "$file" --workers="$w" 2>&1 >/dev/null | tail -1)
      echo "$b $out 0"
    else
      flag=()
      [ "$b" != "default" ] && flag=(--max-memory="$b")
      err=$(mktemp)
      out=$($TIME -f "%e %M" ./zig-out/bin/fix --file "$file" --workers="$w" "${flag[@]}" 2>"$err" >/dev/null; tail -1 "$err")
      cols=$(grep -oP 'collections: \K\d+' "$err" || echo "?")
      echo "$b $out $cols"
      rm -f "$err"
    fi
  done
done
