#!/usr/bin/env bash
# End-to-end checks for `fix repl`: the bare (pipe) mode contract, the
# interactive editor under a real PTY, and the between-inputs GC plateau.
#   test/e2e/repl.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

# --- bare mode (pipes: the automation contract) -----------------------------

out=$(printf '1 + 2\n' | "$FIX" repl 2>/dev/null)
t "bare: arithmetic" "3" "$out"

# No escape sequences may appear on stdout in bare mode.
if printf 'x = 41\nx + 1\n' | "$FIX" repl 2>/dev/null | grep -q $'\x1b'; then
    fail "bare: no escape sequences"
else
    pass "bare: no escape sequences"
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
t "bare: :? lists debugger" ":debug, :d EXPR" "$out"
t "bare: :? lists :vm" ":vm [COMMAND | EXPR]" "$out"

out=$(printf ':env\nfoo = 1\n:env\n' | "$FIX" repl 2>/dev/null)
t "bare: :env before" "no bindings" "$out"
t "bare: :env after" "foo : an integer" "$out"

out=$(printf ':vm 1 + 2\n' | "$FIX" repl 2>/dev/null)
t "bare: :vm prints a chunk" "chunk[0x" "$out"
# (1 + 2 folds to a constant; a lambda body keeps its arithmetic.)
out=$(printf ':vm x: x + 1\n' | "$FIX" repl 2>/dev/null)
t "bare: :vm shows opcodes" "int_add" "$out"

out=$(printf ':vm "hello"\n' | "$FIX" repl --color=never 2>/dev/null)
t "bare: :vm values lead with intern location" "intern[0x" "$out"
t "bare: :vm intern value includes type and text" '→ string "hello"' "$out"

out=$(printf ':vm x: x + 1\n:vm\n' | "$FIX" repl 2>/dev/null)
chunks=$(grep -c 'chunk\[0x' <<<"$out")
if ((chunks >= 2)); then
    pass "bare: focused chunk is repeatable"
else
    fail "bare: focused chunk is repeatable"
fi

out=$(printf '1 + 2\n:vm ls 1\n:vm chunks 1\n' | "$FIX" repl 2>/dev/null)
t "bare: :vm name tree is queryable" "@0 <root>" "$out"
listing_lines=$(wc -l <<<"$out")
if ((listing_lines <= 6)); then
    pass "bare: :vm listings stay bounded"
else
    fail "bare: :vm listings emitted $listing_lines lines"
fi

out=$(printf '1\n:vm heap\n' | "$FIX" repl --bare --color=never 2>/dev/null)
t "bare: :vm heap has bounded aggregate output" "object slots" "$out"
t "bare: :vm heap includes object variants" "thunk states" "$out"
heap_lines=$(wc -l <<<"$out")
if ((heap_lines <= 28)); then
    pass "bare: :vm heap stays bounded"
else
    fail "bare: :vm heap emitted $heap_lines lines"
fi

out=$(printf '1\n:vm objects 0 3\n' | "$FIX" repl --bare --color=never 2>/dev/null)
t "bare: :vm object rows lead with location" "objects[0x0] →" "$out"
if [[ "$out" == *"list[0x"* || "$out" == *"attrs[0x"* || "$out" == *"thunk[0x"* ]]; then
    fail "bare: :vm object rows used a type as a store"
else
    pass "bare: :vm object rows use canonical stores"
fi

out=$(printf '1\n:vm help\n' | "$FIX" repl --no-tui --color=never 2>/dev/null)
t "bare: :vm help lists heap stores" "store NAME [START] [LIMIT]" "$out"
t "bare: :vm help lists references" "refs (chunk|object) ID [LIMIT]" "$out"
t "bare: :vm help lists instruction breakpoints" "break-at CHUNK OFFSET" "$out"

out=$(printf '{ a = 1; b = [ 2 3 ]; }\n:vm store values 0 3\n:vm store attrs 0 3\n:vm store attr-positions 0 3\n:vm store intern 0 3\n:vm store builtin 0 3\n' |
    "$FIX" repl --no-tui --color=never 2>/dev/null)
t "bare: values store is queryable" "values[0x0:" "$out"
t "bare: attrs store is queryable" "attrs[0x0:" "$out"
t "bare: attr-position store is queryable" "attr-positions[0x0:" "$out"
t "bare: intern store is queryable" "intern[0x0:" "$out"
t "bare: builtin store is queryable" "builtin[0x0:" "$out"

out=$(printf '[ 1 2 ]\n:vm object 0 3\n:vm refs chunk 0 3\n:vm spans\n:vm find top 3\n:vm break-at 0 0\n:vm breakpoints\n:vm clear-at 0 0\n' |
    "$FIX" repl --no-tui --color=never 2>/dev/null)
t "bare: object inspection includes members" "ITEMS" "$out"
t "bare: object inspection includes outgoing refs" "OUTGOING" "$out"
t "bare: object inspection includes incoming refs" "INCOMING" "$out"
t "bare: source spans are queryable" "SOURCE SPANS" "$out"
t "bare: bytecode names are searchable" "(top)" "$out"
t "bare: instruction breakpoints are settable" "breakpoint" "$out"

# The automation frontend remains line-oriented while exercising the same
# entry stop, deferred import stepping, pending breakpoints, and logical stack.
# Crossing the import boundary takes two steps: push_const -> the import `call`,
# then a step into the imported chunk (where the pending breakpoint resolves).
out=$(printf ':d (import ./test/imported.nix).value\nbreak test/imported.nix:1\nbreakpoints\ns\ns\nbt\n:frame 0\n:vm store intern 0 2\nfinish\nc\n' |
    "$FIX" repl --bare --color=never 2>&1)
t "bare debug: native entry" "-- debugger #1 (entry) --" "$out"
t "bare debug: pending import breakpoint" "test/imported.nix:1 (pending)" "$out"
t "bare debug: steps into import" "imported.nix:1:3" "$out"
t "bare debug: cross-import caller" "#1 <repl>:1:2" "$out"
t "bare debug: frame document includes non-forcing locals" "LOCALS · values are not forced" "$out"
t "bare debug: frame document includes code" "CODE · chunk[0x" "$out"
t "bare debug: VM queries reach heap stores" "intern[0x0:" "$out"
if [[ "$out" == *$'\x1b['* ]]; then
    fail "bare debug: no CSI output"
else
    pass "bare debug: no CSI output"
fi

out=$(printf ':i builtins.map\n' | "$FIX" repl 2>/dev/null)
t "bare: :i function" "→ map" "$out"

out=$(printf 'f = x: x * 2\n:i f\n' | "$FIX" repl 2>/dev/null)
t "bare: :i closure shows chunk" "chunk[0x" "$out"

out=$(printf ':q\n1 + 1\n' | "$FIX" repl 2>/dev/null)
if [[ "$out" == *"2"* ]]; then
    fail "bare: :q stops the loop"
else
    pass "bare: :q stops the loop"
fi

out=$(printf 'builtins.throw "nope"\n1 + 1\n' | "$FIX" repl 2>/dev/null)
t "bare: error then recovery" "2" "$out"

# EOF with a pending incomplete expression still evaluates it.
out=$(printf '[ 1 2\n3 ]' | "$FIX" repl 2>/dev/null)
t "bare: EOF flushes pending" "[ 1 2 3 ]" "$out"

# --bare on a tty still gets a plain prompt (checked via PTY below).

# --- interactive mode under a PTY --------------------------------------------
# Skipped wholesale where there is no util-linux script(1) (e.g. macOS/BSD); the
# bare-mode pipe contract above already runs on every platform.
if ! e2e_have_pty; then
    skip "tty: interactive PTY checks" "no util-linux script(1)"
else

out=$(pty '1 + 2\r')
t "tty: banner hint" ":? for help" "$out"
t "tty: prompt" "fix>" "$out"
t "tty: evaluates" "3" "$out"
if [[ "$out" == *$'\x1b[?1049h'* ]]; then
    fail "tty: inline repl does not claim alternate screen"
else
    pass "tty: inline repl does not claim alternate screen"
fi

out=$(
    (
        sleep 0.4
        printf ':vm\r'
        sleep 0.4
        printf 'q'
        sleep 0.4
    ) |
        script -qec "$FIX repl" /dev/null 2>/dev/null
)
t "tty: :vm opens before first evaluation" "The VM explorer" "$out"

# The VM workspace is entered explicitly, and leaving it restores the normal
# terminal before replaying expressions evaluated inside the workspace.
out=$(
    (
        sleep 0.4
        printf 'x: x + 1\r'
        sleep 0.3
        printf ':vm\r'
        sleep 0.5
        printf 'i1 + 1\r'
        sleep 0.4
        printf '\033'
        sleep 0.2
        printf 'q'
        sleep 0.3
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl" /dev/null 2>/dev/null
)
if [[ "$out" == *$'\x1b[?1049h'* && "$out" == *$'\x1b[?1049l'* ]]; then
    pass "tty: :vm owns and restores alternate screen"
else
    fail "tty: :vm screen lifecycle"
fi
after_vm=${out##*$'\x1b[?1049l'}
t "tty: vm transcript survives screen exit" "fix> 1 + 1" "$after_vm"

# A chunk uses one debugger-style document. SOURCE is an in-place inspection
# session followed by code, constants, and references.
out=$(
    (
        sleep 0.4
        printf '1 + 2 * 3\r'
        sleep 0.4
        printf ':vm\r'
        sleep 0.6
        printf '\t'
        sleep 0.3
        printf '\t'
        sleep 0.2
        printf 'G'
        sleep 0.4
        printf 'q'
        sleep 0.3
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
t "tty vm: unified inspector offers source span session" "SOURCE · 1 subexpressions" "$out"
t "tty vm: unified inspector includes code" "CODE · chunk" "$out"
if [[ "$out" == *"PREVIEW"* ]]; then
    fail "tty vm: current tree subject covered itself with a preview"
else
    pass "tty vm: current tree subject has no redundant preview"
fi
if [[ "$out" == *"Enter leaves"* ]]; then
    fail "tty vm: source heading still advertises Enter-to-leave"
else
    pass "tty vm: source heading has no Enter-to-leave behavior"
fi
if [[ "$out" == *"▶"* ]]; then
    fail "tty vm: ordinary source showed a subexpression cursor"
else
    pass "tty vm: ordinary source has no subexpression cursor"
fi
if [[ "$out" == *"asynchronously"* || "$out" == *"updating references"* ]]; then
    fail "tty vm: inspector exposed background indexing state"
else
    pass "tty vm: background indexing stays out of documents"
fi

# Hover previews are stable overlays with their own scroll position. The heap
# census populates the collapsed HEAP preview and includes every object variant,
# including zero-count variants, so the explorer never silently omits a type.
out=$(
    (
        sleep 0.4
        printf 'x: (x + 1) * (x + 2)\r'
        sleep 0.4
        printf ':vm\r'
        sleep 0.7
        printf '\t'
        sleep 0.3
        printf 'g'
        sleep 0.7
        printf '\033j'
        sleep 0.25
        for _ in 1 2 3 4 5 6 7; do
            printf '\033[1;3B'
            sleep 0.12
        done
        printf 'q'
        sleep 0.3
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
if grep -aoE '[2-9]-[0-9]+/[0-9]+' <<<"$out" >/dev/null; then
    pass "tty vm: Alt-j and Alt-arrow scroll hover previews"
else
    fail "tty vm: hover preview did not scroll"
fi
t "tty vm: collapsed heap preview includes object variants" "object types" "$out"
t "tty vm: heap preview includes the last object variant" "partial application" "$out"

# Store folders distinguish live records from reserved TLAB tails. Opening the
# object store synchronously materializes its live rows, while dense stores use
# the same canonical range language.
out=$(
    (
        sleep 0.4
        printf '{ a = 1; b = 2; c = 3; d = 4; }\r'
        sleep 0.4
        printf ':vm\r'
        sleep 0.7
        printf '\t'
        sleep 0.2
        printf 'g'
        sleep 0.2
        printf '\r'
        sleep 0.3
        printf 'j'
        sleep 0.2
        printf '\r'
        sleep 0.6
        printf 'q'
        sleep 0.2
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
if grep -aoE 'objects · [0-9]+ live' <<<"$out" >/dev/null; then
    pass "tty vm: object folder starts with a live count"
else
    fail "tty vm: object folder did not report live records"
fi
if grep -aoE 'objects\[0x0:0x[0-9a-f]+\] \([0-9]+\)' <<<"$out" >/dev/null; then
    pass "tty vm: object range uses a live extent and count"
else
    fail "tty vm: object range did not materialize"
fi
t "tty vm: expanded object store contains records" "objects[0x0] →" "$out"
t "tty vm: intern store appears in the tree" "intern[0x0:" "$out"
t "tty vm: builtin store appears in the tree" "builtin[0x0:" "$out"
if [[ "$out" == *"objects[0x0:0x100] (256)"* ]]; then
    fail "tty vm: object range exposed its reserved TLAB tail"
else
    pass "tty vm: object range excludes its reserved TLAB tail"
fi

# Nested expressions on one line may share a bytecode-entry offset. A source
# breakpoint must mark only the exact selected span, not every row with that
# old shared offset.
out=$(
    (
        sleep 0.4
        printf 'x: (x + 1) * (x + 2)\r'
        sleep 0.4
        printf ':vm\r'
        sleep 0.6
        printf '\r'
        sleep 0.3
        # Enter on the selected span is deliberately a no-op; Escape owns
        # leaving the source interaction layer.
        printf '\r'
        sleep 0.2
        printf 'p'
        sleep 0.4
        printf 'q'
        sleep 0.2
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
span_marks=$(printf '%s' "$out" | grep -o '◆' | wc -l)
t "tty vm: source session shows span progress" "SOURCE · 1/" "$out"
if [[ "$span_marks" -eq 1 ]]; then
    pass "tty vm: source breakpoint marks only its exact span"
else
    fail "tty vm: source breakpoint marked $span_marks span rows"
fi

# The tree filter modal is entered with F and echoes the query in the header.
out=$(
    (
        sleep 0.4
        printf '1 + 1\r'
        sleep 0.4
        printf ':vm\r'
        sleep 0.6
        printf 'F'
        sleep 0.3
        printf 'zqx\r'
        sleep 0.4
        printf 'q'
        sleep 0.3
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
t "tty vm: filter modal echoes the query" "filter 'zqx'" "$out"

# A debugger reached from the inline prompt owns one alternate-screen session
# across multiple step stops, then restores the ordinary REPL on continue.
out=$(
    (
        sleep 0.4
        printf ':d (import ./test/imported.nix).value\r'
        sleep 0.6
        printf 's'
        sleep 0.5
        printf 's'
        sleep 0.5
        printf 'c'
        sleep 0.4
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
t "tty debug: opens integrated screen" "paused/entry" "$out"
t "tty debug: frame heading uses section language" "FRAME · #" "$out"
t "tty debug: locals heading uses section language" "LOCALS · values are not forced" "$out"
t "tty debug: code heading uses section language" "CODE · chunk" "$out"
# Two steps to cross into the import (pause 2 is still the <repl> `call`); the
# paused frame subtree shows the imported file within the same screen.
t "tty debug: import step stays in screen" "imported.nix" "$out"
debug_enters=$(grep -o $'\x1b\[?1049h' <<<"$out" | wc -l)
debug_leaves=$(grep -o $'\x1b\[?1049l' <<<"$out" | wc -l)
if ((debug_enters == 1 && debug_leaves == 1)); then
    pass "tty debug: one screen across steps"
else
    fail "tty debug: screen lifecycle ($debug_enters enters, $debug_leaves leaves)"
fi

# The owned debugger keeps the explorer model, terminal screen, and interaction
# focus. Expand HEAP/objects and step once: the new frame becomes the subject,
# while the tree stays focused and its freshly-snapshotted range stays expanded.
out=$(
    (
        sleep 0.4
        printf ':d (x: x) { a = [1]; }\r'
        sleep 0.6
        printf '\tgjj\r'
        sleep 0.4
        printf 'j\r'
        sleep 0.5
        printf 's'
        sleep 0.8
        printf 'q'
        sleep 0.3
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
expanded_object_frames=$(grep -aoE 'objects\[0x0:0x[0-9a-f]+\] \([0-9]+\)' <<<"$out" | wc -l)
if ((expanded_object_frames >= 2)); then
    pass "tty debug: stepping preserves tree focus and expansion"
else
    fail "tty debug: stepping left or collapsed the expanded object tree"
fi

# Finishing the outermost frame can complete without another debugger pause.
# Its value must be printed after the alternate screen is restored, where it
# remains in the ordinary REPL transcript.
out=$(
    (
        sleep 0.4
        printf ':d 40 + 2\r'
        sleep 0.5
        printf 'f'
        sleep 0.5
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
after_debug=${out##*$'\x1b[?1049l'}
t "tty debug: completed result survives screen exit" "42" "$after_debug"

# A return pause annotates the caller's source pointer, CIDER/SLIME-style,
# rather than adding a detached value section or decorating bytecode.
out=$(
    (
        sleep 0.4
        printf ':d (x: x) (y: y)\r'
        sleep 0.5
        for _ in 1 2 3 4; do
            printf 's'
            sleep 0.25
        done
        printf 'q'
        sleep 0.3
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
t "tty debug: return uses canonical value rendering" "⇒ chunk[0x" "$out"
if [[ "$out" == *$'\x1b[1;7m⇒ chunk[0x'*$' → function'* && "$out" == *$'\x1b[1;4m⇒ chunk[0x'*$' → function'* ]]; then
    pass "tty debug: return value flashes once then remains emphasized"
else
    fail "tty debug: return value did not show flash and settled styles"
fi

# A heap-backed inline return result is selected as a normal value link. Enter
# follows it in-place using the same object action as locals, stack slots, and
# tree references.
out=$(
    (
        sleep 0.4
        printf ':d (x: x) { a = [1]; }\r'
        sleep 0.5
        for _ in 1 2 3; do
            printf 's'
            sleep 0.25
        done
        sleep 0.3
        printf '\r'
        sleep 0.5
        printf 'q'
        sleep 0.3
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
t "tty debug: Enter follows an inline returned object" "MEMBERS · 1" "$out"
t "tty debug: heap objects have an outgoing reference section" "OUTGOING · 1" "$out"
t "tty debug: heap objects list outgoing object references" "→ objects[0x" "$out"
t "tty debug: heap objects have an incoming reference section" "INCOMING · 1" "$out"
t "tty debug: heap objects list incoming chunk references" "← chunk[0x" "$out"

# Inside :vm the debugger borrows the explorer's raw mode and alternate screen;
# nested stepping must not emit another enter/leave pair.
out=$(
    (
        sleep 0.4
        printf ':vm\r'
        sleep 0.5
        printf ':d (import ./test/imported.nix).value\r'
        sleep 0.6
        printf 's'
        sleep 0.5
        printf 'c'
        sleep 0.4
        printf '\033'
        sleep 0.2
        printf 'q'
        sleep 0.4
        printf '\004'
        sleep 0.2
    ) |
        script -qec "$FIX repl --color=never" /dev/null 2>/dev/null
)
t "tty vm debug: debugger is integrated" "paused/entry" "$out"
t "tty vm debug: explorer redraws" "fix vm" "$out"
vm_debug_enters=$(grep -o $'\x1b\[?1049h' <<<"$out" | wc -l)
vm_debug_leaves=$(grep -o $'\x1b\[?1049l' <<<"$out" | wc -l)
if ((vm_debug_enters == 1 && vm_debug_leaves == 1)); then
    pass "tty vm debug: borrows explorer screen"
else
    fail "tty vm debug: nested screen lifecycle ($vm_debug_enters enters, $vm_debug_leaves leaves)"
fi

# Tab completion: a unique candidate completes fully in-line.
out=$(pty 'builtins.getFla\t\r')
t "tty: unique attr completion" "getFlake" "$out"

# Smart-enter: '{ a = 1;' is incomplete -> continuation prompt appears.
out=$(
    (
        sleep 0.4
        printf '{ a = 1;\r'
        sleep 0.2
        printf '}\r'
        sleep 0.4
    ) |
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

# --no-tui retains the inline editor but prevents optional workspaces from
# claiming the alternate screen.
out=$(( sleep 0.4; printf '1 + 1\r'; sleep 0.3; printf '\x04'; sleep 0.2 ) |
    script -qec "$FIX repl --no-tui --color=never" /dev/null 2>/dev/null)
t "tty+no-tui: evaluates" "2" "$out"
if [[ "$out" == *$'\x1b[?1049h'* ]]; then
    fail "tty+no-tui: no alternate screen"
else
    pass "tty+no-tui: no alternate screen"
fi

fi # e2e_have_pty

# --- GC between inputs: retained-capacity plateau -----------------------------
#
# Checks that reclaiming a heavy input's garbage between inputs lets the heap
# reuse its retained capacity. `:gc` runs a MAJOR (full) collection, which
# reclaims the tenured old generation; without reuse the capacity would ratchet
# up input to input. Runs at the default worker count on purpose.

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
mb() { echo "$1" | sed -n 's/.*capacity \([0-9.]*\) MiB.*/\1/p' | cut -d. -f1; }
a=$(mb "$first")
b=$(mb "$last")
if [[ -n "$a" && -n "$b" ]] && ((b < a * 3 + 64)); then
    pass "gc: capacity plateaus (${a} MiB -> ${b} MiB across 8x the inputs)"
else
    fail "gc: capacity grew (${a:-?} MiB -> ${b:-?} MiB)"
fi

e2e_finish
