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
harness="$(nix-build --no-out-link "$repo/default.nix" -A "$attribute")"
exec "$harness/bin/fix-bench" "$@"
