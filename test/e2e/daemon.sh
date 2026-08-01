#!/usr/bin/env bash
# End-to-end checks against a real CppNix or Lix daemon.
# Set FIX_REQUIRE_DAEMON=1 in compatibility CI so connection failures cannot
# turn into skips; ordinary local runs remain useful without a running daemon.
#   test/e2e/daemon.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

drv_expr='builtins.derivation {
  name = "fix-daemon-e2e";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "printf daemon-compatible > \"$out\"" ];
}'

# This simultaneously probes the connection, exercises nix.conf comment
# parsing, and verifies that the user-level store setting reaches setup.
out=$(env NIX_CONFIG='store = daemon # use the local compatibility socket' \
    "$FIX" instantiate -E "$drv_expr" 2>&1)
code=$?
if ((code != 0)); then
    if [[ "${FIX_REQUIRE_DAEMON:-0}" == 1 ]]; then
        fail "daemon: required connection"
        echo "  got: $(printf '%q' "$out")" | head -c 2000
        echo
    else
        skip "daemon compatibility" "no reachable daemon"
    fi
    e2e_finish
fi
t "daemon: instantiate through commented store setting" "/nix/store/" "$out"

out=$("$FIX" build --no-out-link -E "$drv_expr" 2>&1)
code=$?
if ((code == 0)); then
    pass "daemon: realize derivation"
else
    fail "daemon: realize derivation"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi
t "daemon: reports realized store path" "/nix/store/" "$out"

# readFile demands the path immediately. This catches the fresh-process case
# where toFile has a pending text recipe but the path does not exist yet.
out=$("$FIX" eval --raw --read-write-mode -E \
    'builtins.readFile (builtins.toFile "fix-daemon-e2e-text" "text-via-daemon")' 2>&1)
code=$?
if ((code == 0)); then
    pass "daemon: realize toFile before readFile"
else
    fail "daemon: realize toFile before readFile"
fi
t "daemon: read fresh text object" "text-via-daemon" "$out"

e2e_finish
