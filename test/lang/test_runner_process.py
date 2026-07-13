import importlib.util
import sys
import os
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("lang_runner_process", HERE / "run.py")
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


class FakeProcess:
    def __init__(self):
        self.events = []
        self.returncode = None
        self.pid = 1234

    def communicate(self, timeout=None):
        self.events.append(("communicate", timeout))
        if len([e for e in self.events if e[0] == "communicate"]) == 1:
            raise subprocess.TimeoutExpired("fix", timeout)
        self.returncode = -9
        return "", ""

    def terminate(self): self.events.append(("terminate",))
    def kill(self): self.events.append(("kill",))
    def wait(self, timeout=None):
        self.events.append(("wait", timeout))
        if len([e for e in self.events if e[0] == "wait"]) == 1:
            raise subprocess.TimeoutExpired("fix", timeout)
        self.returncode = -9
        return -9


class ProcessCleanupTests(unittest.TestCase):
    def assert_timeout_cleanup(self, devices):
        process = FakeProcess()
        def kill_group(pid, sig):
            process.events.append(("killpg", pid, sig))

        with tempfile.TemporaryDirectory() as td, \
             mock.patch.object(runner.subprocess, "Popen", return_value=process) as popen, \
             mock.patch.object(runner.subprocess, "run", return_value=runner.TimedOut()), \
             mock.patch.object(os, "killpg", side_effect=kill_group):
            result = runner.run_fix(Path("fix"), ["in.nix"], Path(td), devices=devices)
        self.assertEqual(-1, result.returncode)
        self.assertIsNotNone(popen.call_args, "run_fix must invoke subprocess.Popen")
        command = popen.call_args.args[0]
        if devices:
            self.assertEqual(
                ["unshare", "--map-root-user", "--user", "--mount", "sh", "-c"],
                command[:7],
            )
        else:
            self.assertEqual(["fix", "eval"], command[:2])
        term = ("killpg", process.pid, signal.SIGTERM)
        kill = ("killpg", process.pid, signal.SIGKILL)
        self.assertIn(term, process.events)
        self.assertIn(kill, process.events)
        self.assertLess(process.events.index(term), process.events.index(kill))
        self.assertEqual("wait", process.events[-1][0])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_direct_fix_timeout_terminates_kills_and_reaps_group(self):
        self.assert_timeout_cleanup(None)

    def test_unshare_timeout_terminates_kills_and_reaps_group(self):
        self.assert_timeout_cleanup(["/tmp/device"])


if __name__ == "__main__":
    unittest.main()
