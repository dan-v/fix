#!/usr/bin/env bash
# Drive every `fix` end-to-end suite (test/e2e/*.sh) against one binary and
# aggregate the results. Adding a suite is just dropping a new fragment here;
# `zig build test-e2e` (and, transitively, `zig build test`) picks it up.
#
#   test/e2e/run.sh                         # all suites vs zig-out/bin/fix
#   test/e2e/run.sh --fix ./path/to/fix     # all suites vs a chosen binary
#   test/e2e/run.sh repl                     # only the repl suite
#   test/e2e/run.sh --fix ./fix flake repl   # a subset, explicit binary
#
# NOTE: runs the fix binary; hold the perf compute lock when invoking.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fix="zig-out/bin/fix"
names=()
while (($#)); do
    case "$1" in
    --fix)
        fix="$2"
        shift 2
        ;;
    --fix=*)
        fix="${1#--fix=}"
        shift
        ;;
    -h | --help)
        sed -n '2,12p' "$0"
        exit 0
        ;;
    *)
        names+=("$1")
        shift
        ;;
    esac
done

# Default to every fragment except this driver and the sourced library.
if ((${#names[@]} == 0)); then
    for f in "$here"/*.sh; do
        base="$(basename "$f" .sh)"
        [[ "$base" == "run" || "$base" == "lib" ]] && continue
        names+=("$base")
    done
fi

failed_suites=()
total_pass=0
total_fail=0
total_skip=0
suite_log="$(mktemp)"
trap 'rm -f "$suite_log"' EXIT
suite_timeout="${E2E_SUITE_TIMEOUT:-5m}"

run_suite() {
    local frag="$1" fix="$2"
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=5s "$suite_timeout" bash "$frag" "$fix"
    else
        bash "$frag" "$fix"
    fi
}

for name in "${names[@]}"; do
    frag="$here/$name.sh"
    if [[ ! -f "$frag" ]]; then
        echo "run.sh: no such suite '$name' ($frag)" >&2
        failed_suites+=("$name")
        continue
    fi
    echo "=== e2e: $name ==="
    : >"$suite_log"
    (
        elapsed=0
        while sleep 30; do
            elapsed=$((elapsed + 30))
            echo
            echo "=== e2e: $name still running after ${elapsed}s ==="
            ps -Ao pid,ppid,etime,state,command 2>/dev/null |
                awk 'NR == 1 || /(^|[/ ])fix( |$)/ || /fix repl/ || index($0, "test/e2e") || /script -q/'
        done
    ) &
    heartbeat_pid=$!
    run_suite "$frag" "$fix" 2>&1 |
        tee "$suite_log" |
        while IFS= read -r line; do
            [[ "$line" == "##E2E "* ]] || printf '%s\n' "$line"
        done
    code=${PIPESTATUS[0]}
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    if ((code == 124)); then
        echo "FAIL e2e suite '$name' timed out after $suite_timeout"
    fi
    # Aggregate the machine-readable tally line each fragment emits.
    tally="$(grep '^##E2E ' "$suite_log" | tail -1)"
    if [[ "$tally" =~ pass=([0-9]+)\ fail=([0-9]+)\ skip=([0-9]+) ]]; then
        total_pass=$((total_pass + BASH_REMATCH[1]))
        total_fail=$((total_fail + BASH_REMATCH[2]))
        total_skip=$((total_skip + BASH_REMATCH[3]))
    fi
    ((code != 0)) && failed_suites+=("$name")
    echo
done

echo "=============================================================="
echo "e2e totals: ${total_pass} passed, ${total_fail} failed, ${total_skip} skipped  (${#names[@]} suite(s))"
if ((${#failed_suites[@]} == 0)); then
    echo "ALL E2E SUITES PASSED"
    exit 0
fi
echo "FAILED SUITES: ${failed_suites[*]}"
exit 1
