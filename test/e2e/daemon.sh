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
out=$("$FIX" instantiate --store "$xp_uri" -E "$drv_expr" 2>&1)
if (($? != 0)) && [[ "$out" == *"only offers lix-xp-1"* ]]; then
    pass "daemon: XP-only endpoint fails without implementation delegation"
else
    fail "daemon: XP-only endpoint fails without implementation delegation"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

out=$("$FIX" instantiate --store auto -E "$drv_expr" 2>&1)
if (($? != 0)) && [[ "$out" == *"native local-store backend"* ]]; then
    pass "store auto: fails without implementation delegation"
else
    fail "store auto: fails without implementation delegation"
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

# The subpath analogue: reading `src + "/inner.txt"` out of a fresh ingested
# tree materializes the tree's store root.
subread_dir=$(e2e_mktemp)
mkdir -p "$subread_dir/tree"
printf 'sub-read-through-root' >"$subread_dir/tree/inner.txt"
out=$("$FIX" eval --raw --read-write-mode -E "
  let src = builtins.path { path = $subread_dir/tree; name = \"fix-daemon-e2e-subread\"; };
  in builtins.readFile (src + \"/inner.txt\")" 2>&1)
t "daemon: readFile of a fresh tree subpath materializes the root" "sub-read-through-root" "$out"
mkdir -p "$subread_dir/tree2/sub"
printf 'nested-leaf' >"$subread_dir/tree2/sub/leaf.txt"
out=$("$FIX" eval --json --read-write-mode -E "
  let src = builtins.path { path = $subread_dir/tree2; name = \"fix-daemon-e2e-subread\"; };
  in builtins.attrNames (builtins.readDir (src + \"/sub\"))" 2>&1)
t "daemon: readDir of a fresh tree subpath materializes the root" "leaf.txt" "$out"

# An absolute store URI is a Nix/Lix chroot store root. It must not silently
# delegate to an installed implementation while the native backend is pending.
local_root=$(e2e_mktemp)
out=$("$FIX" instantiate --store "$local_root" -E "$drv_expr" 2>&1)
if (($? != 0)) && [[ "$out" == *"native local-store backend"* ]]; then
    pass "local store: fails without implementation delegation"
else
    fail "local store: fails without implementation delegation"
    echo "  got: $(printf '%q' "$out")" | head -c 2000
    echo
fi

e2e_finish
