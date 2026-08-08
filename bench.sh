#!/usr/bin/env bash
# Source-tree convenience wrapper for the Nix-contained benchmark harness.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
attribute=bench
if [[ -n "${TOOLS:-}" ]]; then
  fix_only=1
  IFS=',' read -r -a selectors <<< "$TOOLS"
  for selector in "${selectors[@]}"; do
    selector="${selector#-}"
    case "$selector" in
      fix|fix-*) ;;
      *) fix_only=0 ;;
    esac
  done
  if [[ "$fix_only" -eq 1 ]]; then
    attribute=benchFix
  fi
fi
commit="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ "$commit" != unknown ]] && ! git -C "$repo" diff --quiet HEAD 2>/dev/null; then
  commit="$commit-dirty"
fi
export FIX_BENCH_COMMIT="$commit"

harness="$(nix-build --no-out-link "$repo/default.nix" -A "$attribute")"
exec "$harness/bin/fix-bench" "$@"
