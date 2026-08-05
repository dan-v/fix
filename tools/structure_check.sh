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

# ObjectHeap's stores are collector implementation details. Expression and CLI
# code consume counts, snapshots, and semantic accessors instead of coupling to
# the segmented backing layout.
if rg -n '\bheap\.(objects|values|attrs|attr_positions|bytes)\b' \
  "$src/expr" "$src/cli" "$src/store" "$src/fetchers"; then
  echo "structure-check: use ObjectHeap APIs outside the runtime heap implementation" >&2
  failed=1
fi

# Foundational compiler stages must not import the attrset lowering stage just
# to decode names or report diagnostics; attr_names.zig owns that leaf concern.
if rg -n '@import\("attrs\.zig"\)' \
  "$src/expr/compiler/diagnostics.zig" \
  "$src/expr/compiler/emit.zig" \
  "$src/expr/compiler/access.zig" \
  "$src/expr/compiler/fold.zig" \
  "$src/expr/compiler/lambda.zig" \
  "$src/expr/compiler/literals.zig"; then
  echo "structure-check: compiler leaf stages must not depend on attrset lowering" >&2
  failed=1
fi

if [[ -e "$src/expr/engine/capabilities.zig" ]]; then
  echo "structure-check: do not restore forwarding-only Engine capability views" >&2
  failed=1
fi

exit "$failed"
