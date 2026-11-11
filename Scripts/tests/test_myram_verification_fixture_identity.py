import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "configure-myram-verification.py"
ROOT = SCRIPT.parent.parent
spec = importlib.util.spec_from_file_location("configure_verification", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VerificationFixtureIdentityTests(unittest.TestCase):
    def test_storage_configuration_isolates_test_paths_as_well_as_application_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = module.EXPECTED_STORAGE_ROOT_FILES | {
                "MyRAMTests/MyRAMSyncOperationIDAllocatorTests.swift",
                "MyRAMTests/SyncBatchAnchoredRecoveryStoreTests.swift",
            }
            for relative in paths:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('.appendingPathComponent("MyRAM", isDirectory: true)')
            module.configure_storage_roots(root, {"storage_root_name": "MyRAM Verification"})
            for relative in paths:
                self.assertEqual((root / relative).read_text(),
                                 '.appendingPathComponent("MyRAM Verification", isDirectory: true)')

    def fixture(self, path, iphone="94C3C1CC-4FD0-4E55-97E3-3AAD33F24B8B", mac="5CF4DFED-1278-4D5C-BB0A-D63DC5866DC2"):
        path.write_text(json.dumps({"schema": "myr233.seven-batch-restore-fixture.v1",
                                   "captured_device_ids": {"iphone": iphone, "mac": mac}}))
        return path

    def test_manifest_binds_valid_distinct_ids_and_exact_manifest_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.fixture(Path(directory) / "fixture.json")
            result = module.load_fixture_identity(path)
            self.assertEqual(result["manifest_sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(result["iphone"], "94C3C1CC-4FD0-4E55-97E3-3AAD33F24B8B")
            self.assertEqual(result["mac"], "5CF4DFED-1278-4D5C-BB0A-D63DC5866DC2")

    def test_invalid_or_colliding_fixture_ids_fail_before_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            for iphone, mac in [("invalid", "invalid"), (None, "invalid"),
                                ("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000001")]:
                self.fixture(path, iphone, mac)
                with self.assertRaises(module.ConfigurationError):
                    module.load_fixture_identity(path)
            path.write_text('{"schema":"unsupported"}')
            with self.assertRaises(module.ConfigurationError):
                module.load_fixture_identity(path)

    def test_myr227_profile_prevents_existing_verification_collisions(self):
        ordinary = module.load_identity(ROOT)
        myr227 = module.load_identity(ROOT, "myr227")
        for key in ("display_name", "storage_root_name", "swiftdata_store_name",
                    "multipeer_service_type", "bonjour_service"):
            self.assertNotEqual(ordinary[key], myr227[key])
        for platform in ("ios", "macos"):
            for key in ("app_bundle_identifier", "widget_bundle_identifier",
                        "widget_app_group_identifier", "url_scheme"):
                self.assertNotEqual(ordinary[platform][key], myr227[platform][key])
        with self.assertRaises(module.ConfigurationError):
            module.load_identity(ROOT, "not-registered")

    def test_test_only_profile_is_distinct_and_rebinds_host_and_test_bundles(self):
        profile = module.load_identity(ROOT, "myr227test")
        live = module.load_identity(ROOT, "myr227")
        for key in ("storage_root_name", "swiftdata_store_name", "multipeer_service_type"):
            self.assertNotEqual(profile[key], live[key])
        for platform in ("ios", "macos"):
            self.assertNotEqual(profile[platform]["app_bundle_identifier"], live[platform]["app_bundle_identifier"])
            self.assertNotEqual(profile[platform]["widget_app_group_identifier"], live[platform]["widget_app_group_identifier"])
        self.generate(with_fixture=False, profile="myr227test")

    def test_creator_binds_myr227_profile_in_disposable_checkout(self):
        self.generate(with_fixture=False, profile="myr227")

    def test_creator_binds_both_app_plists_and_manifest_and_preserves_source(self):
        self.generate(with_fixture=True)

    def test_creator_without_fixture_has_no_fixture_identity_configuration(self):
        self.generate(with_fixture=False)

    def test_transport_only_generation_binds_both_apps_and_audit(self):
        self.generate(with_fixture=True, transport_only=True)

    def generate(self, with_fixture, transport_only=False, profile="default"):
        before = subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"])
        sha = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
        with tempfile.TemporaryDirectory() as directory:
            worktree = Path(directory) / "Verification"
            command = ["bash", str(ROOT / "Scripts/create-myram-verification-worktree.sh"), "--path", str(worktree), "--profile", profile]
            fixture = self.fixture(Path(directory) / "fixture.json")
            if transport_only:
                command += ["--transport-only"]
            if with_fixture:
                command += ["--fixture-manifest", str(fixture)]
            try:
                subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
                manifest = json.loads((worktree / "MYR-221-VERIFICATION-IDENTITY.json").read_text())
                self.assertEqual(manifest["source_candidate_sha"], sha)
                self.assertEqual(manifest["profile"], profile)
                if profile == "myr227test":
                    project_text = (worktree / "MyRAM.xcodeproj" / "project.pbxproj").read_text()
                    expected = module.load_identity(ROOT, profile)
                    for name in (expected["ios"]["test_bundle_identifier"],
                                 expected["ios"]["ui_test_bundle_identifier"],
                                 expected["macos"]["test_bundle_identifier"]):
                        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER = {name};", project_text)
                    for original in (*module.PRODUCTION["ios_test_bundle_ids"],
                                     *module.PRODUCTION["mac_test_bundle_ids"]):
                        self.assertNotIn(f"PRODUCT_BUNDLE_IDENTIFIER = {original};", project_text)
                self.assertEqual(manifest["multipeer"]["verification_service_type"],
                                 module.load_identity(ROOT, profile)["multipeer_service_type"])
                self.assertEqual(manifest["transport_mode"], "transportOnly" if transport_only else "application")
                for platform, relative in [("iphone", "MyRAM/Info.plist"), ("mac", "MyRAM/Mac/Info.plist")]:
                    values = plistlib.loads((worktree / relative).read_bytes())
                    self.assertEqual(values.get("MyRAMVerificationTransportOnly", False), transport_only)
                    if with_fixture:
                        self.assertEqual(values["MyRAMVerificationFixtureDeviceID"], manifest["fixture_identity"][platform])
                    else:
                        self.assertNotIn("MyRAMVerificationFixtureDeviceID", values)
                if with_fixture:
                    self.assertEqual(manifest["fixture_identity"]["manifest_sha256"], hashlib.sha256(fixture.read_bytes()).hexdigest())
                else:
                    self.assertIsNone(manifest["fixture_identity"])
                subprocess.run(["git", "-C", str(worktree), "diff", "--check"], check=True)
            finally:
                subprocess.run(["git", "-C", str(ROOT), "worktree", "remove", "--force", str(worktree)], capture_output=True)
        self.assertEqual(subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"]), before)


if __name__ == "__main__":
    unittest.main()
