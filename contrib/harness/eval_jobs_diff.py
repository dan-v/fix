#!/usr/bin/env python3
"""Field-by-field comparison of two eval-jobs JSONL outputs.

Default mode treats the first file as the reference (nix-eval-jobs) and the
second as the candidate (fix eval-jobs):

  - coverage: every attr present on one side must be present on the other;
  - agreement: drvPath (the strong oracle — equal drvPath certifies the whole
    derivation closure agrees), name, system, and outputs must match;
  - errors: an attr that errors on one side must error on the other (message
    text is evaluator-specific and NOT compared);
  - reference-only fields (meta, cacheStatus, ...) are reported as
    informational gaps, not failures.

--ab mode compares two runs of the same tool: records must agree on all
shared fields, and any field present in baseline but missing in current is a
failure (a regression can't hide by dropping a field).

Exit status: 0 iff no failures.
"""

import json
import sys
from collections import Counter

# Fields that must agree when present on both sides.
COMPARED = ("drvPath", "name", "system", "outputs")


def load(path):
    jobs = {}
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"{path}:{lineno}: unparseable JSONL: {e}")
                sys.exit(2)
            key = tuple(rec.get("attrPath") or [rec.get("attr", f"line{lineno}")])
            if key in jobs:
                print(f"{path}:{lineno}: duplicate attr {key}")
                sys.exit(2)
            jobs[key] = rec
    return jobs


def main():
    args = sys.argv[1:]
    ab = "--ab" in args
    args = [a for a in args if a != "--ab"]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    ref_name, cand_name = ("baseline", "current") if ab else ("nix-eval-jobs", "fix")
    ref, cand = load(args[0]), load(args[1])

    failures = []
    field_gaps = Counter()

    for key in sorted(set(ref) | set(cand)):
        attr = ".".join(key)
        r, c = ref.get(key), cand.get(key)
        if r is None:
            failures.append(f"{attr}: only in {cand_name}")
            continue
        if c is None:
            failures.append(f"{attr}: only in {ref_name}")
            continue
        r_err, c_err = "error" in r, "error" in c
        if r_err != c_err:
            side, other = (ref_name, cand_name) if r_err else (cand_name, ref_name)
            failures.append(f"{attr}: errors under {side} but not {other}")
            continue
        if r_err:
            continue  # both errored; message text is evaluator-specific
        for field in COMPARED:
            if field in r and field in c:
                if r[field] != c[field]:
                    failures.append(
                        f"{attr}: {field} mismatch\n"
                        f"    {ref_name}: {json.dumps(r[field])}\n"
                        f"    {cand_name}: {json.dumps(c[field])}"
                    )
            elif field in r:
                failures.append(f"{attr}: {field} missing from {cand_name}")
        for field in sorted(set(r) - set(c) - set(COMPARED)):
            if ab:
                failures.append(f"{attr}: field {field!r} present in baseline, missing in current")
            else:
                field_gaps[field] += 1

    n = len(set(ref) | set(cand))
    print(f"compared {n} attrs: {len(ref)} in {ref_name}, {len(cand)} in {cand_name}")
    if field_gaps:
        gaps = ", ".join(f"{f} ({c} attrs)" for f, c in field_gaps.most_common())
        print(f"informational — {ref_name} fields not emitted by {cand_name}: {gaps}")
    if failures:
        print(f"\nFAIL — {len(failures)} disagreement(s):")
        for f in failures[:50]:
            print(f"  {f}")
        if len(failures) > 50:
            print(f"  ... and {len(failures) - 50} more")
        sys.exit(1)
    print("OK — full agreement on coverage, errors, and compared fields")


if __name__ == "__main__":
    main()
