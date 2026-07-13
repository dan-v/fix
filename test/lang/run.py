#!/usr/bin/env python3
"""Run the Lix and snix language conformance suites against `fix`.

Both upstream projects ship a corpus of tiny Nix programs plus golden output,
designed to pin down language semantics. We drive each program through `fix`
and diff against the golden file. The point is *conformance*: proof that fix
implements the Nix language the same way the reference evaluators do.

The corpora are pinned via npins (see ../../npins/sources.json) and resolved to
/nix/store paths on demand, so nothing third-party is vendored into the tree.

    lix   tests/functional2/lang/            (eval + parse runners + 7 python
                                              custom adapters, driven explicitly)
    snix  contrib/nix-language-test-suite/   (.nix + .kdl + .exp/.err, cross-impl)

This is a complete, no-skip inventory. Every case is ATTEMPTED. A case is one of:

    pass      fix matches the reference evaluator.
    fail      a real conformance gap OR an undrivable/malformed case (unsupported
              flag/feature, missing fixture/golden, launch failure, translation
              failure, parse-fail error-text parity we do not reproduce, ...).
              Any fail makes the whole run exit non-zero.
    blocked   the case's EXTERNAL dependency is provably absent: no nix-daemon /
              store, or no rootless user+mount namespace / system device for a
              device fixture. Printed always, NEVER counted as a pass, and does
              NOT fail the build (there is nothing fix could do about it here).

There is deliberately no known-failures list and no `skip`: the conformance gap
is meant to be visible (a red run), not hidden.

Usage:
    test/lang/run.py [--suite lix|snix|all] [--fix PATH] [-v]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import multiprocessing
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LANG_DIR = Path(__file__).resolve().parent

# fix eval flags we know how to honor. Anything a declarative case requires that
# is not here makes translation FAIL (a visible conformance gap), never a skip.
SUPPORTED_FLAGS = {
    "-A", "--attr", "--arg", "--argstr", "--option",
    "-I", "--include", "--xml", "--json", "--strict", "--no-location",
    "--expr", "-e", "--file", "--show-trace",
}
DROP_FLAGS_NO_ARG = {"--no-warning"}

# Experimental features fix implements (it is lenient and accepts these). A test
# that needs anything else is a translation FAIL, not a skip.
FIX_EXPERIMENTAL_FEATURES = {"pipe-operators", "fetch-tree", "flakes", "coerce-integers"}

# The nix-daemon socket `fix` connects to for real store ops. When it exists,
# `nix-store` snix cases can actually run; otherwise they are BLOCKED.
NIX_DAEMON_SOCKET = os.environ.get(
    "NIX_DAEMON_SOCKET", "/nix/var/nix/daemon-socket/socket"
)

# A case that neither terminates nor errors within this many seconds is treated
# as a timeout (a failure). Guards against a pathological program wedging the run.
CASE_TIMEOUT_S = 10

MAX_PARALLEL = min(16, (multiprocessing.cpu_count() or 4))

RUNNERS = ("eval-okay", "eval-fail", "parse-okay", "parse-fail")
_NAME_RE = re.compile(r"(eval-okay|eval-fail|parse-okay|parse-fail)(-[\w-]+?)?$")
_INFILE_RE = re.compile(r"in(-[\w-]+?)?\.nix$")

# The 7 python-backed Lix dirs, driven as explicit fix adapters below (we do NOT
# run upstream pytest). The names are asserted by the inventory tests, so a pin
# that adds/removes one fails inventory loudly.
CUSTOM_DIRS = {
    "builtins.getEnv", "builtins.pathExists", "builtins.readDir",
    "builtins.readFileType", "err_context", "parser-token-whitespace",
    "search-path",
}


def _store_available() -> bool:
    """A usable nix store/daemon for the `nix-store` cases: the daemon socket
    exists, or we are in single-user mode with a writable store."""
    try:
        import stat as _stat

        if _stat.S_ISSOCK(os.stat(NIX_DAEMON_SOCKET).st_mode):
            return True
    except OSError:
        pass
    return os.path.isdir("/nix/store") and os.access("/nix/store", os.W_OK)


class Colors:
    on = sys.stdout.isatty()
    def _c(code): return (lambda s: f"\033[{code}m{s}\033[0m" if Colors.on else s)
    green = staticmethod(_c("32"))
    red = staticmethod(_c("31"))
    yellow = staticmethod(_c("33"))
    blue = staticmethod(_c("34"))
    dim = staticmethod(_c("2"))
    bold = staticmethod(_c("1"))


@dataclass
class Result:
    suite: str
    ident: str          # stable id
    status: str         # "pass" | "fail" | "blocked"
    detail: str = ""    # diff / reason, for -v and always for blocked


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

class TimedOut:
    """Stand-in for a CompletedProcess when fix wedges or cannot be launched."""
    def __init__(self, stderr: str = "fix timed out"):
        self.returncode = -1
        self.stdout = ""
        self.stderr = stderr


def run_fix(fix: Path, args: list[str], cwd: Path, env: dict | None = None,
            devices: list[str] | None = None,
            subcmd: tuple[str, ...] = ("eval", "--workers", "1")):
    """Launch `fix <subcmd> [args]` in its own process group and collect output.

    On timeout the whole group is SIGTERM'd, given a grace period, then SIGKILL'd
    and reaped, so a wedged child (or a namespace helper) can never leak."""
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    full_env.setdefault("NO_COLOR", "1")
    fix_cmd = [str(fix), *subcmd, *args]
    if devices:
        # A case needs genuine device nodes (char/block/device fixtures) that
        # can't be created unprivileged. Run fix inside a rootless user+mount
        # namespace and bind-mount /dev/null — a real character special file —
        # onto each fixture path first, so fix's NAR ingestion hits the honest
        # "unsupported file type" path on a real device inode. A fresh mount
        # namespace copies current mounts, so /nix/store, tmp and HOME stay
        # visible; the bind-mount only overlays the fixture path.
        inner = "".join(f"mount --bind /dev/null {shlex.quote(t)} && " for t in devices)
        inner += "exec " + " ".join(shlex.quote(a) for a in fix_cmd)
        cmd = ["unshare", "--map-root-user", "--user", "--mount", "sh", "-c", inner]
    else:
        cmd = fix_cmd
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace",
            cwd=str(cwd), env=full_env, start_new_session=True,
        )
    except (FileNotFoundError, OSError) as e:
        return TimedOut(f"failed to launch fix: {e}")
    try:
        out, err = proc.communicate(timeout=CASE_TIMEOUT_S)
        return subprocess.CompletedProcess(cmd, proc.returncode, out, err)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            proc.wait()
        return TimedOut()


# Device-node fixtures are presented via a bind-mount of /dev/null inside a
# rootless user+mount namespace (see run_fix). Some kernels disable unprivileged
# user namespaces, so probe the mechanism once and BLOCK the case if unavailable
# — never a false pass/fail.
_userns_lock = threading.Lock()
_userns_ok: bool | None = None


def userns_available() -> bool:
    global _userns_ok
    with _userns_lock:
        if _userns_ok is None:
            _userns_ok = _probe_userns()
        return _userns_ok


def _probe_userns() -> bool:
    try:
        with tempfile.TemporaryDirectory(prefix="fixlang-userns-") as td:
            mp = os.path.join(td, "probe")
            open(mp, "w").close()
            r = subprocess.run(
                ["unshare", "--map-root-user", "--user", "--mount", "sh", "-c",
                 f"mount --bind /dev/null {shlex.quote(mp)} && [ -c {shlex.quote(mp)} ]"],
                capture_output=True, timeout=CASE_TIMEOUT_S,
            )
            return r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False


def translate_flags(flags: list[str]) -> tuple[list[str], str | None]:
    """Map a reference-runner flag list onto fix's flags.

    Returns (fix_flags, error). error is set when the case needs a flag/feature
    fix cannot honor — that is a visible conformance FAIL, not a skip."""
    out: list[str] = []
    i = 0
    while i < len(flags):
        f = flags[i]
        if f in ("--extra-deprecated-features", "--deprecated-features"):
            # fix accepts the whole Lix deprecated-feature set leniently.
            out += [f, flags[i + 1]]
            i += 2
            continue
        if f in DROP_FLAGS_NO_ARG:
            i += 1
            continue
        if f in ("--extra-experimental-features", "--experimental-features"):
            vals = []
            for v in flags[i + 1].split():
                if v == "nix-command":
                    continue  # not a fix concept
                if v not in FIX_EXPERIMENTAL_FEATURES:
                    return out, f"unsupported-feature:{v}"
                vals.append(v)
            if vals:
                out += [f, " ".join(vals)]
            i += 2
            continue
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
        out.append(f)
        i += 1
    return out, None


# --------------------------------------------------------------------------
# Lix functional2/lang: declarative discovery (eval + parse)
# --------------------------------------------------------------------------

def _infile_suffix(in_name: str) -> str:
    m = _INFILE_RE.fullmatch(in_name)
    return (m.group(1) or "") if m else ""


@dataclass
class LixCase:
    case_dir: Path
    ident: str
    runner: str
    in_file: str = "in.nix"
    test_name: str = ""
    flags: list = field(default_factory=list)
    extra_files: list = field(default_factory=list)
    global_assets: list = field(default_factory=list)
    handler: object = None      # custom adapters set a run(fix) -> Result closure


_TOML_TEST_KEYS = {"runner", "name", "flags", "extra-files", "global-assets", "matrix", "in"}


def discover_lix_cases(lang_dir: Path):
    """Yield every Lix case: declarative eval + parse, and the 7 python-backed
    custom dirs (driven as explicit adapters). Raises ValueError on a malformed
    declarative manifest so corpus drift fails inventory rather than hiding."""
    for case_dir in sorted(p for p in lang_dir.iterdir() if p.is_dir()):
        name = case_dir.name
        # `assets` is shared fixtures, not a case; skip a stray __pycache__ too.
        # (A single `__functor` case dir IS a real declarative case and is kept.)
        if name in ("assets", "__pycache__"):
            continue
        if any(case_dir.glob("*.py")):
            yield from _custom_cases(case_dir)
            continue
        toml = case_dir / "test.toml"
        if toml.exists():
            yield from _lix_toml_cases(case_dir, name, toml)
        else:
            yield from _lix_simple_cases(case_dir, name)


def _lix_simple_cases(case_dir: Path, rel: str):
    all_files = {f.name for f in case_dir.iterdir() if not f.name.startswith("_")}
    used: set[str] = set()
    collected: set[str] = set()
    cases: list[LixCase] = []
    for f in sorted(all_files):
        if not f.endswith(".exp"):
            continue
        used.add(f)
        stem = f.rsplit(".", 2)[0]
        m = _NAME_RE.fullmatch(stem)
        if m is None:
            raise ValueError(f"{rel}: malformed test name {stem!r} for {f!r}")
        if stem in collected:
            continue
        collected.add(stem)
        runner, suffix = m.group(1), (m.group(2) or "")
        in_file = f"in{suffix}.nix"
        if not (case_dir / in_file).exists():
            raise ValueError(f"{rel}: missing input {in_file!r} for {stem!r}")
        if runner in ("eval-okay", "parse-okay") and not (case_dir / f"{stem}.out.exp").exists():
            raise ValueError(f"{rel}: missing expected golden {stem}.out.exp")
        used.add(in_file)
        cases.append(LixCase(case_dir, f"{rel}:{stem}", runner, in_file, stem))
    leftover = all_files - used
    if leftover:
        raise ValueError(f"{rel}: unreferenced files {sorted(leftover)}")
    yield from cases


def _lix_toml_cases(case_dir: Path, rel: str, toml: Path):
    spec = tomllib.loads(toml.read_text())  # TOMLDecodeError propagates
    extra_top = set(spec) - {"test"}
    if extra_top:
        raise ValueError(f"{rel}: unexpected top-level keys {sorted(extra_top)}")
    entries = spec.get("test", [])
    if not entries:
        raise ValueError(f"{rel}: no [[test]] entries")
    all_files = {f.name for f in case_dir.iterdir() if not f.name.startswith("_")}
    in_files = sorted(f for f in all_files if _INFILE_RE.fullmatch(f))
    used: set[str] = set()
    cases: list[LixCase] = []
    for entry in entries:
        unknown = set(entry) - _TOML_TEST_KEYS
        if unknown:
            raise ValueError(f"{rel}: unexpected test keys {sorted(unknown)}")
        runner = entry.get("runner")
        if runner not in RUNNERS:
            raise ValueError(f"{rel}: invalid runner {runner!r}")
        name = entry.get("name", runner)
        flags = list(entry.get("flags", []))
        extra = list(entry.get("extra-files", []))
        if len(extra) != len(set(extra)):
            raise ValueError(f"{rel}: duplicate extra-files {extra}")
        gassets = list(entry.get("global-assets", []))
        matrix = entry.get("matrix", False)
        in_spec = entry.get("in")
        if matrix:
            names = in_spec if in_spec is not None else in_files
            names = names if isinstance(names, list) else [names]
        else:
            names = [in_spec if isinstance(in_spec, str) else "in.nix"]
        for in_file in names:
            if not (case_dir / in_file).exists():
                raise ValueError(f"{rel}: missing input {in_file!r}")
            suffix = _infile_suffix(in_file)
            test_name = f"{name}{suffix}"
            if runner in ("eval-okay", "parse-okay") and not (case_dir / f"{test_name}.out.exp").exists():
                raise ValueError(f"{rel}: missing expected golden {test_name}.out.exp")
            used.add(in_file)
            used.add(f"{test_name}.out.exp")
            used.add(f"{test_name}.err.exp")
            for ef in extra:
                if not (case_dir / ef).exists():
                    raise ValueError(f"{rel}: missing extra-file {ef!r}")
                used.add(ef)
            cases.append(LixCase(case_dir, f"{rel}:{test_name}", runner, in_file,
                                 test_name, flags, extra, gassets))
    leftover = all_files - {"test.toml"} - used
    if leftover:
        raise ValueError(f"{rel}: unreferenced files {sorted(leftover)}")
    yield from cases


# --------------------------------------------------------------------------
# Lix declarative execution (eval + parse)
# --------------------------------------------------------------------------

def _indent(s: str, p: str = "    ") -> str:
    return "\n".join(p + line for line in s.splitlines())


def _diff(expected: str, actual: str) -> str:
    return (f"  expected: {expected.strip()!r}\n"
            f"  actual:   {actual.strip()!r}")


def _provide_global_asset(lang_dir: Path, name: str, dest: Path) -> str | None:
    """Materialise a Lix global asset (e.g. config.nix) into dest. Returns an
    error string when it cannot be satisfied (a setup FAIL, never a silent pass)."""
    ga = lang_dir.parent / "testlib" / "global_assets"
    if name == "config.nix":
        tpl = ga / "config.nix.template"
        if not tpl.exists():
            return "global-asset config.nix template missing"
        text = (tpl.read_text()
                .replace("@path@", "/path-placeholder")
                .replace("@system@", "x86_64-linux")
                .replace("@shell@", "/bin/sh"))
        (dest / "config.nix").write_text(text)
        return None
    src = ga / name
    if not src.exists():
        return f"unsatisfiable global-asset {name!r}"
    if src.is_dir():
        shutil.copytree(src, dest / name)
    else:
        shutil.copy(src, dest / name)
    return None


def _setup_lix_files(c: LixCase, lang_dir: Path, tmp: Path) -> str | None:
    """Copy the case's in.nix + lib.nix + extra-files + global-assets into tmp.
    Returns an error string on a setup problem (a FAIL, before fix ever runs)."""
    shutil.copy(c.case_dir / c.in_file, tmp / "in.nix")
    lib = lang_dir / "lib.nix"
    if lib.exists():
        shutil.copy(lib, tmp / "lib.nix")
    for extra in c.extra_files:
        src = c.case_dir / extra
        if not src.exists():
            return f"missing extra-file {extra!r}"
        dst = tmp / Path(extra).name
        if src.is_dir():
            shutil.copytree(src, dst)
        else:
            shutil.copy(src, dst)
    for asset in c.global_assets:
        err = _provide_global_asset(lang_dir, asset, tmp)
        if err:
            return err
    return None


def run_lix_case(fix: Path, lang_dir: Path, c: LixCase) -> Result:
    if c.handler is not None:
        return c.handler(fix)
    fix_flags, ferr = translate_flags(c.flags)
    if ferr:
        return Result("lix", c.ident, "fail", f"flag translation failed: {ferr}")
    if c.runner in ("parse-okay", "parse-fail"):
        return _run_lix_parse(fix, lang_dir, c, fix_flags)
    return _run_lix_eval(fix, lang_dir, c, fix_flags)


def _run_lix_eval(fix: Path, lang_dir: Path, c: LixCase, fix_flags: list[str]) -> Result:
    with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
        tmp = Path(td)
        setup_err = _setup_lix_files(c, lang_dir, tmp)
        if setup_err:
            return Result("lix", c.ident, "fail", f"setup failed: {setup_err}")
        # reference runner: --eval --strict, flakes xp feature on, HOME per-test.
        p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes",
                          *fix_flags, "in.nix"], tmp, {"HOME": str(tmp)})
        out = p.stdout.replace(str(tmp), "/pwd")
        err = p.stderr.replace(str(tmp), "/pwd")

        if c.runner == "eval-fail":
            # A genuine evaluation failure is rc == 1 (matches the reference
            # runner's .expect(1)). Timeout / crash / usage-error is a FAIL.
            if p.returncode == 1:
                return Result("lix", c.ident, "pass")
            if p.returncode == -1:
                return Result("lix", c.ident, "fail", "expected eval failure, but fix hung (timeout)")
            if p.returncode == 0:
                return Result("lix", c.ident, "fail", "expected eval failure, but it succeeded")
            return Result("lix", c.ident, "fail",
                          f"expected eval failure (rc 1), got rc {p.returncode}\n{_indent(err.strip())}")

        exp_file = c.case_dir / f"{c.test_name}.out.exp"
        if not exp_file.exists():
            return Result("lix", c.ident, "fail", "eval-okay case has no .out.exp golden (manifest error)")
        if p.returncode != 0:
            return Result("lix", c.ident, "fail", f"eval failed:\n{_indent(err.strip())}")
        if out.strip() == exp_file.read_text().strip():
            return Result("lix", c.ident, "pass")
        return Result("lix", c.ident, "fail", _diff(exp_file.read_text(), out))


def _normalize_parse_json(stdout: str) -> str:
    """Replicate the Lix lang-runner's parse normalization: json.loads then
    yaml.dump (sorted keys), with upstream's fixed list indentation."""
    import yaml

    class CustomFixedIndentationDumper(yaml.Dumper):
        def increase_indent(self, flow=False, indentless=False):
            super().increase_indent(flow, False)

    obj = json.loads(stdout)
    return yaml.dump(obj, Dumper=CustomFixedIndentationDumper, default_flow_style=False)


# The caret location `at <path>:<line>:<col>:` in a Nix or fix parser
# diagnostic. The trailing colon distinguishes the caret line from an inline
# reference like `already defined at <path>:2:3` (no trailing colon).
_ERR_LOC_RE = re.compile(r"at\s+\S*?:(\d+):(\d+):")


def _error_line(text: str) -> int | None:
    """Line of the (last) positioned parse error in a diagnostic, or None."""
    matches = _ERR_LOC_RE.findall(text)
    return int(matches[-1][0]) if matches else None


def _run_lix_parse(fix: Path, lang_dir: Path, c: LixCase, fix_flags: list[str]) -> Result:
    with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
        tmp = Path(td)
        setup_err = _setup_lix_files(c, lang_dir, tmp)
        if setup_err:
            return Result("lix", c.ident, "fail", f"setup failed: {setup_err}")
        p = run_fix(fix, [*fix_flags, "in.nix"], tmp, {"HOME": str(tmp)},
                    subcmd=("parse", "--json"))
        out = p.stdout.replace(str(tmp), "/pwd")
        err = p.stderr.replace(str(tmp), "/pwd")

        if c.runner == "parse-fail":
            # "Close enough" parse-fail: we do not reproduce Nix's exact error
            # prose, but fix must genuinely reject the input as a parse error —
            # exit 1 with no AST on stdout — and locate it on the same source
            # line Nix does. Column and message differences are tolerated.
            # Semantic errors fix only detects after parsing (e.g. duplicate
            # attributes) exit 0 here and correctly stay FAIL.
            if p.returncode != 1 or out.strip():
                detail = f"expected a parse error (exit 1, no AST); got rc={p.returncode}"
                if err.strip():
                    detail += f"\n{_indent(err.strip())}"
                return Result("lix", c.ident, "fail", detail)
            err_exp = c.case_dir / f"{c.test_name}.err.exp"
            want_line = _error_line(err_exp.read_text()) if err_exp.exists() else None
            got_line = _error_line(err)
            if want_line is not None and got_line is not None and want_line != got_line:
                return Result("lix", c.ident, "fail",
                              f"parse error on line {got_line}, Nix reports line {want_line}")
            return Result("lix", c.ident, "pass")

        exp_file = c.case_dir / f"{c.test_name}.out.exp"
        if not exp_file.exists():
            return Result("lix", c.ident, "fail", "parse-okay case has no .out.exp golden (manifest error)")
        if p.returncode != 0:
            return Result("lix", c.ident, "fail", f"parse failed (rc={p.returncode}):\n{_indent(err.strip())}")
        try:
            normalized = _normalize_parse_json(out)
        except ImportError:
            return Result("lix", c.ident, "fail", "pyyaml required to normalize parse output (run via run-unit.sh env)")
        except Exception as e:
            return Result("lix", c.ident, "fail", f"could not normalize parse JSON: {e}")
        err_exp = c.case_dir / f"{c.test_name}.err.exp"
        expected_err = err_exp.read_text() if err_exp.exists() else ""
        if (normalized.rstrip("\n") == exp_file.read_text().rstrip("\n")
                and err.rstrip("\n") == expected_err.rstrip("\n")):
            return Result("lix", c.ident, "pass")
        return Result("lix", c.ident, "fail", _diff(exp_file.read_text(), normalized))


# --------------------------------------------------------------------------
# Lix python-backed custom adapters (79 cases)
# --------------------------------------------------------------------------

def _custom_cases(case_dir: Path):
    builder = _CUSTOM_BUILDERS.get(case_dir.name)
    if builder is None:
        # A python-backed dir we don't recognise (pin drift): surface it as a
        # visible failing case rather than silently dropping it.
        ident = f"{case_dir.name}:custom"

        def h(_fix, n=case_dir.name):
            return Result("lix", f"{n}:custom", "fail",
                          f"unrecognized python-backed test dir {n!r} (pin drift?)")
        yield LixCase(case_dir, ident, "eval-okay", handler=h)
        return
    yield from builder(case_dir)


def _cmp_eval(ident: str, p, tmp: Path, expected: str) -> Result:
    out = p.stdout.replace(str(tmp), "/pwd")
    err = p.stderr.replace(str(tmp), "/pwd")
    if p.returncode != 0:
        return Result("lix", ident, "fail", f"eval failed:\n{_indent(err.strip())}")
    if out.strip() == expected.strip():
        return Result("lix", ident, "pass")
    return Result("lix", ident, "fail", _diff(expected, out))


def _cmp_eval_fail(ident: str, p, tmp: Path, expected_err: str) -> Result:
    err = p.stderr.replace(str(tmp), "/pwd")
    if p.returncode == 1 and err.strip() == expected_err.strip():
        return Result("lix", ident, "pass")
    return Result("lix", ident, "fail",
                  f"expected rc 1 + matching stderr; rc={p.returncode}\n"
                  f"  expected: {expected_err.strip()!r}\n  actual:   {err.strip()!r}")


def _eval(fix: Path, cwd: Path, flags: list[str], env: dict) -> object:
    full = {"HOME": str(cwd)}
    full.update(env)
    return run_fix(fix, ["--strict", "--extra-experimental-features", "flakes",
                         *flags, "in.nix"], cwd, full)


def _build_getenv(case_dir: Path):
    golden = (case_dir / "eval-okay.out.exp").read_text()
    src = ('builtins.getEnv "TEST_VAR" + '
           '(if builtins.getEnv "NO_SUCH_VAR" == "" then "bar" else "bla")')
    ident = "builtins.getEnv:eval-okay"

    def h(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            (tmp / "in.nix").write_text(src)
            p = _eval(fix, tmp, [], {"TEST_VAR": "foo"})
            return _cmp_eval(ident, p, tmp, golden)
    yield LixCase(case_dir, ident, "eval-okay", handler=h)


def _build_pathexists(case_dir: Path):
    lang_dir = case_dir.parent
    golden = (case_dir / "eval-okay.out.exp").read_text()
    ident = "builtins.pathExists:eval-okay"

    def h(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            # `./..`-relative asserts resolve above the eval cwd, so eval in a
            # subdir and put test-home/lib.nix in the parent.
            (tmp / "test-home").mkdir()
            shutil.copy(lang_dir / "lib.nix", tmp / "test-home" / "lib.nix")
            work = tmp / "work"
            work.mkdir()
            shutil.copy(case_dir / "in.nix", work / "in.nix")
            shutil.copy(lang_dir / "lib.nix", work / "lib.nix")
            sr = work / "symlink-resolution"
            (sr / "foo" / "lib").mkdir(parents=True)
            (sr / "foo" / "lib" / "default.nix").write_text('"test"')
            os.symlink("../overlays", sr / "foo" / "overlays")
            (sr / "overlays").mkdir(parents=True, exist_ok=True)
            (sr / "overlays" / "overlay.nix").write_text("import ../lib")
            os.symlink("nonexistent", sr / "broken")
            p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes", "in.nix"],
                        work, {"HOME": str(tmp)})
            return _cmp_eval(ident, p, work, golden)
    yield LixCase(case_dir, ident, "eval-okay", handler=h)


def _build_readdir_like(case_dir: Path):
    golden = (case_dir / "eval-okay.out.exp").read_text()
    ident = f"{case_dir.name}:eval-okay"

    def h(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            rd = tmp / "readDir"
            (rd / "foo").mkdir(parents=True)
            (rd / "bar").write_text("")
            os.symlink("./foo", rd / "ldir")
            os.symlink("./bar", rd / "linked")
            shutil.copy(case_dir / "in.nix", tmp / "in.nix")
            p = _eval(fix, tmp, [], {})
            return _cmp_eval(ident, p, tmp, golden)
    yield LixCase(case_dir, ident, "eval-okay", handler=h)


def _build_err_context(case_dir: Path):
    ident = "err_context:eval-fail"
    expr = 'builtins.addErrorContext "Hello" (throw "Foo")'

    def h(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            p = run_fix(fix, ["--show-trace", "-e", expr], tmp)
            if p.returncode != 0 and "Hello" in p.stderr:
                return Result("lix", ident, "pass")
            return Result("lix", ident, "fail",
                          f"expected rc!=0 with 'Hello' in stderr; rc={p.returncode}\n"
                          f"{_indent(p.stderr.strip())}")
    yield LixCase(case_dir, ident, "eval-fail", handler=h)


# 17 exprs, each with (exit_code, exit_code_depr). Verbatim from upstream
# parser-token-whitespace/test_whitespace_things.py.
PTW_EXPRS = [
    ("00012.3", 1, 0), ("0a", 1, 0), ("0https://a", 1, 0), ("0.0.0", 1, 0),
    ('foo"1"2', 1, 0), ("0x10", 1, 0), ("0.", 1, 1), ("1.", 0, 0),
    ("0.a", 1, 0), ("1.a", 1, 0), ('0.""', 1, 0), ('1.""', 1, 0),
    ("(0)(0)", 0, 0), ('a("")', 0, 0), ("(a).a", 0, 0), ("(a).0", 0, 0),
    ("00.", 1, 1),
]


def _ptw_case(case_dir: Path, golden_base: str, full: str, flags: list[str], expected_rc: int):
    ident = f"parser-token-whitespace:{golden_base}"
    out_g = case_dir / f"{golden_base}.out.exp"
    err_g = case_dir / f"{golden_base}.err.exp"

    def h(fix):
        expected_out = out_g.read_text() if out_g.exists() else ""
        expected_err = err_g.read_text() if err_g.exists() else ""
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            p = run_fix(fix, [*flags, "-e", full], Path(td), subcmd=("parse", "--json"))
        if (p.returncode == expected_rc
                and p.stdout.rstrip("\n") == expected_out.rstrip("\n")
                and p.stderr.rstrip("\n") == expected_err.rstrip("\n")):
            return Result("lix", ident, "pass")
        return Result("lix", ident, "fail",
                      f"rc={p.returncode} (expected {expected_rc})\n"
                      f"  stdout={p.stdout!r}\n  exp-out={expected_out!r}\n"
                      f"  stderr={p.stderr.strip()!r}\n  exp-err={expected_err.strip()!r}")
    return LixCase(case_dir, ident, "parse-okay", handler=h)


def _build_ptw(case_dir: Path):
    for expr, code_a, code_b in PTW_EXPRS:
        e = expr.strip()
        for wrapped in (f"({e})", f"[{e}]"):
            f_expr = wrapped.replace("/", "-")
            full = f"with {{}}; {wrapped}"
            yield _ptw_case(case_dir, f_expr, full,
                            ["--extra-deprecated-features", "url-literals"], code_a)
            yield _ptw_case(case_dir, f"{f_expr}-depr", full,
                            ["--extra-deprecated-features", "tokens-no-whitespace url-literals"], code_b)


def _build_search_path(case_dir: Path):
    lang_dir = case_dir.parent

    def copy_dirs(tmp: Path, trees, in_src: str, lib: bool = False):
        for t in trees:
            shutil.copytree(case_dir / t, tmp / t)
        if lib:
            shutil.copy(lang_dir / "lib.nix", tmp / "lib.nix")
        shutil.copy(case_dir / in_src, tmp / "in.nix")

    # (i) full search path, deprecated shadow-internal-symbols
    def h1(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            copy_dirs(tmp, ("dir1", "dir2", "dir3", "dir4"), "in.nix", lib=True)
            p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes",
                              "--extra-deprecated-features", "shadow-internal-symbols",
                              "-I", "dir1", "-I", "dir2", "-I", "dir5=dir3", "in.nix"],
                        tmp, {"NIX_PATH": "dir3:dir4", "HOME": str(tmp)})
            return _cmp_eval("search-path:eval-okay", p, tmp,
                             (case_dir / "eval-okay.out.exp").read_text())
    yield LixCase(case_dir, "search-path:eval-okay", "eval-okay", handler=h1)

    # (ii) nix=... prefix, deprecation silenced
    def h2(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            copy_dirs(tmp, ("nix-shadow",), "in-fetchurl.nix")
            p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes",
                              "--extra-deprecated-features", "nix-path-shadow", "in.nix"],
                        tmp, {"NIX_PATH": "nix=nix-shadow", "HOME": str(tmp)})
            return _cmp_eval("search-path:prefixed-deprecated", p, tmp,
                             (case_dir / "eval-okay-prefixed.out.exp").read_text())
    yield LixCase(case_dir, "search-path:prefixed-deprecated", "eval-okay", handler=h2)

    # (iii) nix=... prefix without the deprecation -> reserved-prefix error
    def h3(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            copy_dirs(tmp, ("nix-shadow",), "in-fetchurl.nix")
            p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes", "in.nix"],
                        tmp, {"NIX_PATH": "nix=nix-shadow", "HOME": str(tmp)})
            return _cmp_eval_fail("search-path:prefixed", p, tmp,
                                  (case_dir / "eval-okay-prefixed.err.exp").read_text())
    yield LixCase(case_dir, "search-path:prefixed", "eval-fail", handler=h3)

    # (iv) prefixless -I, deprecation silenced
    def h4(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            copy_dirs(tmp, ("nix-shadow",), "in-fetchurl.nix")
            p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes",
                              "--extra-deprecated-features", "nix-path-shadow",
                              "-I", "nix-shadow", "in.nix"], tmp, {"HOME": str(tmp)})
            return _cmp_eval("search-path:prefixless-deprecated", p, tmp,
                             (case_dir / "eval-okay-prefixless.out.exp").read_text())
    yield LixCase(case_dir, "search-path:prefixless-deprecated", "eval-okay", handler=h4)

    # (v) prefixless -I without the deprecation -> shadow error
    def h5(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            copy_dirs(tmp, ("nix-shadow",), "in-fetchurl.nix")
            p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes",
                              "-I", "nix-shadow", "in.nix"], tmp, {"HOME": str(tmp)})
            return _cmp_eval_fail("search-path:prefixless", p, tmp,
                                  (case_dir / "eval-okay-prefixless.err.exp").read_text())
    yield LixCase(case_dir, "search-path:prefixless", "eval-fail", handler=h5)

    # (vi) empty search path -> corepkg fetchurl
    def h6(fix):
        with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
            tmp = Path(td)
            shutil.copy(case_dir / "in-fetchurl.nix", tmp / "in.nix")
            p = run_fix(fix, ["--strict", "--extra-experimental-features", "flakes", "in.nix"],
                        tmp, {"HOME": str(tmp)})
            return _cmp_eval("search-path:empty", p, tmp,
                             (case_dir / "eval-okay-fetchurl.out.exp").read_text())
    yield LixCase(case_dir, "search-path:empty", "eval-okay", handler=h6)


_CUSTOM_BUILDERS = {
    "builtins.getEnv": _build_getenv,
    "builtins.pathExists": _build_pathexists,
    "builtins.readDir": _build_readdir_like,
    "builtins.readFileType": _build_readdir_like,
    "err_context": _build_err_context,
    "parser-token-whitespace": _build_ptw,
    "search-path": _build_search_path,
}


# --------------------------------------------------------------------------
# snix nix-language-test-suite runner
# --------------------------------------------------------------------------

# error-kind -> substrings fix's stderr must contain (modern CppNix / Lix
# phrasings, matching snix's reference cppnix runner's CppNixLatest/LixLatest arms)
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

# Every language feature declared by a snix case. Each is either mapped to a fix
# flag (flakes/pipe-operators -> experimental feature) or is a language-level
# feature judged purely by the golden compare (corepkgs/path-interpolation/
# curpos). An unknown feature is a FAIL, never a silent ignore.
SNIX_XP_FEATURES = {"flakes", "pipe-operators"}
SNIX_LANG_FEATURES = {"corepkgs", "path-interpolation", "curpos"}
SNIX_KNOWN_FEATURES = SNIX_XP_FEATURES | SNIX_LANG_FEATURES

DEVICE_FIXTURE_KINDS = {"char", "block", "device"}


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
                pos += 1
                continue
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


def snix_flags(c: SnixCase) -> tuple[list[str], str | None]:
    """Map a snix case's runtime-opts + features onto fix flags. Returns
    (flags, reason); reason is set (a FAIL) only for an unknown feature — a
    known language-level feature (corepkgs/path-interpolation/curpos) needs no
    flag and is judged by the golden compare."""
    flags: list[str] = []
    if c.eval_strict:
        flags.append("--strict")
    if c.xml_output:
        # reference runner passes --xml --no-location; fix omits positions from
        # its XML, so --no-location is accepted (matching Nix's form).
        flags += ["--xml", "--no-location"]
    for p in c.search_path:
        flags += ["--include", p]
    feats = []
    for f in sorted(c.features):
        if f in SNIX_XP_FEATURES:
            feats.append(f)
        elif f in SNIX_LANG_FEATURES:
            continue  # language-level; the .nix + golden judge it
        else:
            return flags, f"unsupported-feature:{f}"
    if feats:
        flags += ["--extra-experimental-features", " ".join(feats)]
    return flags, None


def _materialize_fixtures(fixtures: list[KdlNode], case_dir: Path, dest: Path,
                          devices: list[str]) -> tuple[str, str] | None:
    """Create the declared fixture tree under `dest`. fifo/socket nodes are made
    unprivileged; char/block/device nodes are recorded in `devices` for a
    run-time bind-mount (run_fix). Returns None on success, or (status, detail)
    where status is "fail" (malformed/undrivable) or "blocked" (external device
    provably absent)."""
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
                err = _materialize_fixtures(fx.children, case_dir, target, devices)
                if err:
                    return err
        elif fx.name == "symlink":
            (dest / fx.args[0]).parent.mkdir(parents=True, exist_ok=True)
            os.symlink(fx.props.get("target", ""), dest / fx.args[0])
        elif fx.name == "fifo":
            target = dest / fx.args[0]
            target.parent.mkdir(parents=True, exist_ok=True)
            os.mkfifo(target)
        elif fx.name == "socket":
            target = dest / fx.args[0]
            target.parent.mkdir(parents=True, exist_ok=True)
            s = socket.socket(socket.AF_UNIX)
            try:
                s.bind(str(target))
            finally:
                s.close()
        elif fx.name in DEVICE_FIXTURE_KINDS:
            arg = fx.args[0] if fx.args else ""
            if os.path.isabs(arg):
                # An absolute path names an existing system device the program
                # reads directly. If it is absent, the case is BLOCKED.
                if not os.path.exists(arg):
                    return ("blocked", f"missing-system-device:{arg}")
                continue
            # A device node to present at dest/arg via a run-time bind-mount.
            target = dest / arg
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("")
            devices.append(str(target))
        else:
            return ("fail", f"unsupported-fixture:{fx.name}")
    return None


def run_snix_case(fix: Path, c: SnixCase) -> Result:
    def fail(detail: str) -> Result:
        return Result("snix", c.ident, "fail", detail)

    # `nix-store` cases (import-from-derivation) need a real store; fix realizes
    # outputs on demand via a running nix-daemon. Absent store -> BLOCKED.
    if c.nix_store and not _store_available():
        return Result("snix", c.ident, "blocked", "needs-store (no nix-daemon/writable store)")

    nix_src = c.kdl.with_suffix(".nix")
    exp = c.kdl.with_suffix(".exp")
    err = c.kdl.with_suffix(".err")
    if not nix_src.exists():
        return fail("missing .nix companion")
    if not exp.exists() and not err.exists():
        return fail("missing golden (.exp/.err)")

    flags, reason = snix_flags(c)
    if reason:
        return fail(reason)

    with tempfile.TemporaryDirectory(prefix="fixlang-") as td:
        tmp = Path(td)
        devices: list[str] = []
        fxerr = _materialize_fixtures(c.fixtures, c.kdl.parent, tmp, devices)
        if fxerr:
            status, detail = fxerr
            return Result("snix", c.ident, status, detail)
        if devices and not userns_available():
            # Device fixtures need a rootless user+mount namespace; this kernel
            # doesn't allow it. BLOCKED, never a false pass/fail.
            return Result("snix", c.ident, "blocked", "device-fixture (no rootless userns)")

        code_path = tmp / nix_src.name
        shutil.copy(nix_src, code_path)
        env = {name: val for name, val in c.env_vars}
        p = run_fix(fix, [*flags, code_path.name], tmp, env, devices=devices or None)

        if err.exists():
            kind = err.read_text().strip()
            subs = ERROR_KINDS.get(kind, [])
            # A genuine evaluation failure is rc == 1 AND the expected phrasing.
            if p.returncode == 1 and any(s in p.stderr for s in subs):
                return Result("snix", c.ident, "pass")
            return fail(f"expected error kind {kind} (rc 1 & one of {subs}); "
                        f"rc={p.returncode}\n{_indent(p.stderr.strip())}")

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
# reporting
# --------------------------------------------------------------------------

def _progress(suite: str, i: int, total: int, n_pass: int, n_fail: int, n_block: int):
    msg = f"[{suite}] {i}/{total}  {n_pass} pass  {n_fail} fail  {n_block} blocked"
    if sys.stderr.isatty():
        sys.stderr.write("\r\033[K" + msg)
    else:
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
    done = n_pass = n_fail = n_block = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_PARALLEL) as pool:
        futs = {pool.submit(runner, c): idx for idx, c in enumerate(cases)}
        for fut in concurrent.futures.as_completed(futs):
            idx = futs[fut]
            r = fut.result()
            results[idx] = r
            done += 1
            if r.status == "pass":
                n_pass += 1
            elif r.status == "blocked":
                n_block += 1
            else:
                n_fail += 1
            _progress(name, done, total, n_pass, n_fail, n_block)
    if sys.stderr.isatty():
        sys.stderr.write("\n")
        sys.stderr.flush()
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", choices=["lix", "snix", "all"], default="all")
    ap.add_argument("--fix", default=str(REPO / "zig-out/bin/fix"), help="path to the fix binary")
    ap.add_argument("-v", "--verbose", action="store_true", help="show diffs for failures")
    args = ap.parse_args()

    fix = Path(args.fix)
    if not fix.exists():
        sys.exit(f"fix binary not found at {fix} (build with `zig build`)")

    suites = ["lix", "snix"] if args.suite == "all" else [args.suite]

    total_fail = 0
    for suite in suites:
        results = run_suite(suite, fix)
        fails = [r for r in results if r.status not in ("pass", "blocked")]
        blocked = [r for r in results if r.status == "blocked"]
        n_pass = sum(1 for r in results if r.status == "pass")

        head = Colors.bold(f"[{suite}]")
        print(f"{head} {Colors.green(str(n_pass) + ' pass')}, "
              f"{Colors.red(str(len(fails)) + ' fail')}, "
              f"{Colors.blue(str(len(blocked)) + ' blocked')}")

        # Every divergence — the point of this suite is to show, honestly, where
        # fix does not yet match the reference evaluator.
        for r in sorted(fails, key=lambda r: r.ident):
            print(f"  {Colors.red('FAIL')} {r.ident}")
            if args.verbose and r.detail:
                print(_indent(r.detail, "      "))
        # BLOCKED is always listed with its reason (it is not a pass).
        for r in sorted(blocked, key=lambda r: r.ident):
            print(f"  {Colors.blue('BLOCKED')} {r.ident} {Colors.dim('(' + r.detail + ')')}")

        total_fail += len(fails)

    # Non-zero iff any FAIL. BLOCKED does not fail the build.
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
