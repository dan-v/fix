#!/usr/bin/env bash
# GC validation: output digest, collection report, and wall time.
# Usage: gc_validate.sh <bin> [workers]
set -uo pipefail
bin="${1:-./zig-out/bin/fix}"
workers="${2:-1}"
file=test/nixos_toplevel.nix
golden=42da4061f3a0bc74975d023290df880ccb96d528fadfabb98fa2ee865baefe15

out=$(mktemp); err=$(mktemp)
start=$(date +%s.%N)
"$bin" eval --file "$file" --workers="$workers" >"$out" 2>"$err"
code=$?
end=$(date +%s.%N)
got=$(sha256sum "$out" | cut -d' ' -f1)
wall=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", b-a}')

if [ "$got" = "$golden" ]; then ok="BYTE-IDENTICAL ✓"; else ok="MISMATCH ✗ ($got)"; fi
echo "w=$workers exit=$code wall=${wall}s  $ok"
# GC report (peak RSS / collections), if present on stderr
grep -E "collections:|peak RSS|current RSS|live after|peak reserved|mark time" "$err" 2>/dev/null | sed 's/^/    /'
rm -f "$out" "$err"
