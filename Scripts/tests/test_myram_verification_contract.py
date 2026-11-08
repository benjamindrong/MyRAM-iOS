from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import myram_verification_contract as resolver  # noqa: E402


RULES_PATH = SCRIPTS / "myram-verification-contract-v1.json"
AUTHORITY_PATH = SCRIPTS / "tests" / "fixtures" / "myr-196-authority.json"
EXPECTED_PATH = SCRIPTS / "tests" / "fixtures" / "myr-196-expected-contract.json"

CHANGED_AREA_IDS = {"V02", "V08", "V11", "V12", "E07"}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class VerificationContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rules = load(RULES_PATH)
        self.authority = load(AUTHORITY_PATH)
        self.expected = load(EXPECTED_PATH)

    def test_myr_196_replay_matches_manually_reviewed_oracle(self) -> None:
        contract = resolver.resolve_contract(self.rules, self.authority)

        self.assertEqual(contract, self.expected)
        self.assertEqual(len(contract["verification_requirements"]), 13)
        self.assertEqual(len(contract["evidence_requirements"]), 12)
        self.assertEqual(len(contract["fail_closed_conditions"]), 4)
        self.assertEqual(len(contract["changed_paths"]), 16)
        self.assertEqual(
            [item["id"] for item in contract["fail_closed_conditions"]],
            ["F01", "F02", "F03", "F04"],
        )

    def test_contract_digest_and_cli_bytes_are_stable(self) -> None:
        contract = resolver.resolve_contract(self.rules, self.authority)
        without_digest = dict(contract)
        expected_digest = without_digest.pop("contract_sha256")
        actual_digest = hashlib.sha256(
            resolver.canonical_bytes(without_digest)
        ).hexdigest()
        self.assertEqual(actual_digest, expected_digest)

        expected_bytes = resolver.canonical_bytes(contract) + b"\n"
        first = self.run_cli(self.authority)
        second = self.run_cli(self.authority)
        self.assertEqual(first.returncode, 0, first.stderr.decode())
        self.assertEqual(second.returncode, 0, second.stderr.decode())
        self.assertEqual(first.stdout, expected_bytes)
        self.assertEqual(second.stdout, expected_bytes)
        self.assertEqual(first.stdout, second.stdout)
        self.assertTrue(first.stdout.endswith(b"\n"))
        self.assertFalse(first.stdout.endswith(b"\n\n"))

    def test_order_invariance_and_exact_equal_authority_duplicate(self) -> None:
        rules = copy.deepcopy(self.rules)
        rules["authority_catalog"].reverse()
        rules["predicates"].reverse()
        rules["verification_requirements"].reverse()
        rules["evidence_requirements"].reverse()
        for requirement in rules["verification_requirements"] + rules["evidence_requirements"]:
            requirement["authority_ids"].reverse()
            if requirement["trigger"]["kind"] == "explicit-authority":
                requirement["trigger"]["authority_ids"].reverse()

        authority = copy.deepcopy(self.authority)
        authority["changed_paths"].reverse()
        authority["authorities"].reverse()
        authority["authorities"].append(copy.deepcopy(authority["authorities"][0]))

        self.assertEqual(
            resolver.resolve_contract(rules, authority),
            self.expected,
        )

    def test_fixed_non_triggering_replay_paths_are_accepted_without_changed_area_selection(self) -> None:
        authority = copy.deepcopy(self.authority)
        authority["changed_paths"] = [
            "docs/MYR-196-completion-verification-evidence.md",
            "AGENTS.md",
        ]

        contract = resolver.resolve_contract(self.rules, authority)
        selected = {
            item["id"]
            for key in ("verification_requirements", "evidence_requirements")
            for item in contract[key]
        }
        self.assertTrue(CHANGED_AREA_IDS.isdisjoint(selected))
        self.assertIn("V01", selected)
        self.assertIn("E09", selected)

    def test_every_approved_trigger_class_and_predicate_is_traceable(self) -> None:
        contract = resolver.resolve_contract(self.rules, self.authority)
        items = {
            item["id"]: item
            for key in ("verification_requirements", "evidence_requirements")
            for item in contract[key]
        }

        self.assertEqual(items["V01"]["trigger"], {"kind": "always-required"})
        self.assertEqual(
            items["V02"]["trigger"],
            {"kind": "changed-area", "predicate": "P-MAC-PROVEN"},
        )
        self.assertEqual(
            items["V08"]["trigger"],
            {"kind": "changed-area", "predicate": "P-PROJECT"},
        )
        self.assertEqual(
            items["V11"]["trigger"],
            {"kind": "changed-area", "predicate": "P-SHARED-IPHONE"},
        )
        self.assertEqual(
            items["E09"]["trigger"],
            {
                "kind": "explicit-authority",
                "authority_ids": ["A-V4", "A-V8"],
            },
        )

    def test_unsupported_changed_path_fails_f02(self) -> None:
        authority = copy.deepcopy(self.authority)
        authority["changed_paths"].append("MyRAM/Unmapped.swift")
        self.assert_failure("F02", authority)

    def test_noncanonical_paths_fail_f02_without_repair(self) -> None:
        invalid_paths = [
            "./AGENTS.md",
            "/AGENTS.md",
            "docs//MYR-196-completion-verification-evidence.md",
            "docs/../AGENTS.md",
            "AGENTS.md/",
            r"MyRAM\Markdown\MarkdownPreview.swift",
        ]
        for path in invalid_paths:
            with self.subTest(path=path):
                authority = copy.deepcopy(self.authority)
                authority["changed_paths"] = [path]
                self.assert_failure("F02", authority)

    def test_f01_missing_or_imprecise_authority(self) -> None:
        missing = copy.deepcopy(self.authority)
        missing["authorities"] = [
            item for item in missing["authorities"] if item["id"] != "A-V8"
        ]
        self.assert_failure("F01", missing)

        imprecise = copy.deepcopy(self.authority)
        item = next(
            item for item in imprecise["authorities"] if item["id"] == "A-V4"
        )
        item["identity"]["timestamp"] = None
        self.assert_failure("F01", imprecise)

    def test_f03_conflicting_duplicate_authority(self) -> None:
        authority = copy.deepcopy(self.authority)
        duplicate = copy.deepcopy(
            next(item for item in authority["authorities"] if item["id"] == "A-V8")
        )
        duplicate["identity"]["timestamp"] = "2026-07-30T23:51:21Z"
        authority["authorities"].append(duplicate)
        self.assert_failure("F03", authority)

    def test_f04_candidate_drift(self) -> None:
        authority = copy.deepcopy(self.authority)
        authority["observed_current_candidate_sha"] = "0" * 40
        self.assert_failure("F04", authority)

    def test_all_failures_emit_no_usable_contract(self) -> None:
        cases: list[tuple[str, dict]] = []

        f01 = copy.deepcopy(self.authority)
        f01["authorities"] = [
            item for item in f01["authorities"] if item["id"] != "A-TICKET"
        ]
        cases.append(("F01", f01))

        f02 = copy.deepcopy(self.authority)
        f02["changed_paths"] = ["Unknown/File.swift"]
        cases.append(("F02", f02))

        f03 = copy.deepcopy(self.authority)
        conflict = copy.deepcopy(f03["authorities"][0])
        conflict["class"] = "frozen-external-authority"
        f03["authorities"].append(conflict)
        cases.append(("F03", f03))

        f04 = copy.deepcopy(self.authority)
        f04["observed_current_candidate_sha"] = "1" * 40
        cases.append(("F04", f04))

        for code, authority in cases:
            with self.subTest(code=code):
                result = self.run_cli(authority)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertIn(
                    f"{code}:",
                    result.stderr.decode("utf-8"),
                    result.stderr.decode("utf-8"),
                )

    def test_unmapped_obligation_fails_f02(self) -> None:
        rules = copy.deepcopy(self.rules)
        rules["verification_requirements"][0]["authority_ids"] = ["A-NOT-APPROVED"]
        with self.assertRaises(resolver.ContractError) as context:
            resolver.resolve_contract(rules, self.authority)
        self.assertEqual(context.exception.code, "F02")

    def assert_failure(self, code: str, authority: dict) -> None:
        with self.assertRaises(resolver.ContractError) as context:
            resolver.resolve_contract(self.rules, authority)
        self.assertEqual(context.exception.code, code)

    def run_cli(self, authority: dict) -> subprocess.CompletedProcess[bytes]:
        with tempfile.TemporaryDirectory() as temp:
            authority_path = Path(temp) / "authority.json"
            authority_path.write_text(
                json.dumps(authority, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "myram_verification_contract.py"),
                    "--rules",
                    str(RULES_PATH),
                    "--authority",
                    str(authority_path),
                ],
                cwd=ROOT,
                capture_output=True,
                check=False,
            )


if __name__ == "__main__":
    unittest.main()
