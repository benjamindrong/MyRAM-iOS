"""Noninteractive, interruption-safe MYR-225 physical UI runner regression tests."""

import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest import mock


RUNNER = Path(__file__).resolve().parents[1] / "verify-myr225-physical-title-sync.py"
SPEC = importlib.util.spec_from_file_location("myr225_physical_runner", RUNNER)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MYR225PhysicalTitleSyncRunnerTests(unittest.TestCase):
    def test_child_cannot_read_operator_terminal_or_standard_input(self):
        probe = (
            "import os, sys\n"
            "assert not sys.stdin.isatty()\n"
            "assert sys.stdin.read() == ''\n"
            "assert os.getenv('GIT_TERMINAL_PROMPT') == '0'\n"
            "assert os.getenv('GCM_INTERACTIVE') == 'Never'\n"
            "try:\n"
            "    open('/dev/tty', 'rb')\n"
            "except OSError:\n"
            "    pass\n"
            "else:\n"
            "    raise AssertionError('controlling terminal available')\n"
            "print('NO_TTY_PASS')\n"
        )
        result = MODULE.run([sys.executable, "-c", probe], timeout_seconds=15)
        self.assertEqual(result.stdout.decode().strip(), "NO_TTY_PASS")

    def test_runner_kills_isolated_process_group_before_worktree_cleanup(self):
        child = mock.Mock()
        child.pid = 45678
        child.communicate.side_effect = [KeyboardInterrupt(), (b"", b"")]
        with mock.patch.object(MODULE.subprocess, "Popen", return_value=child) as popen:
            with mock.patch.object(MODULE.os, "killpg") as killpg:
                with self.assertRaises(KeyboardInterrupt):
                    MODULE.run([sys.executable, "-c", "pass"])
        self.assertEqual(killpg.call_args_list, [
            mock.call(45678, signal.SIGTERM)
        ])
        options = popen.call_args.kwargs
        self.assertEqual(options["stdin"], subprocess.DEVNULL)
        self.assertTrue(options["start_new_session"])
        self.assertEqual(options["env"]["GIT_TERMINAL_PROMPT"], "0")

    def test_timeout_escalates_group_termination_before_return(self):
        child = mock.Mock()
        child.pid = 45678
        child.communicate.side_effect = [
            subprocess.TimeoutExpired("xcodebuild", 1),
            subprocess.TimeoutExpired("xcodebuild", 8),
            (b"", b""),
        ]
        with mock.patch.object(MODULE.subprocess, "Popen", return_value=child):
            with mock.patch.object(MODULE.os, "killpg") as killpg:
                with self.assertRaises(subprocess.TimeoutExpired):
                    MODULE.run(["xcodebuild"], timeout_seconds=1)
        self.assertEqual(killpg.call_args_list, [
            mock.call(45678, signal.SIGTERM),
            mock.call(45678, signal.SIGKILL),
        ])


if __name__ == "__main__":
    unittest.main()
