import ast
import importlib.util
import sys
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("lang_runner_custom", HERE / "run.py")
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)

EXPECTED = {
    "builtins.getEnv": 1,
    "builtins.pathExists": 1,
    "builtins.readDir": 1,
    "builtins.readFileType": 1,
    "err_context": 1,
    "parser-token-whitespace": 68,
    "search-path": 6,
}


def lix_root():
    expr = f"builtins.toString (import {runner.REPO}/npins).lix"
    out = subprocess.check_output(["nix-instantiate", "--eval", "--expr", expr], text=True)
    return Path(out.strip().strip('"')) / "tests/functional2/lang"


def command_count(test_file):
    tree = ast.parse(test_file.read_text())
    tests = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")]
    if test_file.parent.name != "parser-token-whitespace":
        return len(tests)
    test = tests[0]
    parametrized = next(
        decorator for decorator in test.decorator_list
        if isinstance(decorator, ast.Call) and "parametrize" in ast.unparse(decorator.func)
    )
    # Each expression is tested in list and parenthesized forms, both normally
    # and with the deprecated parser feature enabled.
    return len(ast.literal_eval(parametrized.args[1])) * 2 * 2


class PythonAdapterInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = lix_root()

    def test_exact_python_backed_directories(self):
        actual = {
            directory.name for directory in self.root.iterdir()
            if directory.is_dir() and any(directory.glob("test_*.py"))
        }
        self.assertEqual(set(EXPECTED), actual)

    def test_custom_command_inventory_by_directory(self):
        actual = {}
        for name in EXPECTED:
            files = list((self.root / name).glob("test_*.py"))
            self.assertEqual(1, len(files), name)
            actual[name] = command_count(files[0])
        self.assertEqual(EXPECTED, actual)
        self.assertEqual(79, sum(actual.values()))

    def test_runner_does_not_omit_python_adapters(self):
        discovered = {case.case_dir.name for case in runner.discover_lix_cases(self.root)}
        self.assertTrue(set(EXPECTED).issubset(discovered))


if __name__ == "__main__":
    unittest.main()
