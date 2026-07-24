#!/usr/bin/env bash
# End-to-end checks for `fix flake` (metadata, show, check, lock, update).
# Run from the repo root with the fix binary as $1 (default zig-out/bin/fix).
# NOTE: runs the binary — hold the perf compute lock when invoking.
set -u
FIX=${1:-zig-out/bin/fix}
FF="--extra-experimental-features flakes --impure"
fails=0
t() { # t <name> <expected-substring> <actual>
    local name="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        echo "  wanted substring: $(printf '%q' "$want")"
        echo "  got: $(printf '%q' "$got")" | head -c 2000
        echo
        fails=$((fails + 1))
    fi
}

sub=$(mktemp -d)
root=$(mktemp -d)
trap 'rm -rf "$sub" "$root"' EXIT
cat > "$sub/flake.nix" <<'EOF'
{ outputs = { self, ... }: { v = 1; }; }
EOF
cat > "$root/flake.nix" <<EOF
{
  description = "root flake";
  inputs.sub.url = "path:$sub";
  outputs = { self, sub, ... }: {
    packages.x86_64-linux.default = derivation { name = "d"; system = "x86_64-linux"; builder = "/bin/sh"; };
    packages.x86_64-linux.hello = derivation { name = "h"; system = "x86_64-linux"; builder = "/bin/sh"; };
    packages.x86_64-linux.broken = throw "boom";
    apps.x86_64-linux.default = { type = "app"; program = "/bin/true"; };
    devShells.x86_64-linux.default = derivation { name = "s"; system = "x86_64-linux"; builder = "/bin/sh"; };
  };
}
EOF

# --- metadata ---------------------------------------------------------------
out=$($FIX flake metadata $FF "$root" 2>&1)
t "metadata: description" "root flake" "$out"
t "metadata: input listed" "sub" "$out"
t "metadata: self filtered out" "└───sub" "$out"

# --- show -------------------------------------------------------------------
out=$($FIX flake show $FF "$root" 2>&1)
t "show: packages tree" "packages" "$out"
t "show: leaf label" "hello: package" "$out"
t "show: app leaf" "default: app" "$out"
t "show: devshell leaf" "development environment" "$out"

# --- check (the broken output must fail) ------------------------------------
out=$($FIX flake check $FF "$root" 2>&1)
code=$?
t "check: reports failure" "FAIL packages.x86_64-linux.broken" "$out"
if [[ $code -ne 0 ]]; then echo "ok   check: nonzero exit on failure"; else echo "FAIL check: exit was 0"; fails=$((fails+1)); fi

# --- lock (creates flake.lock) ----------------------------------------------
rm -f "$root/flake.lock"
out=$($FIX flake lock $FF "$root" 2>&1)
t "lock: reports written" "wrote lock file" "$out"
if [[ -f "$root/flake.lock" ]]; then echo "ok   lock: flake.lock exists"; else echo "FAIL lock: no flake.lock"; fails=$((fails+1)); fi

# --- update (re-pins; preserves a valid lock on success) --------------------
out=$($FIX flake update $FF "$root" 2>&1)
t "update: reports updated" "updated lock file" "$out"
if [[ -f "$root/flake.lock" ]]; then echo "ok   update: flake.lock present"; else echo "FAIL update: lost flake.lock"; fails=$((fails+1)); fi

# --- errors -----------------------------------------------------------------
out=$($FIX flake bogus 2>&1)
t "unknown subcommand" "unknown flake subcommand 'bogus'" "$out"
out=$($FIX flake metadata github:NixOS/nonesuch --extra-experimental-features flakes 2>&1 || true)
# update/lock on a remote ref is rejected as non-local.
out=$($FIX flake update $FF github:owner/repo 2>&1 || true)
t "update: rejects remote ref" "needs a local flake" "$out"

echo
if [[ $fails -eq 0 ]]; then echo "all flake e2e checks passed"; else echo "$fails flake e2e check(s) failed"; fi
exit $((fails > 0))
