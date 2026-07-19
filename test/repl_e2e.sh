#!/usr/bin/env bash
# End-to-end checks for `fix repl`: the bare (pipe) mode contract, the
# interactive editor under a real PTY, and the between-inputs GC plateau.
# Run from the repo root with the fix binary as $1 (default zig-out/bin/fix).
# NOTE: runs the binary — hold the perf compute lock when invoking.
set -u
FIX=${1:-zig-out/bin/fix}
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

# --- bare mode (pipes: the automation contract) -----------------------------

out=$(printf '1 + 2\n' | "$FIX" repl 2>/dev/null)
t "bare: arithmetic" "3" "$out"

# No escape sequences may appear on stdout in bare mode.
if printf 'x = 41\nx + 1\n' | "$FIX" repl 2>/dev/null | grep -q $'\x1b'; then
    echo "FAIL bare: no escape sequences"; fails=$((fails+1))
else
    echo "ok   bare: no escape sequences"
fi

out=$(printf 'x = 41\nx + 1\n' | "$FIX" repl 2>/dev/null)
t "bare: bindings persist" "42" "$out"

out=$(printf '2 * 3\nit + 1\n' | "$FIX" repl 2>/dev/null)
t "bare: it binding" "7" "$out"

out=$(printf '{ a = 1;\n  b = 2; }\n' | "$FIX" repl 2>/dev/null)
t "bare: multiline accumulation" "a = 1" "$out"

out=$(printf ':t { a = 1; b = 2; }\n' | "$FIX" repl 2>/dev/null)
t "bare: :t" "a set (2 attrs)" "$out"

out=$(printf ':?\n' | "$FIX" repl 2>/dev/null)
t "bare: :? lists :vm" ":vm, :d, :disasm" "$out"

out=$(printf ':env\nfoo = 1\n:env\n' | "$FIX" repl 2>/dev/null)
t "bare: :env before" "no bindings" "$out"
t "bare: :env after" "foo : an integer" "$out"

out=$(printf ':vm 1 + 2\n' | "$FIX" repl 2>/dev/null)
t "bare: :vm prints a chunk" "chunk[0x" "$out"
# (1 + 2 folds to a constant; a lambda body keeps its arithmetic.)
out=$(printf ':vm x: x + 1\n' | "$FIX" repl 2>/dev/null)
t "bare: :vm shows opcodes" "int_add" "$out"

out=$(printf ':vm x: x + 1\n:vm\n' | "$FIX" repl 2>/dev/null)
chunks=$(grep -c 'chunk\[0x' <<<"$out")
if (( chunks >= 2 )); then
    echo "ok   bare: focused chunk is repeatable"
else
    echo "FAIL bare: focused chunk is repeatable"; fails=$((fails+1))
fi

out=$(printf '1 + 2\n:vm ls 1\n:vm chunks 1\n' | "$FIX" repl 2>/dev/null)
t "bare: :vm name tree is queryable" "@0 <root>" "$out"
t "bare: :vm listings report bounded overflow" "increase LIMIT" "$out"

out=$(printf '1\n:vm heap\n' | "$FIX" repl --bare --color=never 2>/dev/null)
t "bare: :vm heap has bounded aggregate output" "object slots" "$out"
t "bare: :vm heap includes object variants" "thunk states" "$out"
heap_lines=$(wc -l <<<"$out")
if (( heap_lines <= 24 )); then
    echo "ok   bare: :vm heap stays bounded"
else
    echo "FAIL bare: :vm heap emitted $heap_lines lines"; fails=$((fails+1))
fi

out=$(printf ':i builtins.map\n' | "$FIX" repl 2>/dev/null)
t "bare: :i function" "a function" "$out"

out=$(printf 'f = x: x * 2\n:i f\n' | "$FIX" repl 2>/dev/null)
t "bare: :i closure shows chunk" "closure: chunk #" "$out"

out=$(printf ':q\n1 + 1\n' | "$FIX" repl 2>/dev/null)
if [[ "$out" == *"2"* ]]; then
    echo "FAIL bare: :q stops the loop"; fails=$((fails+1))
else
    echo "ok   bare: :q stops the loop"
fi

out=$(printf 'builtins.throw "nope"\n1 + 1\n' | "$FIX" repl 2>/dev/null)
t "bare: error then recovery" "2" "$out"

# EOF with a pending incomplete expression still evaluates it.
out=$(printf '[ 1 2\n3 ]' | "$FIX" repl 2>/dev/null)
t "bare: EOF flushes pending" "[ 1 2 3 ]" "$out"

# --bare on a tty still gets a plain prompt (checked via PTY below).

# --- interactive mode under a PTY --------------------------------------------
# `script` gives the child a real PTY. The settle delay matters: bytes sent
# before the repl enables raw mode hit a cooked tty (where ^C is SIGINT).

pty() { # pty <printf-format-of-keystrokes>
    ( sleep 0.4; printf "$1"; sleep 0.4 ) | script -qec "$FIX repl" /dev/null 2>/dev/null
}

out=$(pty '1 + 2\r')
t "tty: banner hint" ":? for help" "$out"
t "tty: prompt" "fix>" "$out"
t "tty: evaluates" "3" "$out"
if [[ "$out" == *$'\x1b[?1049h'* ]]; then
    echo "FAIL tty: inline repl does not claim alternate screen"; fails=$((fails+1))
else
    echo "ok   tty: inline repl does not claim alternate screen"
fi

out=$(pty ':vm\rq')
t "tty: :vm opens before first evaluation" "The VM explorer" "$out"

# The VM workspace is entered explicitly, and leaving it restores the normal
# terminal before replaying expressions evaluated inside the workspace.
out=$(
    ( sleep 0.4; printf 'x: x + 1\r'; sleep 0.3; printf ':vm\r'; sleep 0.5;
      printf 'i1 + 1\r'; sleep 0.4; printf '\033'; sleep 0.2; printf 'q';
      sleep 0.3; printf '\004'; sleep 0.2 ) |
        script -qec "$FIX repl" /dev/null 2>/dev/null
)
if [[ "$out" == *$'\x1b[?1049h'* && "$out" == *$'\x1b[?1049l'* ]]; then
    echo "ok   tty: :vm owns and restores alternate screen"
else
    echo "FAIL tty: :vm screen lifecycle"; fails=$((fails+1))
fi
after_vm=${out##*$'\x1b[?1049l'}
t "tty: vm transcript survives screen exit" "fix> 1 + 1" "$after_vm"

# Tab completion: a unique candidate completes fully in-line.
out=$(pty 'builtins.getFla\t\r')
t "tty: unique attr completion" "getFlake" "$out"

# Smart-enter: '{ a = 1;' is incomplete -> continuation prompt appears.
out=$(
    ( sleep 0.4; printf '{ a = 1;\r'; sleep 0.2; printf '}\r'; sleep 0.4 ) |
        script -qec "$FIX repl" /dev/null 2>/dev/null
)
t "tty: continuation prompt" "...>" "$out"
t "tty: multiline evaluates" "a = 1" "$out"

# Bracketed paste: pasted newlines must not submit.
out=$(pty '\x1b[200~1 +\n2\x1b[201~\r')
t "tty: paste keeps newline" "3" "$out"

# Ctrl-C clears the line; the second expression still evaluates.
out=$(pty 'garbage!!!\x037 * 6\r')
t "tty: ctrl-c clears" "42" "$out"

# Ctrl-D on an empty line exits without error output.
out=$(( sleep 0.4; printf '\x04'; sleep 0.4 ) | script -qec "$FIX repl; echo exit=\$?" /dev/null 2>/dev/null)
t "tty: ctrl-d exits 0" "exit=0" "$out"

# --bare forces the plain loop even on a tty (no escape codes emitted).
out=$(printf '1 + 1\n\x04' | script -qec "$FIX repl --bare" /dev/null 2>/dev/null)
t "tty+bare: evaluates" "2" "$out"
if [[ "$out" == *$'\x1b['* ]]; then
    echo "FAIL tty+bare: no CSI output"; fails=$((fails+1))
else
    echo "ok   tty+bare: no CSI output"
fi

# --- GC between inputs: RSS/reserved plateau ---------------------------------
#
# Checks that reclaiming a heavy input's garbage between inputs holds reserved
# memory flat. `:gc` runs a MAJOR (full) collection, which reclaims the tenured
# old generation too — without it, under parallel workers more objects tenure
# and reserved would ratchet up input to input (a minor only frees the young
# survivors). Runs at the default worker count on purpose, to exercise that.

gc_soak() {
    local n=$1
    {
        for i in $(seq 1 "$n"); do
            printf 'builtins.length (builtins.genList (x: { v = x * 2; }) 200000)\n'
            printf ':gc\n'
        done
    } | "$FIX" repl --gc-budget=4096 2>/dev/null | grep '^gc:' | tail -1
}
first=$(gc_soak 3)
last=$(gc_soak 24)
echo "gc soak: after 3 inputs:  $first"
echo "gc soak: after 24 inputs: $last"
mb() { echo "$1" | sed -n 's/.*-> \([0-9.]*\) MiB.*/\1/p' | cut -d. -f1; }
a=$(mb "$first"); b=$(mb "$last")
if [[ -n "$a" && -n "$b" ]] && (( b < a * 3 + 64 )); then
    echo "ok   gc: reserved plateaus (${a} MiB -> ${b} MiB across 8x the inputs)"
else
    echo "FAIL gc: reserved grew (${a:-?} MiB -> ${b:-?} MiB)"
    fails=$((fails+1))
fi

echo
if (( fails == 0 )); then echo "ALL PASS"; else echo "$fails FAILURES"; exit 1; fi
