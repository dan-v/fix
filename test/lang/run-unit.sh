#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml, tomllib' >/dev/null 2>&1; then
  exec python3 -m unittest discover -s test/lang -p 'test_*.py'
fi
exec nix-shell -p python3 python3Packages.pyyaml --run "python3 -m unittest discover -s test/lang -p 'test_*.py'"
