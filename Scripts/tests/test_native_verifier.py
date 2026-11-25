"""Host-independent contract tests for Scripts/verify.py; no Xcode or network needed."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "verify.py"
SPEC = importlib.util.spec_from_file_location("myram_native_verifier", SCRIPT)
v = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(v)


class NativeVerifierTests(unittest.TestCase):
    def test_physical_cli_requires_explicit_unambiguous_native_mode(self):
        self.assertEqual(v.parse_args(["physical"]).suite, "physical")
        self.assertEqual(v.parse_args(["physical", "--iphone-udid",
                                       "00008110-00001A1234567890"]).iphone_udid,
                         "00008110-00001A1234567890")
        with self.assertRaisesRegex(v.VerificationError, "forbidden"):
            v.main(["physical", "--simulator", "11111111-1111-1111-1111-111111111111"])
        with self.assertRaisesRegex(v.VerificationError, "requires the physical suite"):
            v.main(["ui", "--iphone-udid", "00008110-00001A1234567890"])

    def test_physical_sync_cli_has_its_own_fixed_native_mode(self):
        self.assertEqual(v.parse_args(["physical-sync"]).suite, "physical-sync")
        with self.assertRaisesRegex(v.VerificationError, "forbidden"):
            v.main(["physical-sync", "--only", "MyRAMUITests/Any"])
        with self.assertRaisesRegex(v.VerificationError, "forbidden"):
            v.main(["physical-sync", "--simulator", "fake"])

    def test_physical_sync_rejects_wrong_run_identity_missing_phases_and_queue_work(self):
        token, candidate, pid = "a" * 32, "b" * 40, 123
        def event(name, title=None, suffix=""):
            row = dict(event=name, token=token, candidate=candidate, pid=str(pid))
            if title:
                row.update(title=f"Sync {token} {title}", body=f"Sync {token} body{suffix}")
            return row
        events = [event("ready"), event("seed-received", "A"), event("mac-title-saved", "B"),
                  event("iphone-title-received", "C"), event("mac-combined-saved", "D", " Mac"),
                  event("iphone-combined-received", "E", " Mac iPhone"),
                  event("drained", "E", " Mac iPhone")]
        events[-1]["diagnostics"] = "\n".join(["unsent_count=0", "pending_incoming_count=0",
            "pending_local_obligation_count=0", "pending_incoming_transport_count=0", "processing_incoming=false"])
        log = "\n".join("MYRAM_PHYSICAL_SYNC " + json.dumps(e) for e in events)
        v.assert_sync_roundtrip(v.sync_events(log, token, candidate, pid), token)
        for bad in (events[:-1], events[:3] + events[4:], events + [events[-1]],
                    events[:-1] + [dict(events[-1], diagnostics="unsent_count=1")],
                    events[:-1] + [dict(events[-1], body="different")]):
            with self.assertRaises(v.VerificationError):
                v.assert_sync_roundtrip(bad, token)
        with self.assertRaises(v.VerificationError):
            v.sync_events(log, token, candidate, pid + 1)
        with self.assertRaises(v.VerificationError):
            v.sync_events(log, "c" * 32, candidate, pid)
        with self.assertRaises(v.VerificationError):
            v.assert_mac_sync_drained(events[-1], offline=True)
        v.assert_mac_sync_drained(dict(events[-1], diagnostics=events[-1]["diagnostics"]
            + "\nmc_session_connected_count=0"), offline=True)

    def test_physical_sync_bundle_identity_rejects_transport_and_stale_candidates(self):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            values = dict(CFBundleIdentifier=v.SYNC_IOS_ID, MyRAMVerificationCandidateSHA="a"*40,
                          NSBonjourServices=[v.SYNC_SERVICE])
            path = app / "Info.plist"
            path.write_bytes(plistlib.dumps(values))
            v.assert_sync_bundle(app, v.SYNC_IOS_ID, "a"*40, mac=False)
            for wrong in (dict(values, MyRAMVerificationCandidateSHA="b"*40),
                          dict(values, MyRAMVerificationTransportOnly=True),
                          dict(values, CFBundleIdentifier="com.northsignalstudio.myram")):
                path.write_bytes(plistlib.dumps(wrong))
                with self.assertRaises(v.VerificationError):
                    v.assert_sync_bundle(app, v.SYNC_IOS_ID, "a"*40, mac=False)

    def test_worktree_cleanup_removes_only_audited_changes_and_preserves_unknown_content(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repo, worktree = base / "repo", base / "worktree"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / "profile").write_text("original\n")
            (repo / ".gitignore").write_text("ignored\n")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=fixture",
                            "-c", "user.email=fixture@example.org", "commit", "-qm", "base"], check=True)
            subprocess.run(["git", "-C", str(repo), "worktree", "add", "--detach", str(worktree)], check=True)
            (worktree / "profile").write_text("generated\n")
            expected = v.worktree_state(worktree)
            for name in ("untracked", "ignored"):
                extra = worktree / name
                extra.write_text("preserve\n")
                with self.assertRaisesRegex(v.VerificationError, "preserving"):
                    v.remove_verified_worktree(repo, worktree, expected)
                self.assertEqual(extra.read_text(), "preserve\n")
                self.assertEqual((worktree / "profile").read_text(), "generated\n")
                extra.unlink()
            v.remove_verified_worktree(repo, worktree, expected)
            self.assertFalse(worktree.exists())
            self.assertEqual((repo / "profile").read_text(), "original\n")

    def test_default_mode_is_ui(self):
        self.assertEqual(v.parse_args([]).suite, "ui")
        self.assertEqual(v.parse_args(["all"]).suite, "all")
        self.assertEqual(v.parse_args(["ios", "--only", "MyRAMTests/A/B"]).only,
                         ["MyRAMTests/A/B"])

    def test_suite_selector_is_exact_and_cannot_expand_other_targets(self):
        v.validate_only("ui", ["MyRAMUITests/MyRAMUITests/testFoo", "MyRAMUITests/OtherTests"])
        v.validate_only("ios", ["MyRAMTests/EditorFormattingMutationApplierTests"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("all", ["MyRAMTests/Any"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("ui", ["MyRAMTests/OtherTests"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("ui", ["MyRAMUITests/Tests;rm -rf ~"])
        with self.assertRaises(v.VerificationError):
            v.validate_only("ui", ["MyRAMUITests"])
        with self.assertRaisesRegex(v.VerificationError, "Duplicate"):
            v.validate_only("ui", ["MyRAMUITests/TestClass", "MyRAMUITests/TestClass"])
        with self.assertRaisesRegex(v.VerificationError, "Overlapping"):
            v.validate_only("ui", ["MyRAMUITests/TestClass/testMethod", "MyRAMUITests/TestClass"])

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

    def test_physical_iphone_selection_never_uses_simulators_or_ineligible_devices(self):
        inventory = """
        Available destinations for the "MyRAM" scheme:
          { platform:iOS, arch:arm64, id:00008110-00001A1234567890, name:Phone A }
          { platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
          { platform:iOS Simulator, id:11111111-1111-1111-1111-111111111111, name:Simulator }
        Ineligible destinations for the "MyRAM" scheme:
          { platform:iOS, id:00008120-00001A1234567890, name:Unavailable }
        """
        self.assertEqual(v.choose_physical_iphone(inventory, None), "00008110-00001A1234567890")
        with self.assertRaises(v.VerificationError):
            v.choose_physical_iphone(inventory, "00008120-00001A1234567890")
        with self.assertRaises(v.VerificationError):
            v.choose_physical_iphone("Available destinations for MyRAM:\n"
                + "{ platform:iOS Simulator, id:11111111-1111-1111-1111-111111111111 }\n"
                + "Ineligible destinations for MyRAM:\n"
                + "{ platform:iOS, id:00008120-00001A1234567890 }", None)
        multi = inventory.replace("Ineligible destinations", """{ platform:iOS, id:00008130-00001A1234567890, name:Phone B }
        Ineligible destinations""")
        with self.assertRaises(v.VerificationError):
            v.choose_physical_iphone(multi, None)

    def test_myr371_mac_native_trace_requires_connection_loss_and_reconnection(self):
        def item(event, detail="", peer="iPhone#one", session="MPC#one",
                 incarnation="owner-one"):
            return "MYR233_TRANSPORT " + json.dumps({
                "event": event, "mode": "transportOnly", "incarnation": incarnation,
                "session": session, "local": "Mac#one", "peer": peer, "detail": detail
            })
        base = [item("owner.created"), item("networking.start"), item("invitation.incoming.accepted")]
        complete = base + [item("session.state", state) for state in
                           ("state=2", "state=0", "state=2")]
        v.assert_myr371_mac_transport("\n".join(complete))
        with self.assertRaisesRegex(v.VerificationError, "different process"):
            v.assert_myr371_mac_transport("\n".join(complete), expected_pid=1234)
        for attempt in (base, complete[:-1], complete + [item("application.send")],
                        base + [item("session.state", state, peer="other") for state in
                                ("state=2", "state=0", "state=2")],
                        base + [item("session.state", state, session="different-session")
                                for state in ("state=2", "state=0", "state=2")],
                        base + [item("session.state", state, incarnation="different-owner")
                                for state in ("state=2", "state=0", "state=2")],
                        base + [item("session.state", "state=2"),
                                item("session.state", "state=0", session="new-session"),
                                item("session.state", "state=2")]):
            with self.assertRaises(v.VerificationError):
                v.assert_myr371_mac_transport("\n".join(attempt))

    def test_physical_xcode_user_authorization_blockers_are_explicit(self):
        self.assertIn("locked", v.physical_xcode_readiness_failure(
            'Run Destination Preflight: Unlock  iPhone to Continue'))
        self.assertIn("locked", v.physical_xcode_readiness_failure(
            "Xcode cannot launch MyRAMUITests because the device is locked."))
        self.assertIn("canceled", v.physical_xcode_readiness_failure(
            'Failed to initialize for UI testing: Authentication canceled.'))
        self.assertIsNone(v.physical_xcode_readiness_failure(
            "Run Destination Preflight: Waiting for the destination to become ready."))
        self.assertIsNone(v.physical_xcode_readiness_failure(
            "Running tests...\nTest Case testMYR371PhysicalTransportPairAndReconnect passed"))

    def test_physical_xcode_readiness_failure_aborts_and_preserves_original_log(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            evidence = v.Evidence(base / "Evidence" / "MyRAM" / "AutomatedVerification",
                                  "a" * 40, "b" * 40, "physical")
            script = ('import sys, time; '
                      'print("Unlock  iPhone to Continue", flush=True); '
                      'time.sleep(20)')
            start = time.monotonic()
            with self.assertRaisesRegex(v.VerificationError, "locked"):
                evidence.run("physical-iphone-tests",
                             [sys.executable, "-u", "-c", script],
                             physical_readiness=True)
            self.assertLess(time.monotonic() - start, 10)
            self.assertEqual(len(evidence.phases), 1)
            self.assertNotEqual(evidence.phases[0]["exit_code"], 0)
            self.assertIn("locked", evidence.phases[0]["failure_reason"])
            self.assertIn("Unlock  iPhone to Continue",
                          (evidence.raw / "physical-iphone-tests.log").read_text())
            evidence.seal("FAIL", "Device locked")
            self.assertTrue((evidence.path / "manifests" / "run.json").is_file())

    def test_result_must_report_tests_and_no_failures(self):
        self.assertEqual(v.validate_summary(json.dumps({"totalTestCount": 6, "failedTests": 0,
                                                         "result": "Passed", "passedTests": 6}))["total"], 6)
        for result in (dict(totalTestCount=0, failedTests=0, result="Passed"),
                       dict(totalTestCount=4, failedTests=1, result="Failed"),
                       dict(totalTestCount=4, failedTests=0, result="Incomplete"),
                       dict(totalTestCount=4, failedTests=0, result="Passed", passedTests=0, skippedTests=4),
                       dict(totalTestCount=4, failedTests=0, result="Passed", skippedTests=4),
                       dict(totalTestCount=4, failedTests=0, result="Passed", passedTests=3),
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
            self.assertEqual((evidence.raw / "producer-error.txt").read_text(),
                             "expected probe failure\n")

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
            calls = [0]

            def mutate_before_integrity_recheck(path):
                if Path(path).name == "ios-tests.log":
                    calls[0] += 1
                    if calls[0] == 2:
                        Path(path).write_bytes(b"changed after initial indexing")
                return original_hash(path)

            with patch.object(v, "sha_file", side_effect=mutate_before_integrity_recheck):
                with self.assertRaisesRegex(v.VerificationError, "integrity mismatch"):
                    evidence.seal("PASS")
            self.assertEqual(calls[0], 2)
            self.assertFalse((evidence.path / "manifests" / "run.json").exists())

    def test_run_id_is_unique_even_for_same_commit_in_same_second(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "MyRAM" / "AutomatedVerification"
            first = v.Evidence(root, "a" * 40, "b" * 40, "mac")
            second = v.Evidence(root, "a" * 40, "b" * 40, "mac")
            self.assertNotEqual(first.path, second.path)
            self.assertTrue(first.path.is_dir())
            self.assertTrue(second.path.is_dir())

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


    def test_multiple_selectors_require_independent_native_results(self):
        class ProbeEvidence:
            def __init__(self, raw):
                self.raw = raw
                self.phases = []
                self.commands = []

            def run(self, name, cmd, cwd=None, env=None):
                self.commands.append((name, cmd))
                self.phases.append({})

        passed = json.dumps({"totalTestCount": 1, "failedTests": 0,
                             "result": "Passed", "passedTests": 1})
        skipped = json.dumps({"totalTestCount": 1, "failedTests": 0,
                              "result": "Passed", "passedTests": 0, "skippedTests": 1})
        selectors = ["MyRAMUITests/ScreenTests/testA", "MyRAMUITests/ScreenTests/testB"]
        with tempfile.TemporaryDirectory() as directory:
            evidence = ProbeEvidence(Path(directory))
            with patch.object(v, "run_output", side_effect=[passed, passed]):
                v.xcode_phase(evidence, Path(directory), Path(directory), "ui",
                              "11111111-1111-1111-1111-111111111111", selectors, {})
            self.assertEqual([name for name, _ in evidence.commands],
                             ["ui-tests-1", "ui-tests-2"])
            for (_, command), selector in zip(evidence.commands, selectors):
                self.assertEqual([arg for arg in command if arg.startswith("-only-testing:")],
                                 ["-only-testing:" + selector])
            self.assertTrue((evidence.raw / "ui-tests-1-summary.json").is_file())
            self.assertTrue((evidence.raw / "ui-tests-2-summary.json").is_file())

        with tempfile.TemporaryDirectory() as directory:
            evidence = ProbeEvidence(Path(directory))
            with patch.object(v, "run_output", side_effect=[passed, skipped]):
                with self.assertRaisesRegex(v.VerificationError, "skipped-only"):
                    v.xcode_phase(evidence, Path(directory), Path(directory), "ui",
                                  "11111111-1111-1111-1111-111111111111", selectors, {})


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
