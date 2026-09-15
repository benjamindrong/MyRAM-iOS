#!/usr/bin/env python3

import json
import tempfile
import unittest
from pathlib import Path

from ben36_evidence import initiate, update


class RunIndexTests(unittest.TestCase):
    def test_attempt_is_created_once_and_updated_in_place(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "run-index.json"
            initiate(index, "BEN36-test", "BEN36-test", 300, "a" * 40)
            update(index, "BEN36-test", "telemetry-missing", "missing iOS telemetry")
            value = json.loads(index.read_text(encoding="utf-8"))
            self.assertEqual(len(value["runs"]), 1)
            self.assertEqual(value["runs"][0]["disposition"], "telemetry-missing")
            self.assertEqual(value["runs"][0]["detail"], "missing iOS telemetry")

    def test_duplicate_run_id_is_rejected_without_changing_index(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "run-index.json"
            initiate(index, "BEN36-test", "BEN36-test", 300, "a" * 40)
            before = index.read_bytes()
            with self.assertRaisesRegex(ValueError, "already indexed"):
                initiate(index, "BEN36-test", "other", 720, "b" * 40)
            self.assertEqual(index.read_bytes(), before)


class RunnerRetentionTests(unittest.TestCase):
    def test_cleanup_collects_runtime_evidence_before_termination(self) -> None:
        runner = (Path(__file__).parent / "ben36_run_endurance.sh").read_text(encoding="utf-8")
        cleanup = runner.split("cleanup() {", 1)[1].split("\n}\ntrap cleanup EXIT", 1)[0]

        collect_at = cleanup.index("collect_runtime_evidence_best_effort")
        mac_kill_at = cleanup.index('kill "$MAC_PID"')
        ios_kill_at = cleanup.index("device process terminate")

        self.assertLess(collect_at, mac_kill_at)
        self.assertLess(collect_at, ios_kill_at)


if __name__ == "__main__":
    unittest.main()
