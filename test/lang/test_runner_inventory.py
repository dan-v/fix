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


def pin(name):
    expr = f"builtins.toString (import {runner.REPO}/npins).{name}"
    out = subprocess.check_output(["nix-instantiate", "--eval", "--expr", expr], text=True)
    return Path(out.strip().strip('"'))


def declarative_inventory(root):
    counts = Counter()
    pattern = re.compile(r"^(eval-okay|eval-fail|parse-okay|parse-fail)(-[\w-]+?)?$")
    for directory in sorted(p for p in root.iterdir() if p.is_dir() and not any(p.glob("*.py"))):
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

    def test_runner_discovers_every_declarative_case(self):
        self.assertEqual(278, len(list(runner.discover_lix_cases(self.lix))))

    def test_pinned_snix_inventory(self):
        self.assertEqual(116, len(list(self.snix.rglob("*.kdl"))))

    def assert_results_make_main_fail(self, results):
        with mock.patch.object(runner.Path, "exists", return_value=True), \
             mock.patch.object(runner, "run_suite", return_value=results), \
             mock.patch.object(runner.sys, "argv", ["run.py", "--suite", "lix"]):
            self.assertEqual(1, runner.main())

    def test_skip_status_makes_main_fail(self):
        self.assert_results_make_main_fail([
            runner.Result("lix", "omitted", "skip", "unsupported"),
        ])

    def test_skip_status_makes_main_fail_among_passes(self):
        self.assert_results_make_main_fail([
            runner.Result("lix", "supported", "pass"),
            runner.Result("lix", "omitted", "skip", "unsupported"),
        ])


if __name__ == "__main__":
    unittest.main()
