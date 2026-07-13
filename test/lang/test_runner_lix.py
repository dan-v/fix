import importlib.util
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("lang_runner_lix", HERE / "run.py")
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


class LixManifestTests(unittest.TestCase):
    def make_case(self, manifest, files=("in.nix",)):
        td = tempfile.TemporaryDirectory()
        root = Path(td.name)
        case = root / "case"
        case.mkdir()
        (case / "test.toml").write_text(manifest)
        for name in files:
            (case / name).write_text("1")
        return td, root

    def test_all_four_declarative_runners_are_discovered(self):
        manifest = "".join(f'[[test]]\nrunner = "{name}"\n\n' for name in runner.RUNNERS)
        td, root = self.make_case(manifest, (
            "in.nix", "eval-okay.out.exp", "eval-fail.err.exp",
            "parse-okay.out.exp", "parse-fail.err.exp",
        ))
        with td:
            self.assertEqual(set(runner.RUNNERS), {c.runner for c in runner.discover_lix_cases(root)})

    def assert_invalid(self, manifest, files=("in.nix",)):
        td, root = self.make_case(manifest, files)
        with td, self.assertRaises((ValueError, tomllib.TOMLDecodeError)):
            list(runner.discover_lix_cases(root))

    def test_missing_input_asset_is_validation_failure(self):
        td, root = self.make_case('[[test]]\nrunner = "eval-okay"\n', ())
        with td, self.assertRaises(ValueError):
            list(runner.discover_lix_cases(root))

    def test_missing_expected_asset_is_validation_failure(self):
        td, root = self.make_case('[[test]]\nrunner = "eval-okay"\n')
        with td, self.assertRaises(ValueError):
            list(runner.discover_lix_cases(root))

    def test_unknown_runner_is_validation_failure(self):
        td, root = self.make_case('[[test]]\nrunner = "unknown"\n')
        with td, self.assertRaises(ValueError):
            list(runner.discover_lix_cases(root))

    def test_missing_extra_asset_is_validation_failure(self):
        td, root = self.make_case(
            '[[test]]\nrunner = "eval-okay"\nextra-files = ["absent"]\n',
            ("in.nix", "eval-okay.out.exp"),
        )
        with td, self.assertRaises(ValueError):
            list(runner.discover_lix_cases(root))

    def test_unreferenced_expected_asset_is_validation_failure(self):
        td, root = self.make_case(
            '[[test]]\nrunner = "eval-okay"\n',
            ("in.nix", "eval-okay.out.exp", "unknown.out.exp"),
        )
        with td, self.assertRaises(ValueError):
            list(runner.discover_lix_cases(root))

    def test_duplicate_asset_is_validation_failure(self):
        td, root = self.make_case(
            '[[test]]\nrunner = "eval-okay"\nextra-files = ["asset", "asset"]\n',
            ("in.nix", "eval-okay.out.exp", "asset"),
        )
        with td, self.assertRaises(ValueError):
            list(runner.discover_lix_cases(root))

    def test_unknown_manifest_key_is_validation_failure(self):
        td, root = self.make_case('[[test]]\nrunner = "eval-okay"\nsurprise = true\n')
        with td, self.assertRaises(ValueError):
            list(runner.discover_lix_cases(root))

    def test_duplicate_manifest_key_is_validation_failure(self):
        td, root = self.make_case('[[test]]\nrunner = "eval-okay"\nrunner = "eval-fail"\n')
        with td, self.assertRaises(Exception):
            list(runner.discover_lix_cases(root))


if __name__ == "__main__":
    unittest.main()
