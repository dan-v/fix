#!/usr/bin/env bash
# Compare two outpaths.nix result sets (oracle vs fix) attr-by-attr.
#
#   compare.sh <oracle.json> <fix.json>
#
# Buckets:
#   match         same drvPath (or both null / both threw)
#   drv-mismatch  both produced a drvPath, but they differ
#   oracle-null   oracle threw, fix produced a drvPath
#   fix-null      fix threw, oracle produced a drvPath
#   oracle-only   attr present only in the oracle result
#   fix-only      attr present only in the fix result
# Exits nonzero if any bucket other than match is nonempty.
set -euo pipefail

oracle="$1"
fix="$2"

jq -n --slurpfile a "$oracle" --slurpfile b "$fix" '
  (.oracle = $a[0]) | (.fix = $b[0]) |
  (.oracle | keys_unsorted) as $ak | (.fix | keys_unsorted) as $bk |
  ($ak - $bk) as $oracle_only | ($bk - $ak) as $fix_only |
  [ ($ak - $oracle_only)[] as $k
    | {key: $k, o: .oracle[$k], f: .fix[$k]}
    | select(.o != .f)
    | . + {bucket: (if .o == null then "oracle-null"
                    elif .f == null then "fix-null"
                    else "drv-mismatch" end)}
  ] as $diffs |
  {
    total: ($ak | length),
    match: (($ak | length) - ($oracle_only | length) - ($diffs | length)),
    "drv-mismatch": [$diffs[] | select(.bucket == "drv-mismatch") | .key],
    "oracle-null":  [$diffs[] | select(.bucket == "oracle-null")  | .key],
    "fix-null":     [$diffs[] | select(.bucket == "fix-null")     | .key],
    "oracle-only":  $oracle_only,
    "fix-only":     $fix_only,
  }
' >/tmp/nixpkgs-compare.json

jq -r '
  "total \(.total)  match \(.match)",
  (to_entries[] | select(.value | type == "array") |
    "\(.key): \(.value | length)" ),
  "",
  (to_entries[] | select((.value | type == "array") and (.value | length > 0)) |
    "== \(.key) (first 20) ==", (.value[:20][]))
' /tmp/nixpkgs-compare.json

jq -e '
  (."drv-mismatch" + ."oracle-null" + ."fix-null" + ."oracle-only" + ."fix-only")
  | length == 0
' /tmp/nixpkgs-compare.json >/dev/null
