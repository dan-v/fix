#!/usr/bin/env bash
# Cache-state reset for the git-fetch benchmark scenarios; standalone so
# hyperfine --prepare can invoke it between timed runs (see inside.sh).
set -euo pipefail
cache=/root/.cache
fixture="$cache/git-fixture"
if [[ "${FIX_HARNESS_FETCH_N:-9}" != 9 ]]; then fixture="$cache/git-fixture-${FIX_HARNESS_FETCH_N}"; fi
case "${1:?usage: inside-reset.sh cold|warm-store}" in
    cold)
        rm -rf /root/.cache/fix /root/.cache/nix
        xargs -r nix-store --delete <"$fixture/paths.txt" >/dev/null 2>&1 || true
        ;;
    warm-store)
        rm -rf /root/.cache/fix /root/.cache/nix
        ;;
    *) echo "unknown scenario $1" >&2; exit 2 ;;
esac
