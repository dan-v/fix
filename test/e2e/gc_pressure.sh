#!/usr/bin/env bash
# GC-pressure result-stability checks: the same evaluation must produce
# byte-identical results no matter when collections run. `FIX_GC_STEP_MB`
# forces a collection every N MB of fresh allocation, magnifying any value
# whose liveness depends on GC timing instead of reachability.
#
# Regression coverage for the derivation-env heap-string borrow bug: a
# context-free list env attr coerces to a fresh (otherwise unreachable)
# heap string whose BORROWED bytes were stored in the env while the walk
# kept forcing — a step-mode collection inside that window freed the bytes
# under the slice and produced silently wrong drvPaths. The fixture sorts
# the list attr FIRST (aaaUrls) so later attrs force inside the borrow
# window, and pads with churn so 1-2 MB steps land collections there.
# Engine-level counterpart of the GC half: the "major roots the pinned
# pre-arming region" test in src/expr/eval/gc_controller.zig.
#   test/e2e/gc_pressure.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

fixture="$(mktemp "${TMPDIR:-/tmp}/gc_pressure.XXXXXX.nix")"
trap 'rm -f "$fixture"' EXIT
cat >"$fixture" <<'EOF'
let
  long = i: "https://example.invalid/prefix-of-considerable-length/${toString i}/suffix-padding-padding-padding";
  urls = i: builtins.genList (j: long (i * 1000 + j)) 8;
  churn = i: builtins.concatStringsSep "-" (builtins.genList (j: toString (i + j)) 64);
  mk = i: derivation {
    name = "gcfix-${toString i}";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ ];
    aaaUrls = urls i;
    pad = churn i;
    zChurn = churn (i + 7);
  };
in map (d: d.drvPath) (builtins.genList mk 400)
EOF

plain="$("$FIX" eval --strict --json --workers 1 "$fixture" 2>/dev/null)"
if [[ -z "$plain" ]]; then
    fail "baseline eval produces output"
else
    pass "baseline eval produces output"
fi

for step in 1 2; do
    stepped="$(FIX_GC_STEP_MB=$step "$FIX" eval --strict --json --workers 1 "$fixture" 2>/dev/null)"
    if [[ "$stepped" == "$plain" ]]; then
        pass "drvPaths identical under FIX_GC_STEP_MB=$step"
    else
        fail "drvPaths identical under FIX_GC_STEP_MB=$step"
        echo "  GC-timing-dependent evaluation results (wrong drvPaths under pressure)"
    fi
done

e2e_finish
