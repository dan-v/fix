#!/usr/bin/env bash
# Full-laziness (FIX_FULL_LAZY=1) semantics: a let binding whose RHS does
# not depend on the enclosing lambda's parameters floats out of the lambda,
# so every application shares ONE thunk — observable as builtins.trace
# firing once instead of once per call. These checks lock, through the real
# CLI: the sharing itself, value identity with the gate off, laziness
# preservation (a floated throw still never fires undemanded), capture
# safety around shadowing, and per-closure (not global) sharing.
# Engine-level counterparts: the float census in let_float/planner.zig.
#   test/e2e/full_laziness.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

on_out() { FIX_FULL_LAZY=1 "$FIX" eval -E "$1" 2>/dev/null; }
on_err() { FIX_FULL_LAZY=1 "$FIX" eval -E "$1" 2>&1 1>/dev/null; }
off_out() { "$FIX" eval -E "$1" 2>/dev/null; }

# --- the transform: one evaluation shared across calls ---------------------
share='let f = x: let y = builtins.trace "eval-y" (1 + 1); in x + y; in f 1 + f 2'
t "shared float: value" "7" "$(on_out "$share")"
t "no-float baseline: value identical" "7" "$(off_out "$share")"
count=$(grep -c '^trace: eval-y$' <<<"$(on_err "$share")")
if [[ "$count" == 1 ]]; then pass "floated binding evaluates once across calls"; else
    fail "floated binding evaluates once across calls"
    echo "  got $count trace occurrences"
fi

# --- pattern lambdas float too ---------------------------------------------
pat='let f = { q }: let y = builtins.trace "py" 3; in q + y; in f { q = 1; } + f { q = 2; }'
t "pattern-lambda float: value" "9" "$(on_out "$pat")"
count=$(grep -c '^trace: py$' <<<"$(on_err "$pat")")
if [[ "$count" == 1 ]]; then pass "pattern-lambda float evaluates once"; else
    fail "pattern-lambda float evaluates once"
    echo "  got $count trace occurrences"
fi

# --- laziness preserved: creation moves, evaluation does not ---------------
t "floated throw stays undemanded" "0" \
    "$(on_out 'let f = x: let y = builtins.throw "boom"; in if x then y else 0; in f false')"

# --- sharing is PER CLOSURE: a param-dependent binding must not float ------
percall='let mk = a: x: let y = builtins.trace "cy" (a * 10); in x + y; f = mk 1; g = mk 2; in f 0 + g 0'
t "param-dependent binding: value" "30" "$(on_out "$percall")"
count=$(grep -c '^trace: cy$' <<<"$(on_err "$percall")")
if [[ "$count" == 2 ]]; then pass "param-dependent binding evaluates per closure"; else
    fail "param-dependent binding evaluates per closure"
    echo "  got $count trace occurrences (want 2: one per captured 'a')"
fi

# --- capture safety: sibling dependency chains move (or stay) together -----
webbed='let f = x: let a = "A"; b = "${a}B"; c = "${b}C"; in c + toString x; in f 1 + f 2'
t "interpolation-sibling web: value" '"ABC1ABC2"' "$(on_out "$webbed")"

# --- inverse capture: a hoisted binder must not capture with-resolved ------
# --- mentions of the same name in the newly-covered region (the esphome ----
# --- shape: an inner helper named like a package, hoisted above a ----------
# --- `with pkgs;` list that resolved the name dynamically) -----------------
cap='let f = ps: let deps = with ps; [ argA ]; helper = let argA = "s"; in argA + "x"; in { inherit deps helper; }; in (f { argA = 1; }).deps'
t "hoisted binder does not capture with-resolved mentions" "$(off_out "$cap")" "$(on_out "$cap")"

# --- values agree with the gate off across a mixed program -----------------
mixed='let g = n: let base = 100; step = base / 4; in n + step; in map g [ 1 2 3 ]'
t "mixed program: gate on == gate off" "$(off_out "$mixed")" "$(on_out "$mixed")"

e2e_finish
