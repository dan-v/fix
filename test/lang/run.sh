#!/usr/bin/env bash
# Wrapper for the Lix/snix language conformance runner. Ensures a python3 with
# pyyaml is available (falling back to `nix-shell`, since resolving the npins
# pins already needs Nix) and forwards all arguments to run.py. pyyaml is used to
# normalize `fix parse --json` output the way the Lix lang-runner does.
#
#   test/lang/run.sh                 # run both suites against zig-out/bin/fix
#   test/lang/run.sh --suite lix -v  # one suite, with diffs
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  exec python3 "$here/run.py" "$@"
fi

# No suitable python3 on PATH — borrow one from Nix. Quote each argument.
quoted=""
for arg in "$@"; do quoted+=" $(printf '%q' "$arg")"; done
exec nix-shell -p python3 python3Packages.pyyaml \
  --run "python3 $(printf '%q' "$here/run.py")$quoted"
