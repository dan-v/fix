#!/usr/bin/env bash
set -euo pipefail

repo=${1:-.}
model_dir="$repo/model"
meta_root=$(mktemp -d "${TMPDIR:-/tmp}/fix-tlc.XXXXXX")
trap 'rm -rf "$meta_root"' EXIT

for spec in FutureWait FiberDispatch Shutdown GcBarrier; do
  echo "TLC $spec"
  tlc \
    -workers 1 \
    -deadlock \
    -cleanup \
    -metadir "$meta_root/$spec" \
    -config "$model_dir/$spec.cfg" \
    "$model_dir/$spec.tla"
done

expect_mutation_rejected() {
  local spec=$1
  local marker=$2
  local expression=$3
  local mutation_dir="$meta_root/mutation-$spec"
  mkdir -p "$mutation_dir"
  cp "$model_dir/$spec.tla" "$model_dir/$spec.cfg" "$mutation_dir/"
  awk -v marker="$marker" -v expression="$expression" \
    'index($0, marker) { printf "    /%c %s %c* %s\n", 92, expression, 92, marker; next } { print }' \
    "$mutation_dir/$spec.tla" >"$mutation_dir/$spec.next"
  mv "$mutation_dir/$spec.next" "$mutation_dir/$spec.tla"
  if tlc -workers 1 -deadlock -cleanup \
      -metadir "$mutation_dir/states" \
      -config "$mutation_dir/$spec.cfg" \
      "$mutation_dir/$spec.tla" >"$mutation_dir/output" 2>&1; then
    echo "TLC mutation unexpectedly survived: $spec" >&2
    return 1
  fi
  if ! rg -q 'Invariant .* is violated|Temporal properties were violated' "$mutation_dir/output"; then
    echo "TLC mutation was invalid instead of violating a property: $spec" >&2
    cat "$mutation_dir/output" >&2
    return 1
  fi
  echo "TLC mutation rejected: $spec"
}

# Prove the models are discriminating rather than tautological: remove three
# load-bearing guards and require TLC to produce a counterexample for each.
expect_mutation_rejected FutureWait \
  'MUTATION_ENROLL_RECHECK' \
  'TRUE'
expect_mutation_rejected Shutdown \
  'MUTATION_EXTERNAL_DRAIN' \
  'TRUE'
expect_mutation_rejected GcBarrier \
  'MUTATION_RELEASE_PHASE' \
  'phase'"'"' = "idle"'
