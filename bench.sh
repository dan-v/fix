#!/usr/bin/env bash
# Usage: bench.sh <label> [workers] [runs]
set -euo pipefail
label="${1:-run}"; workers="${2:-1}"; runs="${3:-5}"
bin=./zig-out/bin/fix
file=test/nixos_toplevel.nix
times=()
for i in $(seq 1 "$runs"); do
  start=$(date +%s.%N)
  "$bin" --file "$file" --workers="$workers" >/dev/null 2>&1
  end=$(date +%s.%N)
  times+=("$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.4f", b-a}')")
done
printf '%s\n' "${times[@]}" | sort -n | awk -v l="$label" -v w="$workers" -v n="$runs" '
  { a[NR]=$1 }
  END { printf "%-22s w=%-3s best=%.3f median=%.3f (n=%d)\n", l, w, a[1], a[int((NR+1)/2)], n }'
