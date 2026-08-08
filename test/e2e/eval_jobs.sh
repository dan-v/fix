#!/usr/bin/env bash
# End-to-end checks for `fix eval-jobs` — the nix-eval-jobs-compatible JSONL
# walker a build pipeline consumes.
#   test/e2e/eval_jobs.sh [FIX]     (default zig-out/bin/fix)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
e2e_init "$@"

d=$(e2e_mktemp)

# A derivation per interesting shape: top level, inside a recursing set, inside
# a non-recursing set (must NOT be found), and one that throws.
cat >"$d/jobs.nix" <<'EOF'
let
  drv = name: derivation { inherit name; system = "x86_64-linux"; builder = "/bin/sh"; };
in {
  top = drv "top";
  recursing = { recurseForDerivations = true; inner = drv "inner"; };
  opaque = { hidden = drv "hidden"; };
  broken = throw "boom";
  notADrv = { a = 1; };
  multi = derivation {
    name = "multi";
    system = "x86_64-linux";
    builder = "/bin/sh";
    outputs = [ "out" "dev" ];
  };
}
EOF

out=$($FIX eval-jobs "$d/jobs.nix" 2>/dev/null)
code=$?

# jq is not a dependency of this suite; python3 already is (see flake.sh).
field() { # field <attr> <key>
    python3 -c '
import json,sys
attr,key=sys.argv[1],sys.argv[2]
for line in sys.stdin:
    if not line.strip(): continue
    d=json.loads(line)
    if d.get("attr")==attr:
        v=d.get(key)
        print("" if v is None else (json.dumps(v) if not isinstance(v,str) else v))
        break
' "$1" "$2" <<<"$out"
}
attrs() { python3 -c '
import json,sys
print(",".join(sorted(json.loads(l)["attr"] for l in sys.stdin if l.strip())))
' <<<"$out"; }

# --- discovery ---------------------------------------------------------------
t "walks top-level derivations" "top" "$(attrs)"
t "descends recurseForDerivations" "recursing.inner" "$(attrs)"
t_absent "does not descend opaque attrsets" "opaque.hidden" "$(attrs)"
t_absent "skips plain attrsets silently" "notADrv" "$(attrs)"

# --- record shape ------------------------------------------------------------
t "name is the derivation name" "top" "$(field top name)"
t "system is reported" "x86_64-linux" "$(field top system)"
t "drvPath is a store .drv" ".drv" "$(field top drvPath)"
t "outputs maps out to a store path" "/nix/store/" "$(field top outputs)"
t "attrPath is a list" '["recursing", "inner"]' "$(field recursing.inner attrPath)"
t "multiple outputs are all listed" '"dev"' "$(field multi outputs)"

# `system` is the system the derivation is BUILT for (its drvAttrs.system), not
# the package set's own `.system` attribute. They differ for a cross stdenv, and
# nix-eval-jobs reports the former — a pipeline routes builds by this field.
cat >"$d/cross.nix" <<'EOF'
{
  native = derivation { name = "native"; system = "x86_64-linux"; builder = "/bin/sh"; };
  # A cross-ish package: the attrset advertises one system, the derivation another.
  crossish = (derivation { name = "crossish"; system = "x86_64-linux"; builder = "/bin/sh"; })
    // { system = "aarch64-none"; };
}
EOF
cross=$($FIX eval-jobs "$d/cross.nix" 2>/dev/null)
crossfield() { python3 -c '
import json,sys
for l in sys.stdin:
    if not l.strip(): continue
    d=json.loads(l)
    if d.get("attr")==sys.argv[1]: print(d.get("system")); break
' "$1" <<<"$cross"; }
t "system for a native derivation" "x86_64-linux" "$(crossfield native)"
t "system comes from the derivation, not the attrset" "x86_64-linux" "$(crossfield crossish)"

# One JSON object per line, and every line is valid JSON.
ok_if "output is one JSON object per line" python3 -c '
import json,sys
lines=[l for l in sys.stdin.read().splitlines() if l.strip()]
assert lines, "no output"
for l in lines: json.loads(l)
' <<<"$out"

# --- failures are records, not aborts ----------------------------------------
t "failing attr becomes an error record" "boom" "$(field broken error)"
t_absent "error record carries no drvPath" '"drvPath"' "$(field broken drvPath)"
# nix-eval-jobs contract: per-attr errors are DATA (error records) and the
# process exits 0 — consumers (buildbot-nix, Hydra) scan the records. Only
# failing to evaluate at all (unreadable/unparseable input) exits nonzero.
if [[ $code -eq 0 ]]; then pass "attr failure still exits 0 (records are the signal)"; else fail "exit was $code despite per-attr isolation"; fi
$FIX eval-jobs "$d/does-not-exist.nix" >/dev/null 2>&1 && fail "unreadable input exited 0" || pass "unreadable input exits nonzero"
# The walk continues past the failure: `top` sorts after `broken`.
t "walk continues after a failure" "top" "$(attrs)"

# A clean tree exits 0.
cat >"$d/clean.nix" <<'EOF'
{ only = derivation { name = "only"; system = "x86_64-linux"; builder = "/bin/sh"; }; }
EOF
$FIX eval-jobs "$d/clean.nix" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then pass "clean tree exits 0"; else fail "clean tree exited nonzero"; fi

# --- --max-depth -------------------------------------------------------------
cat >"$d/deep.nix" <<'EOF'
{
  a = { recurseForDerivations = true;
    b = { recurseForDerivations = true;
      c = derivation { name = "deep"; system = "x86_64-linux"; builder = "/bin/sh"; }; }; };
}
EOF
deep=$($FIX eval-jobs "$d/deep.nix" 2>/dev/null)
t "reaches a nested derivation by default" "a.b.c" "$deep"
shallow=$($FIX eval-jobs --max-depth 2 "$d/deep.nix" 2>/dev/null)
t_absent "--max-depth stops the descent" "a.b.c" "$shallow"

# --- an empty tree is valid, not an error ------------------------------------
echo '{ }' >"$d/empty.nix"
empty=$($FIX eval-jobs "$d/empty.nix" 2>/dev/null)
code=$?
if [[ -z "${empty//[[:space:]]/}" && $code -eq 0 ]]; then
    pass "empty attrset yields no records and exits 0"
else
    fail "empty attrset: exit=$code out=$(printf '%q' "$empty")"
fi

# --- helper acceleration must not change what is emitted ----------------------
# The walk hands each level to the helpers before descending (`accelerateLevel`),
# so a level's derivations instantiate concurrently instead of one-at-a-time
# behind the sequential walk. That is guaranteed work, not speculation, so the
# output must be byte-identical to a solo run — and every attr must still be
# reached, in the same order, with the same drvPaths.
cat >"$d/many.nix" <<'EOF'
let
  mk = n: derivation {
    name = "p${toString n}";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ (toString n) ];
  };
  group = m: { recurseForDerivations = true; } //
    builtins.listToAttrs (map (i: { name = "d${toString i}"; value = mk (m * 100 + i); }) (builtins.genList (x: x) 12));
in {
  recurseForDerivations = true;
  g0 = group 0;
  g1 = group 1;
  g2 = group 2;
}
EOF
par=$($FIX eval-jobs --workers 8 "$d/many.nix" 2>/dev/null)
solo=$($FIX eval-jobs --workers 1 "$d/many.nix" 2>/dev/null)
if [[ "$par" == "$solo" ]]; then
    pass "accelerated walk matches a solo walk byte-for-byte"
else
    fail "accelerated walk diverged from solo ($(printf '%s' "$par" | wc -l) vs $(printf '%s' "$solo" | wc -l) records)"
fi
t "accelerated walk emits every attr" "36" "$(printf '%s\n' "$par" | grep -c '"drvPath"')"
# Repeat runs are stable: the fan-out must not reorder or drop records.
again=$($FIX eval-jobs --workers 8 "$d/many.nix" 2>/dev/null)
if [[ "$par" == "$again" ]]; then
    pass "accelerated walk is deterministic across runs"
else
    fail "accelerated walk varied between runs"
fi

# A top-level function whose formals have defaults is auto-called, as
# nix-eval-jobs and nix-instantiate treat a release expression. Regression:
# the lambda used to pass through unwrapped and walk as silently empty.
cat >"$d/funcroot.nix" <<'EOF'
{ label ? "auto" }:
{
  job = derivation {
    name = "func-${label}"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
  };
}
EOF
out=$($FIX eval-jobs "$d/funcroot.nix" 2>/dev/null)
t "function root is auto-called with defaults" '"func-auto"' "$out"
out=$($FIX eval-jobs --argstr label given "$d/funcroot.nix" 2>/dev/null)
t "function root honors --argstr over defaults" '"func-given"' "$out"

# Zero-formal formals lambdas auto-call too: `{}:` and `{...}:` are
# distinguishable from a plain `x:` lambda only by the lambda PATTERN.
printf '{ ... }: { a = derivation { name="ellipsis-root"; system=builtins.currentSystem; builder="/bin/sh"; }; }\n' >"$d/ellipsisroot.nix"
out=$($FIX eval-jobs "$d/ellipsisroot.nix" 2>/dev/null)
t "ellipsis-only function root auto-calls" '"ellipsis-root"' "$out"
printf '{}: { a = derivation { name="empty-formals-root"; system=builtins.currentSystem; builder="/bin/sh"; }; }\n' >"$d/emptyroot.nix"
out=$($FIX eval-jobs "$d/emptyroot.nix" 2>/dev/null)
t "empty-formals function root auto-calls" '"empty-formals-root"' "$out"
printf 'x: x\n' >"$d/plainroot.nix"
out=$($FIX eval-jobs "$d/plainroot.nix" 2>/dev/null)
t "plain lambda root is still an error record" 'top-level value is not an attribute set' "$out"

# Functions met DURING the walk auto-call like nix-eval-jobs: all-default
# formals evaluate and the result is walked; a defaultless formal is an
# error record; plain lambdas skip silently.
cat >"$d/fnattrs.nix" <<'EOF'
{
  recurseForDerivations = true;
  callme = { label ? "called" }: derivation {
    name = "fn-${label}"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
  };
  needsarg = { version }: derivation {
    name = "needs-${version}"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
  };
  plain = x: x;
}
EOF
fnout=$($FIX eval-jobs "$d/fnattrs.nix" 2>/dev/null)
t "all-default function attr evaluates" '"fn-called"' "$fnout"
t "defaultless formal is an error record" "argument without a value ('version')" "$fnout"
t_absent "plain lambda attr is skipped" '"plain"' "$fnout"

# A root that EXPLICITLY opts out with recurseForDerivations = false yields
# no jobs (nix-eval-jobs honors the attr even at the top level — nixpkgs
# scopes like python3Packages carry it); --force-recurse overrides.
cat >"$d/optout.nix" <<'EOF'
{
  recurseForDerivations = false;
  hidden = derivation { name = "optout"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ]; };
}
EOF
optout=$($FIX eval-jobs "$d/optout.nix" 2>/dev/null)
if [[ -z "${optout//[[:space:]]/}" ]]; then
    pass "root recurseForDerivations=false yields no jobs"
else
    fail "root opt-out was walked: $optout"
fi
t "--force-recurse overrides the root opt-out" '"optout"' "$($FIX eval-jobs --force-recurse "$d/optout.nix" 2>/dev/null)"

# A root that is no attrset at all is a usage error record, not silence.
echo '42' >"$d/notattrs.nix"
out=$($FIX eval-jobs "$d/notattrs.nix" 2>/dev/null || true)
t "non-attrset root emits an error record" '"error"' "$out"

# Non-identifier attr components are quoted in `attr` (nix-eval-jobs form:
# linuxKernel.packages."6.6"), so a consumer can feed it back to -A.
cat >"$d/quoted.nix" <<'EOF'
{
  recurseForDerivations = true;
  packages = {
    recurseForDerivations = true;
    "6.6" = derivation {
      name = "kern"; system = builtins.currentSystem;
      builder = "/bin/sh"; args = [ "-c" ": > $out" ];
    };
  };
}
EOF
out=$($FIX eval-jobs "$d/quoted.nix" 2>/dev/null)
t "non-identifier attr component is quoted" 'packages.\"6.6\"' "$out"
t "attrPath list keeps the raw component" '"packages","6.6"' "$out"

# Recursion is unbounded by default (nix-eval-jobs has no depth cap): a
# 12-deep recurse chain is fully walked without --max-depth.
python3 - "$d" <<'EOF'
import sys
open(sys.argv[1] + "/verydeep.nix", "w").write(
    "{\n" + "".join(
        'l%d = { recurseForDerivations = true;\n' % i for i in range(12)
    ) + 'leaf = derivation { name = "deepleaf"; system = builtins.currentSystem;'
        ' builder = "/bin/sh"; args = [ "-c" ": > $out" ]; };\n'
    + "};\n" * 12 + "}\n")
EOF
out=$($FIX eval-jobs "$d/verydeep.nix" 2>/dev/null)
t "recursion has no default depth cap" '"deepleaf"' "$out"

# --force-recurse descends into sets without recurseForDerivations.
cat >"$d/notrecurse.nix" <<'EOF'
{ hidden = { inner = derivation {
    name = "forced-vis"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
  }; };
}
EOF
t_absent "unmarked set is skipped by default" "forced-vis" "$($FIX eval-jobs "$d/notrecurse.nix" 2>/dev/null)"
t "--force-recurse reaches unmarked sets" "forced-vis" "$($FIX eval-jobs --force-recurse "$d/notrecurse.nix" 2>/dev/null)"

# --meta embeds the meta attrset as structured JSON.
cat >"$d/withmeta.nix" <<'EOF'
{ pkg = (derivation {
    name = "metapkg"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
  }) // { meta = { description = "has meta"; priority = 5; }; };
}
EOF
t_absent "meta omitted without --meta" '"description"' "$($FIX eval-jobs "$d/withmeta.nix" 2>/dev/null)"
withmeta=$($FIX eval-jobs --meta "$d/withmeta.nix" 2>/dev/null)
t "--meta embeds description" '"description":"has meta"' "$withmeta"
t "--meta embeds numbers" '"priority":5' "$withmeta"

# --apply embeds a per-derivation function result as extraValue; --select
# replaces the walked root; --no-instantiate skips store writes and GC roots
# while drvPaths stay identical.
applied=$($FIX eval-jobs --apply 'drv: { n = drv.name; }' "$d/withmeta.nix" 2>/dev/null)
t "--apply embeds extraValue" '"extraValue":{"n":"metapkg"}' "$applied"
selected=$($FIX eval-jobs --select 'root: { renamed = root.pkg; }' "$d/withmeta.nix" 2>/dev/null)
t "--select rewrites the walked root" '"attr":"renamed"' "$selected"
ni=$($FIX eval-jobs --no-instantiate "$d/withmeta.nix" 2>/dev/null)
wi=$($FIX eval-jobs "$d/withmeta.nix" 2>/dev/null)
ni_drv=$(printf '%s' "$ni" | sed -n 's/.*"drvPath":"\([^"]*\)".*/\1/p')
wi_drv=$(printf '%s' "$wi" | sed -n 's/.*"drvPath":"\([^"]*\)".*/\1/p')
t "--no-instantiate computes the same drvPath" "$wi_drv" "$ni_drv"
t_absent "--no-instantiate omits requiredSystemFeatures" 'requiredSystemFeatures' "$ni"
niroots=$(e2e_mktemp)
mkdir -p "$niroots"
$FIX eval-jobs --no-instantiate --gc-roots-dir "$niroots" "$d/withmeta.nix" >/dev/null 2>&1
if [[ -z "$(ls -A "$niroots")" ]]; then
    pass "--no-instantiate registers no GC roots"
else
    fail "--no-instantiate created GC roots: $(ls "$niroots")"
fi

# --max-memory-size recycles the evaluator when its heap exceeds the budget
# and resumes after the last emitted job. With a budget below the baseline
# heap it recycles constantly — the harshest schedule — and the output must
# STILL be byte-identical to an unlimited run, with no record duplicated or
# dropped, and exit 0.
unlimited=$($FIX eval-jobs --workers 2 "$d/many.nix" 2>/dev/null)
budgeted=$($FIX eval-jobs --workers 2 --max-memory-size 1 "$d/many.nix" 2>"$d/recycle.err")
if [[ "$unlimited" == "$budgeted" ]]; then
    pass "recycled walk output is byte-identical to unlimited"
else
    fail "recycled walk diverged ($(printf '%s\n' "$budgeted" | wc -l | tr -d ' ') vs $(printf '%s\n' "$unlimited" | wc -l | tr -d ' ') records)"
fi
t "recycling is reported on stderr" "recycling the evaluator" "$(cat "$d/recycle.err")"

# --gc-roots-dir drops a symlink per emitted .drv, named by drv basename.
roots=$(e2e_mktemp)
mkdir -p "$roots"
out=$($FIX eval-jobs --gc-roots-dir "$roots" "$d/quoted.nix" 2>/dev/null)
drv=$(printf '%s' "$out" | sed -n 's/.*"drvPath":"\([^"]*\)".*/\1/p' | head -1)
if [[ -n "$drv" && -L "$roots/$(basename "$drv")" ]]; then
    t "gc root links to the .drv" "$drv" "$(readlink "$roots/$(basename "$drv")")"
else
    fail "--gc-roots-dir created no symlink for $drv"
fi

# --show-input-drvs reports direct input derivations from the recorded drv.
cat >"$d/depjobs.nix" <<'EOF'
rec {
  dep = derivation { name = "dep"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ]; };
  consumer = derivation { name = "consumer"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ]; input = dep; };
}
EOF
depsout=$($FIX eval-jobs --show-input-drvs "$d/depjobs.nix" 2>/dev/null)
t "inputDrvs names the dependency drv" '-dep.drv":["out"]' "$depsout"
t "a leaf has empty inputDrvs" '"inputDrvs":{}' "$depsout"
t_absent "inputDrvs is opt-in" 'inputDrvs' "$($FIX eval-jobs "$d/depjobs.nix" 2>/dev/null)"

# --- scenarios adapted from Hydra's evaluator jobsets -------------------------
# Deep recurseForDerivations nesting, plus the classic flattening trap: the
# attrs `x.y` (nested) and `"x.y"` (literal dotted name) must stay distinct
# in `attr` — quoting is what disambiguates them.
cat >"$d/hydra-nested.nix" <<'EOF'
let
  drv = name: derivation { inherit name; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ]; };
in {
  x = { recurseForDerivations = true;
    y = { recurseForDerivations = true;
      z = { recurseForDerivations = true; deepest = drv "deepest"; }; }; };
  "x.y" = drv "literal-dotted";
}
EOF
nested=$($FIX eval-jobs "$d/hydra-nested.nix" 2>/dev/null)
t "three recurse levels reach the leaf" '"attr":"x.y.z.deepest"' "$nested"
t "a literal dotted name stays quoted and distinct" '"attr":"\"x.y\""' "$nested"
t "both jobs are emitted" "2" "$(printf '%s\n' "$nested" | grep -c '"drvPath"')"

# Rich meta shapes: mixed license forms (attrset + plain string in one list),
# and meta.outPath referencing the placeholder — serialization must not force
# it into a store path or crash.
cat >"$d/hydra-meta.nix" <<'EOF'
{
  pkg = (derivation {
    name = "metatrap"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
  }) // {
    meta = {
      license = [ { shortName = "gpl3"; fullName = "GNU GPL v3"; } "mit" ];
      maintainers = [ "someone" { name = "other"; email = "o@example.com"; } ];
      outPath = builtins.placeholder "out";
      priority = 9;
    };
  };
}
EOF
metatrap=$($FIX eval-jobs --meta "$d/hydra-meta.nix" 2>/dev/null)
t "mixed license list serializes" '"fullName":"GNU GPL v3"' "$metatrap"
t "plain-string license survives beside attrset" '"mit"' "$metatrap"
t "meta.outPath placeholder serializes as a string" '"outPath":"/' "$metatrap"
t "meta numbers serialize" '"priority":9' "$metatrap"

# --constituents: cycles and missing names resolve without a daemon (no
# rewrite happens on the error paths). The full rewrite path is covered by
# nix-eval-jobs' own suite in the harness (nej-tests).
cat >"$d/aggs.nix" <<'EOF'
rec {
  jobA = derivation { name = "jobA"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ]; };
  missing_agg = derivation {
    name = "missing_agg"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
    _hydraAggregate = true; constituents = [ "nope" "jobA" ];
  };
  cyc0 = derivation {
    name = "cyc0"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
    _hydraAggregate = true; constituents = [ "cyc1" ];
  };
  cyc1 = derivation {
    name = "cyc1"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
    _hydraAggregate = true; constituents = [ "cyc0" ];
  };
}
EOF
aggout=$($FIX eval-jobs --constituents "$d/aggs.nix" 2>/dev/null)
t "missing constituent is an error line" 'nope: does not exist' "$aggout"
t "resolvable constituents still resolve beside the error" '-jobA.drv' "$aggout"
cyccount=$(printf '%s
' "$aggout" | grep -c 'Dependency cycle: cyc0 <-> cyc1')
t "both cycle members carry the same diagnostic" "2" "$cyccount"
t "non-aggregate jobs still stream" '"attr":"jobA"' "$aggout"

# Regression: an aggregate REWRITE must survive --max-memory-size engine
# recycling. A 1 MiB budget recycles after every record, so the aggregate is
# walked in an earlier epoch than the one that rewrites it — the ATerm is
# captured at walk time (a stale engine's in-memory recipe graph is gone).
cat >"$d/agg-recycle.nix" <<'EOF'
rec {
  jobA = derivation { name = "jobA"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ]; };
  zagg = derivation {
    name = "zagg"; system = builtins.currentSystem;
    builder = "/bin/sh"; args = [ "-c" ": > $out" ];
    _hydraAggregate = true; constituents = [ "jobA" ];
  };
}
EOF
single=$($FIX eval-jobs --constituents "$d/agg-recycle.nix" 2>/dev/null | grep '"attr":"zagg"')
recycled=$($FIX eval-jobs --constituents --max-memory-size 1 "$d/agg-recycle.nix" 2>/dev/null | grep '"attr":"zagg"')
t "aggregate record survives engine recycling" '"attr":"zagg"' "$recycled"
# Cross-epoch resolution must not introduce failures single-epoch doesn't
# have (daemonless hosts fail the store write in BOTH; with a daemon both
# succeed — the container suite covers that leg).
t "recycled aggregate matches single-epoch byte-for-byte" "$single" "$recycled"
crossfail=$(printf '%s
' "$recycled" | grep -c 'UnknownInputDerivation\|no recorded derivation')
t "no cross-epoch-specific rewrite failure" "0" "$crossfail"

e2e_finish
