import importlib.util
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("lang_runner_snix", HERE / "run.py")
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


def snix_root():
    expr = f"builtins.toString (import {runner.REPO}/npins).snix"
    out = subprocess.check_output(["nix-instantiate", "--eval", "--expr", expr], text=True)
    return Path(out.strip().strip('"')) / "contrib/nix-language-test-suite/tests/cases"


class SnixBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = snix_root()

    def test_full_kdl_discovery(self):
        kdls = sorted(self.root.rglob("*.kdl"))
        self.assertEqual(116, len(kdls))
        loaded = [runner.load_snix_case(path, self.root) for path in kdls]
        self.assertEqual({str(p.relative_to(self.root).with_suffix("")) for p in kdls},
                         {case.ident for case in loaded})

    def test_missing_nix_companion_is_failure(self):
        with tempfile.TemporaryDirectory() as td:
            kdl = Path(td) / "missing.kdl"
            kdl.write_text("")
            kdl.with_suffix(".exp").write_text("1")
            result = runner.run_snix_case(Path("fix"), runner.load_snix_case(kdl, Path(td)))
        self.assertEqual("fail", result.status)

    def test_missing_expected_companion_is_failure(self):
        with tempfile.TemporaryDirectory() as td:
            kdl = Path(td) / "missing.kdl"
            kdl.write_text("")
            kdl.with_suffix(".nix").write_text("1")
            case = runner.load_snix_case(kdl, Path(td))
            with mock.patch.object(runner, "run_fix") as run_fix:
                result = runner.run_snix_case(Path("fix"), case)
        self.assertEqual("fail", result.status)
        run_fix.assert_not_called()

    def test_every_declared_feature_is_known_and_handled(self):
        features = set()
        for kdl in self.root.rglob("*.kdl"):
            features.update(runner.load_snix_case(kdl, self.root).features)
        # Every feature the corpus declares must be known (mapped to a flag or a
        # language-level feature judged by the golden) — never silently ignored.
        self.assertTrue(
            features <= runner.SNIX_KNOWN_FEATURES,
            f"unknown corpus features: {features - runner.SNIX_KNOWN_FEATURES}",
        )
        for feature in features:
            _flags, reason = runner.snix_flags(runner.SnixCase(Path("x.kdl"), "x", features={feature}))
            self.assertIsNone(reason, f"known feature rejected: {feature}")
        # An unknown feature is a visible FAIL, not a silent pass.
        _flags, reason = runner.snix_flags(
            runner.SnixCase(Path("x.kdl"), "x", features={"future-unknown-feature"})
        )
        self.assertIsNotNone(reason)

    def test_network_case_is_driven(self):
        with tempfile.TemporaryDirectory() as td:
            kdl = Path(td) / "network.kdl"
            kdl.write_text("environment { network }")
            kdl.with_suffix(".nix").write_text("1")
            kdl.with_suffix(".exp").write_text("1")
            completed = subprocess.CompletedProcess([], 0, "1", "")
            with mock.patch.object(runner, "run_fix", return_value=completed):
                result = runner.run_snix_case(Path("fix"), runner.load_snix_case(kdl, Path(td)))
        self.assertNotEqual("skip", result.status)

    def test_unavailable_daemon_is_blocked_not_skip(self):
        case = runner.SnixCase(Path("store.kdl"), "store", nix_store=True)
        with mock.patch.object(runner, "_store_available", return_value=False):
            result = runner.run_snix_case(Path("fix"), case)
        self.assertEqual("blocked", result.status)

    def test_device_without_userns_is_blocked_not_skip(self):
        with tempfile.TemporaryDirectory() as td:
            kdl = Path(td) / "device.kdl"
            kdl.write_text('environment { fixtures { device "node" } }')
            kdl.with_suffix(".nix").write_text("1")
            kdl.with_suffix(".err").write_text("IO")
            with mock.patch.object(runner, "userns_available", return_value=False):
                result = runner.run_snix_case(Path("fix"), runner.load_snix_case(kdl, Path(td)))
        self.assertEqual("blocked", result.status)

    def test_fixture_kinds_are_not_silently_ignored(self):
        with tempfile.TemporaryDirectory() as td:
            error = runner._materialize_fixtures(
                [runner.KdlNode("unknown-fixture", ["x"])], Path(td), Path(td), []
            )
        self.assertIsNotNone(error)


if __name__ == "__main__":
    unittest.main()
