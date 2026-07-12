#!/usr/bin/env python3
"""Run the Lix and snix language conformance suites against `fix`.

Both upstream projects ship a corpus of tiny Nix programs plus golden output,
designed to pin down language semantics. We evaluate each program with
`fix eval` and diff against the golden file. The point is *conformance*: proof
that fix implements the Nix language the same way the reference evaluators do.

The corpora are pinned via npins (see ../../npins/sources.json) and resolved to
/nix/store paths on demand, so nothing third-party is vendored into the tree.

    lix   tests/functional2/lang/            (eval-okay / eval-fail runners)
    snix  contrib/nix-language-test-suite/   (.nix + .kdl + .exp/.err, cross-impl)

Every divergence from the reference evaluator is reported as a FAIL, and any
FAIL makes the run exit non-zero. There is deliberately no known-failures list:
the conformance gap is meant to be visible (a red run), not hidden. `skip` is
reserved for cases the harness genuinely cannot drive — ones needing a running
store/daemon or network, an unsupported flag/experimental-feature, or a special
fixture (device/fifo/socket) — not for language behavior fix gets wrong.

Usage:
    test/lang/run.py [--suite lix|snix|all] [--fix PATH] [-v] [--show-skips]
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LANG_DIR = Path(__file__).resolve().parent

# fix eval flags we know how to honor. Anything a test requires that is not in
# here (e.g. Lix's --no-location) makes the case a SKIP(unsupported-flag)
# rather than a spurious language FAIL.
SUPPORTED_FLAGS = {
    "-A", "--attr", "--arg", "--argstr", "--option",
    "-I", "--include", "--xml", "--json", "--strict",
    "--expr", "-e", "--file",
}
# Flags that are Lix/CppNix-specific knobs with no fix equivalent and no bearing
# on the value produced; drop them silently.
DROP_FLAGS_WITH_ARG = {"--extra-deprecated-features", "--deprecated-features"}
DROP_FLAGS_NO_ARG = {"--no-warning"}

# Experimental features fix implements (see `fix eval --help`). A test that
# requires anything else is skipped as unsupported rather than failed.
FIX_EXPERIMENTAL_FEATURES = {"pipe-operators", "fetch-tree", "flakes"}


class Colors:
    on = sys.stdout.isatty()
    def _c(code): return (lambda s: f"\033[{code}m{s}\033[0m" if Colors.on else s)
    green = staticmethod(_c("32"))
    red = staticmethod(_c("31"))
    yellow = staticmethod(_c("33"))
    dim = staticmethod(_c("2"))
    bold = staticmethod(_c("1"))


@dataclass
class Result:
    suite: str
    ident: str          # stable id, also the skip-list key
    status: str         # "pass" | "fail" | "skip"
    detail: str = ""    # diff / reason, for -v


# --------------------------------------------------------------------------
# pin resolution
# --------------------------------------------------------------------------

def pin_path(name: str) -> Path:
    """Resolve an npins pin to its /nix/store path (fetching if needed)."""
    expr = f"builtins.toString (import {REPO}/npins).{name}"
    p = subprocess.run(
        ["nix-instantiate", "--eval", "--expr", expr],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        sys.exit(f"failed to resolve pin {name!r}:\n{p.stderr}")
    return Path(p.stdout.strip().strip('"'))


# --------------------------------------------------------------------------
# fix invocation
# --------------------------------------------------------------------------

# A case that neither terminates nor errors within this many seconds is
# treated as a timeout (reported like a failure). Guards against a single
# pathological program wedging the whole run.
CASE_TIMEOUT_S = 10

# Cases are independent (each runs in its own temp dir), so fan them out.
import concurrent.futures
import multiprocessing

MAX_PARALLEL = min(16, (multiprocessing.cpu_count() or 4))


class TimedOut:
    """Stand-in for a CompletedProcess when fix wedges."""
    returncode = -1
    stdout = ""
    stderr = "fix timed out"


def run_fix(fix: Path, args: list[str], cwd: Path, env: dict | None = None):
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    # keep evaluation deterministic and quiet
    full_env.setdefault("NO_COLOR", "1")
    try:
        return subprocess.run(
            # --workers 1: these programs are tiny, so a per-process worker pool
            # is pure startup overhead — and we already fan out across cases.
            [str(fix), "eval", "--workers", "1", *args],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=str(cwd), env=full_env, timeout=CASE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return TimedOut()


def translate_flags(flags: list[str]) -> tuple[list[str], str | None]:
    """Map a reference-runner flag list onto fix's flags.

    Returns (fix_flags, skip_reason). skip_reason is set when the case needs a
    flag fix cannot honor, in which case fix_flags is meaningless.
    """
    out: list[str] = []
    i = 0
    while i < len(flags):
        f = flags[i]
        if f in DROP_FLAGS_WITH_ARG:
            i += 2
            continue
        if f in DROP_FLAGS_NO_ARG:
            i += 1
            continue
        if f in ("--extra-experimental-features", "--experimental-features"):
            # drop nix-command (not a fix concept); keep the language features
            # fix actually knows. A test that needs a feature fix doesn't
            # implement is skipped rather than counted as a language failure.
            vals = []
            for v in flags[i + 1].split():
                if v == "nix-command":
                    continue
                if v not in FIX_EXPERIMENTAL_FEATURES:
                    return out, f"unsupported-feature:{v}"
                vals.append(v)
            if vals:
                out += [f, " ".join(vals)]
            i += 2
            continue
        if f == "--no-location":
            return out, "unsupported-flag:--no-location"
        # values that follow a flag we pass through verbatim
        if f in ("-A", "--attr", "--option", "--arg", "--argstr", "-I", "--include"):
            n = 2 if f in ("--option", "--arg", "--argstr") else 1
            out += flags[i:i + 1 + n]
            i += 1 + n
            continue
        if f.startswith("-"):
            if f in SUPPORTED_FLAGS:
                out.append(f)
                i += 1
                continue
            return out, f"unsupported-flag:{f}"
        # bare positional inside flags (rare) — pass through
        out.append(f)
        i += 1
    return out, None


# --------------------------------------------------------------------------
# Lix functional2/lang runner
# --------------------------------------------------------------------------

RUNNERS = ("eval-okay", "eval-fail", "parse-okay", "parse-fail")
_RUNNER_RE = re.compile(rf"^(?P<runner>{'|'.join(RUNNERS)})(?P<suffix>-[\w-]+?)?$")


def _infile_suffix(in_name: str) -> str:
    m = re.fullmatch(r"in(-[\w-]+?)?\.nix", in_name)
    return (m.group(1) or "") if m else ""


@dataclass
class LixCase:
    case_dir: Path
    ident: str
    runner: str
    in_file: str
    test_name: str
    flags: list[str] = field(default_factory=list)
    extra_files: list[str] = field(default_factory=list)


def discover_lix_cases(lang_dir: Path):
    for case_dir in sorted(p for p in lang_dir.iterdir() if p.is_dir()):
        # a directory that is itself a python module is a pytest test, not a
        # declarative lang test.
        if any(case_dir.glob("*.py")):
            continue
        rel = case_dir.name
        toml = case_dir / "test.toml"
        if toml.exists():
            yield from _lix_toml_cases(case_dir, rel, toml)
        else:
            yield from _lix_simple_cases(case_dir, rel)


def _lix_simple_cases(case_dir: Path, rel: str):
    seen = set()
    for exp in sorted(list(case_dir.glob("*.out.exp")) + list(case_dir.glob("*.err.exp"))):
        stem = exp.name[:-len(".out.exp")] if exp.name.endswith(".out.exp") else exp.name[:-len(".err.exp")]
        m = _RUNNER_RE.match(stem)
        if not m:
            continue
        runner, suffix = m.group("runner"), (m.group("suffix") or "")
        if runner not in ("eval-okay", "eval-fail"):
            continue
        in_file = f"in{suffix}.nix"
        if not (case_dir / in_file).exists():
            continue
        test_name = f"{runner}{suffix}"
        if test_name in seen:
            continue
        seen.add(test_name)
        yield LixCase(case_dir, f"{rel}:{test_name}", runner, in_file, test_name)


def _lix_toml_cases(case_dir: Path, rel: str, toml: Path):
    try:
        spec = tomllib.loads(toml.read_text())
    except tomllib.TOMLDecodeError:
        return
    for entry in spec.get("test", []):
        runner = entry.get("runner")
        if runner not in ("eval-okay", "eval-fail"):
            continue
        base_name = entry.get("name", runner)
        flags = list(entry.get("flags", []))
        extra = list(entry.get("extra-files", []))
        matrix = entry.get("matrix", False)
        in_spec = entry.get("in")
        if matrix:
            if in_spec is None:
                in_files = sorted(p.name for p in case_dir.glob("in*.nix"))
            else:
                in_files = in_spec if isinstance(in_spec, list) else [in_spec]
        else:
            in_files = [in_spec if isinstance(in_spec, str) else "in.nix"]
        for in_file in in_files:
            if not (case_dir / in_file).exists():
                continue
            suffix = _infile_suffix(in_file)
            test_name = f"{base_name}{suffix}"
            yield LixCase(case_dir, f"{rel}:{test_name}", runner, in_file, test_name, flags, extra)


def run_lix_case(fix: Path, lang_dir: Path, c: LixCase) -> Result:
    fix_flags, skip = translate_flags(c.flags)
    if skip:
        return Result("lix", c.ident, "skip", skip)
    with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
        tmp = Path(td)
        shutil.copy(c.case_dir / c.in_file, tmp / "in.nix")
        lib = lang_dir / "lib.nix"
        if lib.exists():
            shutil.copy(lib, tmp / "lib.nix")
        for extra in c.extra_files:
            src = c.case_dir / extra
            if src.exists():
                shutil.copy(src, tmp / Path(extra).name)
        # the reference eval runner always evaluates --strict and with the
        # flakes xp feature enabled (nix fixture flake=True).
        args = ["--strict", "--extra-experimental-features", "flakes", *fix_flags, "in.nix"]
        p = run_fix(fix, args, tmp)
        out = p.stdout.replace(str(tmp), "/pwd")

        if c.runner == "eval-fail":
            if p.returncode == -1:
                return Result("lix", c.ident, "fail", "expected evaluation to fail, but fix hung (timeout)")
            if p.returncode != 0:
                return Result("lix", c.ident, "pass")
            return Result("lix", c.ident, "fail", "expected evaluation to fail, but it succeeded")

        exp_file = c.case_dir / f"{c.test_name}.out.exp"
        expected = exp_file.read_text() if exp_file.exists() else ""
        if p.returncode != 0:
            return Result("lix", c.ident, "fail", f"eval failed:\n{_indent(p.stderr.strip())}")
        if out.strip() == expected.strip():
            return Result("lix", c.ident, "pass")
        return Result("lix", c.ident, "fail", _diff(expected, out))


# --------------------------------------------------------------------------
# snix nix-language-test-suite runner
# --------------------------------------------------------------------------

# error-kind -> substrings fix's stderr must contain (modern CppNix / Lix
# phrasings, matching the reference cppnix runner's CppNixLatest/LixLatest arms)
ERROR_KINDS = {
    "NotCoercibleToString": ["cannot coerce"],
    "IO": ["does not exist", "No such file or directory", "has an unsupported type"],
    "TypeError": ["requires a function", "expected a", "was expected"],
    "InvalidHash": ["invalid SRI hash", "invalid hash"],
    "InvalidStorePath": ["is not a valid store path", "store path"],
    "HashMismatch": ["store path mismatch", "hash mismatch"],
    "DerivationError": ["invalid derivation name", "should have type",
                        "duplicate derivation output", "cannot process __json"],
    "UnexpectedArgument": ["unsupported argument", "unexpected argument"],
    "VariableAlreadyDefined": ["already defined"],
    "DuplicateAttrsKey": ["already defined", "duplicate"],
}


@dataclass
class KdlNode:
    name: str
    args: list[str] = field(default_factory=list)
    props: dict[str, str] = field(default_factory=dict)
    children: list["KdlNode"] = field(default_factory=list)


def parse_kdl(text: str) -> list[KdlNode]:
    """Minimal KDL reader covering the subset the suite uses: nodes with
    string/bareword args, key="val" properties, `{...}` children, `//` and
    `/* */` comments and `\\` line continuations."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    lines = []
    for line in text.splitlines():
        line = re.sub(r"//.*$", "", line)
        lines.append(line)
    # join line-continuations
    joined = re.sub(r"\\\s*\n", " ", "\n".join(lines))
    toks = _kdl_tokens(joined)
    pos = 0

    def parse_nodes(depth: int):
        nonlocal pos
        nodes = []
        while pos < len(toks):
            t = toks[pos]
            if t == "}":
                if depth == 0:
                    pos += 1
                    continue
                pos += 1
                return nodes
            if t in (";", "\n"):
                pos += 1
                continue
            if t == "{":
                pos += 1  # stray
                continue
            # node name
            name = _kdl_unquote(t)
            pos += 1
            node = KdlNode(name)
            while pos < len(toks) and toks[pos] not in ("{", "}", "\n", ";"):
                tk = toks[pos]
                if "=" in tk and not tk.startswith('"'):
                    k, _, v = tk.partition("=")
                    node.props[k] = _kdl_unquote(v)
                else:
                    node.args.append(_kdl_unquote(tk))
                pos += 1
            if pos < len(toks) and toks[pos] == "{":
                pos += 1
                node.children = parse_nodes(depth + 1)
            nodes.append(node)
        return nodes

    return parse_nodes(0)


def _kdl_tokens(s: str) -> list[str]:
    toks, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in " \t\r":
            i += 1
        elif c == "\n":
            toks.append("\n")
            i += 1
        elif c in "{};":
            toks.append(c)
            i += 1
        elif c == '"':
            j = i + 1
            buf = ['"']
            while j < n and s[j] != '"':
                if s[j] == "\\":
                    buf.append(s[j:j + 2]); j += 2; continue
                buf.append(s[j]); j += 1
            buf.append('"'); j += 1
            toks.append("".join(buf))
            i = j
        else:
            j = i
            while j < n and s[j] not in ' \t\r\n{};':
                # a property value may itself be quoted: key="a b"
                if s[j] == '"':
                    j += 1
                    while j < n and s[j] != '"':
                        j += 1
                j += 1
            toks.append(s[i:j])
            i = j
    return toks


def _kdl_unquote(t: str) -> str:
    if t.startswith('"') and t.endswith('"') and len(t) >= 2:
        return bytes(t[1:-1], "utf-8").decode("unicode_escape")
    return t


@dataclass
class SnixCase:
    kdl: Path
    ident: str
    eval_strict: bool = False
    xml_output: bool = False
    search_path: list[str] = field(default_factory=list)
    features: set[str] = field(default_factory=set)
    work_dir: str | None = None
    env_vars: list[tuple[str, str]] = field(default_factory=list)
    network: bool = False
    nix_store: bool = False
    fixtures: list[KdlNode] = field(default_factory=list)
    unsupported: str | None = None


def load_snix_case(kdl_path: Path, cases_root: Path) -> SnixCase:
    ident = str(kdl_path.relative_to(cases_root).with_suffix(""))
    nodes = parse_kdl(kdl_path.read_text())
    c = SnixCase(kdl_path, ident)
    for node in nodes:
        if node.name == "runtime-opts":
            for ch in node.children:
                if ch.name == "eval-strict":
                    c.eval_strict = True
                elif ch.name == "xml-output":
                    c.xml_output = True
                elif ch.name == "search-path":
                    c.search_path += ch.args
        elif node.name == "lang":
            for ch in node.children:
                if ch.name == "features":
                    c.features |= set(ch.args)
        elif node.name == "environment":
            for ch in node.children:
                if ch.name == "work-dir":
                    c.work_dir = ch.args[0] if ch.args else None
                elif ch.name == "env-var" and len(ch.args) >= 2:
                    c.env_vars.append((ch.args[0], ch.args[1]))
                elif ch.name == "network":
                    c.network = True
                elif ch.name == "nix-store":
                    c.nix_store = True
                elif ch.name == "fixtures":
                    c.fixtures = ch.children
    return c


def _materialize_fixtures(fixtures: list[KdlNode], case_dir: Path, dest: Path,
                          omitted: list[str] | None = None) -> str | None:
    """Create the declared fixture tree under `dest`.

    Returns a hard skip-reason string when a fixture the harness cannot make at
    all is required. Device nodes (char/block/device) that need root but that we
    couldn't create are recorded in `omitted` and *skipped* rather than
    hard-failing: the caller downgrades an inconclusive run to a skip (never a
    false pass/fail) so a test whose device node turns out not to be load-
    bearing (e.g. the filter excludes it) can still run and pass.
    """
    if omitted is None:
        omitted = []
    for fx in fixtures:
        if fx.name == "file":
            target = dest / fx.args[0]
            target.parent.mkdir(parents=True, exist_ok=True)
            if "content" in fx.props:
                target.write_text(fx.props["content"])
            elif "ref" in fx.props:
                shutil.copy(case_dir / fx.props["ref"], target)
            else:
                target.write_text("")
        elif fx.name == "dir":
            target = dest / fx.args[0]
            if "ref" in fx.props:
                shutil.copytree(case_dir / fx.props["ref"], target, dirs_exist_ok=True)
            else:
                target.mkdir(parents=True, exist_ok=True)
                err = _materialize_fixtures(fx.children, case_dir, target, omitted)
                if err:
                    return err
        elif fx.name == "symlink":
            (dest / fx.args[0]).parent.mkdir(parents=True, exist_ok=True)
            os.symlink(fx.props.get("target", ""), dest / fx.args[0])
        elif fx.name == "fifo":
            # A named pipe: creatable unprivileged with mkfifo(2). fix's NAR
            # ingestion must reject it (unsupported type) unless the filter
            # excludes it — that's exactly what these cases pin down.
            target = dest / fx.args[0]
            target.parent.mkdir(parents=True, exist_ok=True)
            os.mkfifo(target)
        elif fx.name == "socket":
            # A unix-domain socket file: creatable unprivileged by binding an
            # AF_UNIX socket to the path. The bound inode persists after the
            # socket object is closed (it is only removed by unlink), so the
            # fixture is a real socket node on disk.
            target = dest / fx.args[0]
            target.parent.mkdir(parents=True, exist_ok=True)
            s = socket.socket(socket.AF_UNIX)
            try:
                s.bind(str(target))
            finally:
                s.close()
        elif fx.name in ("char", "block", "device"):
            # Character / block device nodes. `mknod(2)` for a device needs
            # CAP_MKNOD (root), so we can only make these when running
            # privileged. A `device` fixture naming an already-present node
            # (e.g. /dev/null, referenced absolutely by the .nix) needs no
            # creation at all — that case runs unprivileged.
            target = dest / fx.args[0]
            if target.exists():
                continue
            fmt = stat.S_IFBLK if fx.name == "block" else stat.S_IFCHR
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                os.mknod(target, fmt | 0o600, os.makedev(1, 3))
            except (PermissionError, OSError):
                # Unprivileged: can't mknod. Record it and press on — if the
                # node is load-bearing the run will be inconclusive and the
                # caller downgrades it to a skip; if not (filtered out), the
                # run still matches golden and passes.
                omitted.append(fx.name)
                continue
        else:
            return f"unsupported-fixture:{fx.name}"
    return None


def snix_flags(c: SnixCase) -> tuple[list[str], str | None]:
    flags: list[str] = []
    if c.eval_strict:
        flags.append("--strict")
    if c.xml_output:
        # reference runner passes --no-location --xml; fix has no --no-location
        return flags, "unsupported-flag:--no-location(xml)"
    for p in c.search_path:
        flags += ["--include", p]
    feats = []
    if "flakes" in c.features:
        feats.append("flakes")
    if "pipe-operators" in c.features:
        feats.append("pipe-operators")
    if feats:
        flags += ["--extra-experimental-features", " ".join(feats)]
    return flags, None


def run_snix_case(fix: Path, c: SnixCase) -> Result:
    if c.network or c.nix_store:
        return Result("snix", c.ident, "skip", "needs-network-or-store")
    flags, skip = snix_flags(c)
    if skip:
        return Result("snix", c.ident, "skip", skip)

    exp = c.kdl.with_suffix(".exp")
    err = c.kdl.with_suffix(".err")
    nix_src = c.kdl.with_suffix(".nix")
    if not nix_src.exists():
        return Result("snix", c.ident, "skip", "no .nix input")

    with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
        tmp = Path(td)
        omitted: list[str] = []
        fxerr = _materialize_fixtures(c.fixtures, c.kdl.parent, tmp, omitted)
        if fxerr:
            return Result("snix", c.ident, "skip", fxerr)
        code_path = tmp / nix_src.name
        shutil.copy(nix_src, code_path)
        env = {name: val for name, val in c.env_vars}
        p = run_fix(fix, [*flags, code_path.name], tmp, env)

        # A privileged device node we couldn't create makes any non-pass
        # inconclusive rather than a real divergence — downgrade to a skip so
        # we never report a false failure for something we couldn't set up.
        def fail(detail: str) -> Result:
            if omitted:
                return Result("snix", c.ident, "skip", f"unsupported-fixture:{omitted[0]}")
            return Result("snix", c.ident, "fail", detail)

        if err.exists():
            kind = err.read_text().strip()
            subs = ERROR_KINDS.get(kind, [])
            ok = p.returncode != 0 and any(s in p.stderr for s in subs)
            if ok:
                return Result("snix", c.ident, "pass")
            return fail(f"expected error kind {kind} (one of {subs}); rc={p.returncode}\n{_indent(p.stderr.strip())}")

        expected = exp.read_text() if exp.exists() else ""
        out = p.stdout
        if c.work_dir:
            out = out.replace(str(tmp), c.work_dir)
        for name, val in c.env_vars:
            if name == "HOME":
                out = out.replace(os.path.expanduser("~"), val)
        if p.returncode != 0:
            return fail(f"eval failed:\n{_indent(p.stderr.strip())}")
        if out.strip() == expected.strip():
            return Result("snix", c.ident, "pass")
        return fail(_diff(expected, out))


# --------------------------------------------------------------------------
# reporting / skip handling
# --------------------------------------------------------------------------

def _indent(s: str, p: str = "    ") -> str:
    return "\n".join(p + line for line in s.splitlines())


def _diff(expected: str, actual: str) -> str:
    return (f"  expected: {expected.strip()!r}\n"
            f"  actual:   {actual.strip()!r}")


def _progress(suite: str, i: int, total: int, n_pass: int, n_fail: int):
    """Live one-line progress to stderr so long runs are followable."""
    msg = f"[{suite}] {i}/{total}  {n_pass} pass  {n_fail} fail"
    if sys.stderr.isatty():
        sys.stderr.write("\r\033[K" + msg)
    else:
        # non-tty (redirected to a file): emit a line every 20 cases + at the end
        if i % 20 == 0 or i == total:
            sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def run_suite(name: str, fix: Path):
    if name == "lix":
        lang_dir = pin_path("lix") / "tests/functional2/lang"
        cases = list(discover_lix_cases(lang_dir))
        runner = lambda c: run_lix_case(fix, lang_dir, c)
    elif name == "snix":
        cases_root = pin_path("snix") / "contrib/nix-language-test-suite/tests/cases"
        cases = [load_snix_case(kdl, cases_root) for kdl in sorted(cases_root.rglob("*.kdl"))]
        runner = lambda c: run_snix_case(fix, c)
    else:
        return []

    total = len(cases)
    results: list[Result] = [None] * total
    done = n_pass = n_fail = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_PARALLEL) as pool:
        futs = {pool.submit(runner, c): idx for idx, c in enumerate(cases)}
        for fut in concurrent.futures.as_completed(futs):
            idx = futs[fut]
            r = fut.result()
            results[idx] = r
            done += 1
            if r.status == "pass":
                n_pass += 1
            elif r.status == "fail":
                n_fail += 1
            _progress(name, done, total, n_pass, n_fail)
    if sys.stderr.isatty():
        sys.stderr.write("\n")
        sys.stderr.flush()
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", choices=["lix", "snix", "all"], default="all")
    ap.add_argument("--fix", default=str(REPO / "zig-out/bin/fix"), help="path to the fix binary")
    ap.add_argument("-v", "--verbose", action="store_true", help="show diffs for failures")
    ap.add_argument("--show-skips", action="store_true",
                    help="also list cases the harness couldn't drive (needs a store, an "
                         "unsupported flag/feature, or a special fixture)")
    args = ap.parse_args()

    fix = Path(args.fix)
    if not fix.exists():
        sys.exit(f"fix binary not found at {fix} (build with `zig build`)")

    suites = ["lix", "snix"] if args.suite == "all" else [args.suite]

    total_fail = 0
    for suite in suites:
        results = run_suite(suite, fix)
        fails = [r for r in results if r.status == "fail"]
        skips = [r for r in results if r.status == "skip"]
        n_pass = sum(1 for r in results if r.status == "pass")

        head = Colors.bold(f"[{suite}]")
        print(f"{head} {Colors.green(str(n_pass) + ' pass')}, "
              f"{Colors.red(str(len(fails)) + ' fail')}, "
              f"{Colors.yellow(str(len(skips)) + ' skip')}")

        # A flat list of every divergence — the point of this suite is to show,
        # honestly, where fix does not yet match the reference evaluator.
        for r in sorted(fails, key=lambda r: r.ident):
            print(f"  {Colors.red('FAIL')} {r.ident}")
            if args.verbose and r.detail:
                print(_indent(r.detail, "      "))
        if args.show_skips:
            for r in sorted(skips, key=lambda r: r.ident):
                print(f"  {Colors.dim('SKIP')} {r.ident} {Colors.dim('(' + r.detail + ')')}")

        total_fail += len(fails)

    # Non-zero while any case diverges: the conformance gap is a red build, not
    # something a skip list papers over.
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
