#!/usr/bin/env bash
# Enforce the durable source boundaries documented in docs/architecture.md.
set -euo pipefail

repo=${1:-.}
src="$repo/src"
failed=0

while IFS= read -r file; do
  name=${file##*/}
  case "$name" in
    main.zig|process_support.zig) ;;
    *)
      echo "structure-check: unexpected Zig file in src root: $file" >&2
      failed=1
      ;;
  esac
done < <(find "$src" -maxdepth 1 -type f -name '*.zig' | sort)

for domain in base syntax runtime store fetchers expr cli; do
  root="$src/$domain/root.zig"
  if [[ ! -f "$root" ]]; then
    echo "structure-check: durable module has no root.zig: $src/$domain" >&2
    failed=1
  fi
done

while IFS= read -r file; do
  echo "structure-check: catch-all module name is forbidden: $file" >&2
  failed=1
done < <(find "$src" -type f \( -name 'util.zig' -o -name 'common.zig' -o -name 'helpers.zig' \) | sort)

if rg -n '(^|[[:space:]])owned:[[:space:]]*bool([,;[:space:]]|$)' "$src"; then
  echo "structure-check: represent borrowed/owned data with a tagged union" >&2
  failed=1
fi

if rg -n '\bEvaluator\b' "$src"; then
  echo "structure-check: use the responsibility-oriented Engine API; no legacy Evaluator alias" >&2
  failed=1
fi

if rg -n '@import\("(\.\./)+(base|syntax|runtime|store|fetchers|expr|cli)(/|\.zig")' "$src"; then
  echo "structure-check: import durable modules by name instead of crossing roots relatively" >&2
  failed=1
fi

for subsystem in pages source_view view_state tree_projection controller preview value_summary tree_render debug_view; do
  file="$src/cli/repl/vm/$subsystem.zig"
  if rg -n "Explorer\\.Ops\\.$subsystem\\." "$file"; then
    echo "structure-check: VM explorer subsystems call their own helpers directly" >&2
    failed=1
  fi
done
exit "$failed"
