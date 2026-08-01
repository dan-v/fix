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

# Lix's `protocol=any` URI treats the path as a socket directory. fix selects
# the legacy socket within it, which also works against a CppNix daemon.
daemon_base="${NIX_STATE_DIR:-/nix/var/nix}/daemon-socket"
out=$("$FIX" instantiate --store "unix://${daemon_base}?protocol=any" -E "$drv_expr" 2>&1)
code=$?
if ((code == 0)); then
    pass "daemon: Lix protocol=any legacy fallback"
else
    fail "daemon: Lix protocol=any legacy fallback"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

xp_uri="unix://${daemon_base}?protocol=lix-xp-1"
if command -v nix >/dev/null 2>&1 && nix store ping --store "$xp_uri" >/dev/null 2>&1; then
    out=$("$FIX" instantiate --store "$xp_uri" -E "$drv_expr" 2>&1)
    if (($? == 0)); then
        pass "daemon: Lix XP endpoint through stdio bridge"
    else
        fail "daemon: Lix XP endpoint through stdio bridge"
        echo "  got: $(printf '%q' "$out")" | head -c 2000
        echo
    fi
else
    skip "daemon: Lix XP endpoint bridge" "endpoint not exposed"
fi

out=$("$FIX" instantiate --store auto -E "$drv_expr" 2>&1)
if (($? == 0)); then
    pass "store auto: installed implementation selects backend"
else
    fail "store auto: installed implementation selects backend"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

custom_state=$(e2e_mktemp)
mkdir -p "$custom_state/daemon-socket"
ln -s "$daemon_base/socket" "$custom_state/daemon-socket/socket"
out=$(env NIX_STATE_DIR="$custom_state" "$FIX" instantiate -E "$drv_expr" 2>&1)
if (($? == 0)); then
    pass "daemon: NIX_STATE_DIR selects socket"
else
    fail "daemon: NIX_STATE_DIR selects socket"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

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

# An absolute store URI is a Nix/Lix chroot store root. fix serves it through
# the installed nix-daemon's stdio worker endpoint, without a persistent daemon.
local_root=$(e2e_mktemp)
local_expr='builtins.derivation {
  name = "fix-local-e2e";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "printf local-compatible > \"$out\"" ];
}'
out=$("$FIX" build --no-out-link --store "$local_root" -E "$local_expr" 2>&1)
code=$?
logical=$(printf '%s\n' "$out" | grep '^/nix/store/' | tail -1)
if ((code == 0)); then
    pass "local store: realize through stdio helper"
else
    fail "local store: realize through stdio helper"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi
if [[ -n "$logical" && -f "$local_root$logical" && "$(<"$local_root$logical")" == local-compatible ]]; then
    pass "local store: physical chroot output"
else
    fail "local store: physical chroot output"
fi

e2e_finish
