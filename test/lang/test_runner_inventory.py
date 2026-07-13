import importlib.util
import sys
import re
import subprocess
import tomllib
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("lang_runner_inventory", HERE / "run.py")
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)

# Per-directory custom-adapter inventory (must equal 79 in total).
CUSTOM_COUNTS = {
    "builtins.getEnv": 1,
    "builtins.pathExists": 1,
    "builtins.readDir": 1,
    "builtins.readFileType": 1,
    "err_context": 1,
    "parser-token-whitespace": 68,
    "search-path": 6,
}


def pin(name):
    expr = f"builtins.toString (import {runner.REPO}/npins).{name}"
    out = subprocess.check_output(["nix-instantiate", "--eval", "--expr", expr], text=True)
    return Path(out.strip().strip('"'))


def declarative_inventory(root):
    """Independent re-scan of the corpus's declarative test declarations, so the
    counts the runner asserts are checked against the corpus, not against the
    runner's own discovery."""
    counts = Counter()
    pattern = re.compile(r"^(eval-okay|eval-fail|parse-okay|parse-fail)(-[\w-]+?)?$")
    for directory in sorted(p for p in root.iterdir() if p.is_dir()):
        if directory.name == "assets" or any(directory.glob("*.py")):
            continue
        manifest = directory / "test.toml"
        if manifest.exists():
            for entry in tomllib.loads(manifest.read_text()).get("test", []):
                inputs = entry.get("in")
                if entry.get("matrix"):
                    inputs = sorted(p.name for p in directory.glob("in*.nix")) if inputs is None else inputs
                    inputs = inputs if isinstance(inputs, list) else [inputs]
                else:
                    inputs = [inputs if isinstance(inputs, str) else "in.nix"]
                counts[entry.get("runner")] += sum((directory / name).exists() for name in inputs)
            continue
        seen = set()
        for expected in list(directory.glob("*.out.exp")) + list(directory.glob("*.err.exp")):
            stem = expected.name.removesuffix(".out.exp").removesuffix(".err.exp")
            match = pattern.fullmatch(stem)
            if match and stem not in seen and (directory / f"in{match.group(2) or ''}.nix").exists():
                seen.add(stem)
                counts[match.group(1)] += 1
    return counts


class InventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lix = pin("lix") / "tests/functional2/lang"
        cls.snix = pin("snix") / "contrib/nix-language-test-suite/tests/cases"

    def test_pinned_declarative_lix_inventory(self):
        counts = declarative_inventory(self.lix)
        self.assertEqual(211, counts["eval-okay"] + counts["eval-fail"])
        self.assertEqual(67, counts["parse-okay"] + counts["parse-fail"])

    def test_runner_discovers_declarative_plus_custom(self):
        cases = list(runner.discover_lix_cases(self.lix))
        # 211 declarative eval + 67 declarative parse + 79 custom = 357.
        self.assertEqual(357, len(cases))
        custom = Counter(
            c.case_dir.name for c in cases if c.case_dir.name in runner.CUSTOM_DIRS
        )
        self.assertEqual(CUSTOM_COUNTS, dict(custom))
        self.assertEqual(79, sum(custom.values()))
        declarative = [c for c in cases if c.case_dir.name not in runner.CUSTOM_DIRS]
        self.assertEqual(278, len(declarative))

    def test_parser_token_whitespace_is_17x2x2(self):
        self.assertEqual(68, len(runner.PTW_EXPRS) * 2 * 2)

    def test_pinned_snix_inventory(self):
        # meta.kdl lives outside cases/ and is docs, not a case.
        self.assertEqual(116, len(list(self.snix.rglob("*.kdl"))))

    def assert_results_make_main_fail(self, results):
        with mock.patch.object(runner.Path, "exists", return_value=True), \
             mock.patch.object(runner, "run_suite", return_value=results), \
             mock.patch.object(runner.sys, "argv", ["run.py", "--suite", "lix"]):
            self.assertEqual(1, runner.main())

    def assert_results_make_main_pass(self, results):
        with mock.patch.object(runner.Path, "exists", return_value=True), \
             mock.patch.object(runner, "run_suite", return_value=results), \
             mock.patch.object(runner.sys, "argv", ["run.py", "--suite", "lix"]):
            self.assertEqual(0, runner.main())

    def test_fail_makes_main_fail(self):
        self.assert_results_make_main_fail([
            runner.Result("lix", "gap", "fail", "diverges"),
        ])

    def test_blocked_does_not_fail_the_build(self):
        self.assert_results_make_main_pass([
            runner.Result("lix", "ok", "pass"),
            runner.Result("lix", "gated", "blocked", "needs-store"),
        ])

    def test_stray_non_pass_non_blocked_status_fails(self):
        # A status that is neither pass nor blocked (e.g. a leftover "skip") must
        # count as a failure, so nothing can hide behind an unknown status.
        self.assert_results_make_main_fail([
            runner.Result("lix", "supported", "pass"),
            runner.Result("lix", "omitted", "skip", "unexpected"),
        ])


if __name__ == "__main__":
    unittest.main()
