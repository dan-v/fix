# Shared harness for the `fix` end-to-end suites (sourced, never run directly).
#
# A suite is a `test/e2e/<name>.sh` fragment that sources this file, calls
# `e2e_init "$@"` (which resolves the fix binary), makes assertions with the
# helpers below, and ends with `e2e_finish`. Fragments stay independently
# runnable — `test/e2e/repl.sh /path/to/fix` — and `run.sh` drives them all.
#
# NOTE: these run the fix binary; hold the perf compute lock when invoking.

# --- binary + lifecycle -----------------------------------------------------

# e2e_init [FIX_PATH]: pick the binary (arg > $FIX env > zig-out/bin/fix) and
# make it absolute so a fragment can `cd` into a temp dir and still find it.
e2e_init() {
    FIX="${1:-${FIX:-zig-out/bin/fix}}"
    if [[ ! -x "$FIX" ]]; then
        echo "e2e: fix binary not found/executable at '$FIX' (build with \`zig build\`)" >&2
        exit 2
    fi
    FIX="$(cd "$(dirname "$FIX")" && pwd)/$(basename "$FIX")"
    E2E_NAME="$(basename "${BASH_SOURCE[1]:-e2e}" .sh)"
    E2E_PASS=0
    E2E_FAILS=0
    E2E_SKIP=0
    E2E_TMPDIRS=()
    trap 'e2e_cleanup' EXIT
}

# e2e_have_pty: true only for a util-linux script(1) (`-c`/`-e`). BSD/macOS
# `script` has an incompatible CLI, so PTY-driven checks skip there rather than
# fail — the pipe-mode contract stays covered on every platform.
e2e_have_pty() {
    command -v script >/dev/null 2>&1 || return 1
    script --version 2>/dev/null | grep -qi util-linux
}

e2e_cleanup() {
    local d
    for d in "${E2E_TMPDIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
}

# e2e_mktemp: a temp dir cleaned up automatically at fragment exit (no manual
# trap juggling when a fragment needs several).
e2e_mktemp() {
    local d
    d="$(mktemp -d)"
    E2E_TMPDIRS+=("$d")
    printf '%s' "$d"
}

# --- assertions -------------------------------------------------------------

pass() { echo "ok   $1"; E2E_PASS=$((E2E_PASS + 1)); }
fail() {
    echo "FAIL $1"
    E2E_FAILS=$((E2E_FAILS + 1))
}
# skip <name> [reason]: an environmentally-unavailable check (never a pass, does
# not fail the run) — the harness's honest analogue of the lang suite's BLOCKED.
skip() {
    echo "skip $1${2:+  ($2)}"
    E2E_SKIP=$((E2E_SKIP + 1))
}

# t <name> <expected-substring> <actual>: pass iff actual contains expected.
t() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then
        pass "$name"
    else
        fail "$name"
        echo "  wanted substring: $(printf '%q' "$want")"
        echo "  got: $(printf '%q' "$got")" | head -c 2000
        echo
    fi
}

# t_absent <name> <unwanted-substring> <actual>: pass iff actual lacks it.
t_absent() {
    local name="$1" nope="$2" got="$3"
    if [[ "$got" == *"$nope"* ]]; then
        fail "$name"
        echo "  unwanted substring present: $(printf '%q' "$nope")"
    else
        pass "$name"
    fi
}

# ok_if <name> <cmd...>: pass iff the command succeeds.
ok_if() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

# --- pseudo-terminal --------------------------------------------------------
# `script` gives a child a real PTY. The settle delays matter: bytes sent
# before the repl enables raw mode hit a cooked tty (where ^C is SIGINT).
pty() { # pty <printf-format-of-keystrokes> [extra fix args...]
    local keys="$1"
    shift
    (
        sleep 0.4
        printf "$keys"
        sleep 0.4
    ) | script -qec "$FIX repl $*" /dev/null 2>/dev/null
}

# --- summary ----------------------------------------------------------------
# Prints a machine-readable tally line run.sh aggregates, then exits nonzero if
# anything failed.
e2e_finish() {
    echo
    echo "##E2E ${E2E_NAME} pass=${E2E_PASS} fail=${E2E_FAILS} skip=${E2E_SKIP}"
    local tail=""
    ((E2E_SKIP > 0)) && tail=", $E2E_SKIP skipped"
    if ((E2E_FAILS == 0)); then
        echo "[$E2E_NAME] ALL PASS ($E2E_PASS checks$tail)"
    else
        echo "[$E2E_NAME] $E2E_FAILS FAILURE(S) ($E2E_PASS passed$tail)"
    fi
    exit $((E2E_FAILS > 0))
}
