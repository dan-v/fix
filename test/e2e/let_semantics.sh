#!/usr/bin/env bash
# End-to-end characterization checks for `let` laziness/sharing/error-ordering
# semantics, driven through the real `fix eval` CLI (stdout AND stderr) so
# they lock the user-visible contract, not just the in-process Engine API.
# These are guardrails for an upcoming let-optimization pass — see the
# engine-level counterparts in src/expr/compiler/tests/compiler_lowering.zig.
#   test/e2e/let_semantics.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

# eval_out <expr>: stdout of `fix eval -E <expr>` (stderr discarded).
eval_out() { "$FIX" eval -E "$1" 2>/dev/null; }
# eval_err <expr>: stderr of `fix eval -E <expr>` (stdout discarded).
eval_err() { "$FIX" eval -E "$1" 2>&1 1>/dev/null; }

# --- non-strict rendering: Nix parity for a sunk single-use binding --------
# Let-float sinks the single-use `x` into the list element, which compiles
# as a genuine unforced element thunk — rendering `<CODE>` exactly like Nix
# (`nix-instantiate --eval` prints `[ <CODE> ]` for this expression; fix
# printed `[ 2 ]` before the rewrite because the binding slot held a folded
# constant).
out=$(eval_out 'let x = 1 + 1; in [ x ]')
t "non-strict list rendering matches Nix (<CODE> element)" "[ <CODE> ]" "$out"

# --- sharing: builtins.trace fires exactly once for a doubly-referenced ----
# --- let binding, observed on stderr as the real CLI prints it -------------
out=$(eval_out 'let x = builtins.trace "eval-x" (1 + 1); in x + x')
err=$(eval_err 'let x = builtins.trace "eval-x" (1 + 1); in x + x')
t "shared let binding: value" "4" "$out"
t "shared let binding: trace fires" "trace: eval-x" "$err"
count=$(grep -c '^trace: eval-x$' <<<"$err")
if [[ "$count" == 1 ]]; then pass "shared let binding: trace fires exactly once"; else
    fail "shared let binding: trace fires exactly once"
    echo "  got $count occurrences in: $(printf '%q' "$err")"
fi

# --- sharing across closure calls: captured (not re-evaluated) per call ----
out=$(eval_out 'let x = builtins.trace "once" 5; f = y: x + y; in f 1 + f 2')
err=$(eval_err 'let x = builtins.trace "once" 5; f = y: x + y; in f 1 + f 2')
t "closure-captured let binding: value" "13" "$out"
count=$(grep -c '^trace: once$' <<<"$err")
if [[ "$count" == 1 ]]; then pass "closure-captured let binding: trace fires exactly once"; else
    fail "closure-captured let binding: trace fires exactly once"
    echo "  got $count occurrences in: $(printf '%q' "$err")"
fi

# --- laziness: an unused, erroring let binding never runs ------------------
out=$(eval_out 'let x = builtins.throw "boom"; in 42')
code=$?
t "unused erroring let binding: value" "42" "$out"
ok_if "unused erroring let binding: exits zero" [ "$code" -eq 0 ]

# --- error ordering under tryEval: eager throw beats a lazy division error -
out=$(eval_out 'let x = 1 / 0; in builtins.tryEval ((builtins.throw "t") + x)')
t "tryEval error ordering: success is false" "success = false" "$out"
t_absent "tryEval error ordering: no division-by-zero abort" "division" "$out"

e2e_finish
