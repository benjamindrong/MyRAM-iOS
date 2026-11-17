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

    def test_canonical_v1_sealing_tracks_original_logs_and_failed_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "MyRAM" / "AutomatedVerification"
            evidence = v.Evidence(root, "a" * 40, "b" * 40, "mac")
            with self.assertRaises(v.VerificationError):
                evidence.run("failed-probe", ["/bin/sh", "-c", "echo fixture-failure; exit 7"])
            evidence.seal("FAIL", "expected probe failure")
            location = evidence.path / "manifests" / "run.json"
            manifest = json.loads(location.read_text())
            self.assertEqual(manifest["manifest_schema_version"], 1)
            self.assertEqual(manifest["evidence_contract_version"], 1)
            self.assertEqual(manifest["project"], "MyRAM")
            self.assertEqual(manifest["work_unit"], "AutomatedVerification")
            self.assertEqual(manifest["run_id"], evidence.path.name)
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(manifest["retention_state"], "sealed")
            self.assertEqual(manifest["source_revision"], "a" * 40)
            self.assertEqual(manifest["origin"], {"kind": "implementation_unit",
                                                  "key": "AutomatedVerification"})
            self.assertEqual(manifest["history_state"], "current")
            self.assertEqual(manifest["authority_state"], "current")
            self.assertEqual(manifest["superseded_by_run_id"], None)
            self.assertTrue(manifest["started_at"])
            self.assertTrue(manifest["completed_at"])
            self.assertEqual(manifest["evidence"][0]["category"], "runner_output")
            self.assertEqual(manifest["evidence"][0]["provenance"], "machine")
            self.assertEqual(manifest["evidence"][0]["phase_id"], "phase-1")
            self.assertEqual(manifest["evidence"][0]["attempt_number"], 1)
            self.assertEqual(set(manifest["evidence"][0]), {
                "evidence_id", "category", "category_detail", "provenance",
                "availability", "path", "sha256", "phase_id", "attempt_number",
                "captured_at", "legacy_source_ref",
            })
            original = evidence.raw / "failed-probe.log"
            self.assertEqual(manifest["artifacts"][0]["sha256"], v.sha_file(original))
            self.assertFalse((evidence.path / "manifest.json").exists())

    def test_canonical_ui_result_bundle_keeps_native_bytes_and_a_single_index(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = v.Evidence(Path(directory) / "MyRAM" / "AutomatedVerification",
                                  "c" * 40, "d" * 40, "ui")
            evidence.run("ui-tests", ["/bin/sh", "-c", "printf 'passed\\n'"])
            bundle = evidence.raw / "ui-tests.xcresult"
            bundle.mkdir()
            original = bundle / "Data"
            original.write_bytes(b"native-xcresult-unchanged")
            evidence.seal("PASS")
            manifest = json.loads((evidence.path / "manifests" / "run.json").read_text())
            self.assertEqual(manifest["status"], "passed")
            self.assertEqual(original.read_bytes(), b"native-xcresult-unchanged")
            bundles = [item for item in manifest["evidence"] if item["category"] == "result_bundle"]
            self.assertEqual(len(bundles), 1)
            self.assertEqual(bundles[0]["path"], "raw/ui-tests.xcresult")
            self.assertIsNone(bundles[0]["sha256"])
            self.assertEqual(bundles[0]["phase_id"], "phase-1")
            artifacts = {item["path"]: item for item in manifest["artifacts"]}
            self.assertEqual(artifacts["raw/ui-tests.xcresult/Data"]["sha256"],
                             v.sha_file(original))
            self.assertNotIn("manifest.json", {p.name for p in evidence.path.iterdir()})

    def test_existing_canonical_seal_and_symlink_artifacts_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "MyRAM" / "AutomatedVerification"
            evidence = v.Evidence(root, "e" * 40, "f" * 40, "mac")
            location = evidence.path / "manifests" / "run.json"
            location.write_bytes(b"protected independent manifest")
            with self.assertRaises(FileExistsError):
                evidence.seal("FAIL", "no phases")
            self.assertEqual(location.read_bytes(), b"protected independent manifest")
            second = v.Evidence(root, "f" * 40, "e" * 40, "mac")
            regular = second.raw / "original.log"
            regular.write_bytes(b"original")
            (second.raw / "alias").symlink_to(regular)
            with self.assertRaises(v.VerificationError):
                second.seal("FAIL")
            self.assertFalse((second.path / "manifests" / "run.json").exists())

    def test_integrity_drift_blocks_publication_before_any_v1_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = v.Evidence(Path(directory) / "MyRAM" / "AutomatedVerification",
                                  "1" * 40, "2" * 40, "ios")
            evidence.run("ios-tests", ["/bin/sh", "-c", "printf fixture"])
            original_hash = v.sha_file
            changed = [False]

            def mutate_before_integrity_recheck(path):
                if Path(path).name == "ios-tests.log" and not changed[0]:
                    changed[0] = True
                    Path(path).write_bytes(b"changed after initial indexing")
                return original_hash(path)

            with patch.object(v, "sha_file", side_effect=mutate_before_integrity_recheck):
                with self.assertRaisesRegex(v.VerificationError, "integrity mismatch"):
                    evidence.seal("PASS")
            self.assertTrue(changed[0])
            self.assertFalse((evidence.path / "manifests" / "run.json").exists())

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
