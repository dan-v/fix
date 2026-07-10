#!/usr/bin/env bash
# Interleaved A/B/C of dormant GC cost: non-gc build vs -Dgc (default budget,
# 0 collections) vs -Dgc with FIX_GC_OFF (reclaim machinery never enabled).
# Usage: ab_dormant.sh <workers> <rounds>
set -uo pipefail
w="${1:-1}"
rounds="${2:-8}"
TIME=/run/current-system/sw/bin/time
file=test/nixos_toplevel.nix

run() { # name env... -- bin
  local name="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local bin="$1"
  local out
  out=$(env "${envs[@]}" $TIME -f "%e %M" "$bin" eval --file "$file" --workers="$w" 2>&1 >/dev/null | tail -1)
  echo "$name $out"
}

for i in $(seq 1 "$rounds"); do
  run nongc      X=1 -- ./zig-out-nongc/bin/fix
  run gc-default X=1 -- ./zig-out/bin/fix
  run gc-off     FIX_GC_OFF=1 -- ./zig-out/bin/fix
done
