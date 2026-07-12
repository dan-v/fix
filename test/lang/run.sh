#!/usr/bin/env bash
# Wrapper for the Lix/snix language conformance runner. Ensures a python3 is
# available (falling back to `nix-shell -p python3`, since resolving the npins
# pins already needs Nix) and forwards all arguments to run.py.
#
#   test/lang/run.sh                 # run both suites against zig-out/bin/fix
#   test/lang/run.sh --suite lix -v  # one suite, with diffs
#   test/lang/run.sh --show-skips    # also list cases the harness can't drive
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
  exec python3 "$here/run.py" "$@"
fi

# No python3 on PATH — borrow one from Nix. Quote each argument for the -c form.
quoted=""
for arg in "$@"; do quoted+=" $(printf '%q' "$arg")"; done
exec nix-shell -p python3 --run "python3 $(printf '%q' "$here/run.py")$quoted"
