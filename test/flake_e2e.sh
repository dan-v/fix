#!/usr/bin/env bash
# End-to-end checks for `fix flake` (metadata, show, check, lock, update).
# Run from the repo root with the fix binary as $1 (default zig-out/bin/fix).
# NOTE: runs the binary — hold the perf compute lock when invoking.
set -u
FIX=${1:-zig-out/bin/fix}
# Absolute so `cd`-ing into a temp flake dir (for update/lock) still finds it.
FIX=$(cd "$(dirname "$FIX")" && pwd)/$(basename "$FIX")
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

# --- lock / update operate on the cwd flake; positionals are input names ----
# Fresh two-input root so partial updates are observable.
a=$(mktemp -d); b=$(mktemp -d); r2=$(mktemp -d)
trap 'rm -rf "$sub" "$root" "$a" "$b" "$r2"' EXIT
echo '{ outputs = i: { v = 1; }; }' > "$a/flake.nix"
echo '{ outputs = i: { v = 2; }; }' > "$b/flake.nix"
cat > "$r2/flake.nix" <<EOF
{ inputs.a.url = "path:$a"; inputs.b.url = "path:$b"; outputs = i: { x = 1; }; }
EOF
hashes() { grep -o '"narHash":"[^"]*"' "$r2/flake.lock" | tr '\n' ' '; }
anode() { grep -A3 "\"$1\":" "$r2/flake.lock" | grep -o '"narHash":"[^"]*"' | head -1; }

out=$(cd "$r2" && $FIX flake lock $FF 2>&1)
t "lock: reports written" "wrote flake.lock" "$out"
if [[ -f "$r2/flake.lock" ]]; then echo "ok   lock: flake.lock exists"; else echo "FAIL lock: no flake.lock"; fails=$((fails+1)); fi
a0=$(anode a); b0=$(anode b)

# Change input a, then update ONLY a: a re-pins, b stays.
echo '{ outputs = i: { v = 999; }; }' > "$a/flake.nix"
out=$(cd "$r2" && $FIX flake update a $FF 2>&1)
t "update a: reports updated" "updated flake.lock" "$out"
a1=$(anode a); b1=$(anode b)
if [[ "$a0" != "$a1" ]]; then echo "ok   update a: a re-pinned"; else echo "FAIL update a: a unchanged"; fails=$((fails+1)); fi
if [[ "$b0" == "$b1" ]]; then echo "ok   update a: b left frozen"; else echo "FAIL update a: b changed"; fails=$((fails+1)); fi

# update (no args) re-pins everything.
echo '{ outputs = i: { v = 3; }; }' > "$b/flake.nix"
out=$(cd "$r2" && $FIX flake update $FF 2>&1)
b2=$(anode b)
if [[ "$b1" != "$b2" ]]; then echo "ok   update (all): b re-pinned"; else echo "FAIL update (all): b unchanged"; fails=$((fails+1)); fi

# lock completes a missing input without touching existing pins.
a2=$(anode a); b3=$(anode b)
cat > "$r2/flake.nix" <<EOF
{ inputs.a.url = "path:$a"; inputs.b.url = "path:$b"; inputs.c.url = "path:$sub"; outputs = i: { x = 1; }; }
EOF
out=$(cd "$r2" && $FIX flake lock $FF 2>&1)
if grep -q '"c":' "$r2/flake.lock"; then echo "ok   lock: added new input c"; else echo "FAIL lock: c not added"; fails=$((fails+1)); fi
if [[ "$a2" == "$(anode a)" && "$b3" == "$(anode b)" ]]; then echo "ok   lock: existing pins untouched"; else echo "FAIL lock: existing pins changed"; fails=$((fails+1)); fi

# --- errors -----------------------------------------------------------------
out=$($FIX flake bogus 2>&1)
t "unknown subcommand" "unknown flake subcommand 'bogus'" "$out"

echo
if [[ $fails -eq 0 ]]; then echo "all flake e2e checks passed"; else echo "$fails flake e2e check(s) failed"; fi
exit $((fails > 0))
