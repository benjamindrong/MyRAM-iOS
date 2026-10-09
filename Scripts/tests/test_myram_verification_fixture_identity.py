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

    def test_creator_binds_both_app_plists_and_manifest_and_preserves_source(self):
        self.generate(with_fixture=True)

    def test_creator_without_fixture_has_no_fixture_identity_configuration(self):
        self.generate(with_fixture=False)

    def generate(self, with_fixture):
        before = subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"])
        sha = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
        with tempfile.TemporaryDirectory() as directory:
            worktree = Path(directory) / "Verification"
            command = ["bash", str(ROOT / "Scripts/create-myram-verification-worktree.sh"), "--path", str(worktree)]
            fixture = self.fixture(Path(directory) / "fixture.json")
            if with_fixture:
                command += ["--fixture-manifest", str(fixture)]
            try:
                subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
                manifest = json.loads((worktree / "MYR-221-VERIFICATION-IDENTITY.json").read_text())
                self.assertEqual(manifest["source_candidate_sha"], sha)
                for platform, relative in [("iphone", "MyRAM/Info.plist"), ("mac", "MyRAM/Mac/Info.plist")]:
                    values = plistlib.loads((worktree / relative).read_bytes())
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
