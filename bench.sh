#!/usr/bin/env bash
# Source-tree convenience wrapper for the Nix-contained benchmark harness.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$(nix-build --no-out-link "$repo/default.nix" -A bench)"
exec "$harness/bin/fix-bench" "$@"
