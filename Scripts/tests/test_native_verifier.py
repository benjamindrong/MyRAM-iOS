"""Host-independent contract tests for Scripts/verify.py; no Xcode or network needed."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "verify.py"
SPEC = importlib.util.spec_from_file_location("myram_native_verifier", SCRIPT)
v = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(v)


class NativeVerifierTests(unittest.TestCase):
    def test_default_mode_is_ui(self):
        self.assertEqual(v.parse_args([]).suite, "ui")
        self.assertEqual(v.parse_args(["all"]).suite, "all")
        self.assertEqual(v.parse_args(["ios", "--only", "MyRAMTests/A/B"]).only,
                         ["MyRAMTests/A/B"])

    def test_suite_selector_is_exact_and_cannot_expand_other_targets(self):
        v.validate_only("ui", ["MyRAMUITests/MyRAMUITests/testFoo", "MyRAMUITests/MyRAMUITests"])
        v.validate_only("ios", ["MyRAMTests/EditorFormattingMutationApplierTests"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("all", ["MyRAMTests/Any"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("ui", ["MyRAMTests/OtherTests"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("ui", ["MyRAMUITests/Tests;rm -rf ~"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("ui", ["MyRAMUITests"])

    def test_origin_policy(self):
        for origin in ("https://github.com/benjamindrong/MyRAM-iOS.git",
                       "git@github.com:benjamindrong/MyRAM-iOS.git",
                       "ssh://git@github.com/benjamindrong/MyRAM-iOS.git"):
            self.assertEqual(v.normal_origin(origin), v.REPOSITORY)
        self.assertEqual(v.normal_origin("git@otherhost:benjamindrong/MyRAM-iOS.git"), "")

    def test_dependency_pin_must_be_unique_and_immutable(self):
        sample = "  repository: benjamindrong/NearbySyncCore\n  ref: " + "a" * 40 + "\n"
        self.assertEqual(v.pinned_nearby_sha(sample), "a" * 40)
        with self.assertRaises(v.VerificationError):
            v.pinned_nearby_sha(sample * 2)
        with self.assertRaises(v.VerificationError):
            v.pinned_nearby_sha("repository: benjamindrong/NearbySyncCore\nref: main\n")

    def test_simulator_resolution_reuses_booted_and_pinned(self):
        devices = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                {"name": "iPhone 17 Pro", "udid": "11111111-1111-1111-1111-111111111111",
                 "isAvailable": True, "state": "Shutdown"},
                {"name": "MYRAM_SIMULATOR_ID", "udid": "22222222-2222-2222-2222-222222222222",
                 "isAvailable": True, "state": "Booted"}],
            "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
                {"name": "iPhone 17 Pro", "udid": "33333333-3333-3333-3333-333333333333",
                 "isAvailable": True, "state": "Booted"}]}}
        self.assertEqual(v.choose_simulator(json.dumps(devices), None),
                         ("22222222-2222-2222-2222-222222222222", True))
        self.assertEqual(v.choose_simulator(json.dumps(devices), "11111111-1111-1111-1111-111111111111"),
                         ("11111111-1111-1111-1111-111111111111", False))
        with self.assertRaises(v.VerificationError):
            v.choose_simulator(json.dumps(devices), "33333333-3333-3333-3333-333333333333")

    def test_result_must_report_tests_and_no_failures(self):
        self.assertEqual(v.validate_summary(json.dumps({"totalTestCount": 6, "failedTests": 0,
                                                         "result": "Passed", "passedTests": 6}))["total"], 6)
        for result in (dict(totalTestCount=0, failedTests=0, result="Passed"),
                       dict(totalTestCount=4, failedTests=1, result="Failed"),
                       dict(totalTestCount=4, failedTests=0, result="Incomplete"),
                       dict(failedTests=0, result="Passed")):
            with self.assertRaises(v.VerificationError):
                v.validate_summary(json.dumps(result))

    def test_candidate_identity_rejects_dirty_tree(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=fixture",
                            "-c", "user.email=fixture@example.org", "commit", "--allow-empty", "-qm", "base"], check=True)
            sha = v.current_candidate(root)
            self.assertRegex(sha, r"^[0-9a-f]{40}$")
            (root / "uncommitted.txt").write_text("private work")
            with self.assertRaises(v.VerificationError):
                v.current_candidate(root)
            self.assertEqual((root / "uncommitted.txt").read_text(), "private work")

    def test_lock_prevents_concurrent_identity_use(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with v.lock_resources(root, ["mac-profile"]):
                with self.assertRaises(v.VerificationError):
                    with v.lock_resources(root, ["mac-profile"]):
                        pass
            with v.lock_resources(root, ["mac-profile"]):
                pass

    def test_evidence_sealing_tracks_hashes_and_failed_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = v.Evidence(Path(directory), "a" * 40, "b" * 40, "mac")
            with self.assertRaises(v.VerificationError):
                evidence.run("failed-probe", ["/bin/sh", "-c", "echo fixture-failure; exit 7"])
            evidence.seal("FAIL", "expected probe failure")
            manifest = json.loads((evidence.path / "manifest.json").read_text())
            self.assertEqual(manifest["outcome"], "FAIL")
            self.assertEqual(manifest["phases"][0]["exit_code"], 7)
            self.assertEqual(manifest["canonical_artifacts"][0]["sha256"],
                             v.sha_file(evidence.raw / "failed-probe.log"))

    def test_xcode_phase_only_selector_does_not_expand_to_full_target(self):
        class ProbeEvidence:
            def __init__(self, raw):
                self.raw = raw
                self.phases = [{}]
                self.cmd = None
            def run(self, name, cmd, cwd=None, env=None):
                self.cmd = cmd
        with tempfile.TemporaryDirectory() as directory:
            e = ProbeEvidence(Path(directory))
            with patch.object(v, "run_output", return_value=json.dumps({
                "totalTestCount": 1, "failedTests": 0, "result": "Passed", "passedTests": 1})):
                v.xcode_phase(e, Path(directory), Path(directory), "ui", "11111111-1111-1111-1111-111111111111",
                              ["MyRAMUITests/MyRAMUITests/testA"], {})
            self.assertIn("-only-testing:MyRAMUITests/MyRAMUITests/testA", e.cmd)
            self.assertNotIn("-only-testing:MyRAMUITests", e.cmd)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", e.cmd)
            self.assertIn("-parallel-testing-enabled", e.cmd)

    def test_profile_is_isolated_from_all_registered_profiles(self):
        root = Path(__file__).resolve().parents[1]
        profiles = [json.loads(p.read_text()) for p in root.glob("*verification-identities.json")]
        automated = json.loads((root / "myram-automated-test-identities.json").read_text())
        profiles.append(automated)
        seen = set()
        for entry in profiles:
            values = [entry["display_name"], entry["storage_root_name"],
                      entry["swiftdata_store_name"], entry["multipeer_service_type"],
                      entry["bonjour_service"]]
            for platform in ("ios", "macos"):
                values.extend(str(x) for x in entry[platform].values())
            self.assertFalse(seen.intersection(values))
            seen.update(values)
        self.assertLessEqual(len(automated["multipeer_service_type"]), 15)
        self.assertNotIn("com.northsignalstudio.myram.dev", seen)


if __name__ == "__main__":
    unittest.main()
