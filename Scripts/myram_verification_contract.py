#!/usr/bin/env python3
"""Resolve frozen MyRAM verification authority into a deterministic contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import PurePosixPath
from typing import Any

RULES_SCHEMA = "myram.verification-contract.rules.v1"
AUTHORITY_SCHEMA = "myram.verification-contract.authority.v1"
CONTRACT_SCHEMA = "myram.verification-contract.v1"
REPOSITORY = "benjamindrong/MyRAM-iOS"
TRIGGER_KINDS = {"always-required", "changed-area", "explicit-authority"}
AUTHORITY_CLASSES = {
    "pr-change-set",
    "repository-owned-rule",
    "frozen-external-authority",
}
SHA40 = re.compile(r"^[0-9a-f]{40}$")
FAIL_ORDER = ["F01", "F02", "F03", "F04"]


class ContractError(Exception):
    """Fail-closed resolver error carrying one canonical failure code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def fail(code: str, message: str) -> None:
    raise ContractError(code, message)


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def load_json(path: str, label: str) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail("F01", f"{label} cannot be frozen precisely: {error}")


def require_exact_keys(value: Any, expected: set[str], label: str, code: str = "F01") -> None:
    if not isinstance(value, dict) or set(value) != expected:
        fail(code, f"{label} must contain exactly {sorted(expected)}")


def require_sha(value: Any, label: str, code: str = "F01") -> str:
    if not isinstance(value, str) or SHA40.fullmatch(value) is None:
        fail(code, f"{label} must be a lowercase 40-hex SHA")
    return value


def require_id(value: Any, prefix: str, label: str, code: str = "F01") -> str:
    if not isinstance(value, str) or re.fullmatch(rf"{re.escape(prefix)}[0-9]{{2}}", value) is None:
        fail(code, f"{label} has invalid stable ID")
    return value


def require_canonical_path(value: Any, label: str, code: str = "F02") -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        fail(code, f"{label} is not a canonical repository-relative path")
    if "\\" in value or value.startswith("/") or value.endswith("/"):
        fail(code, f"{label} is not a canonical repository-relative path")
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        fail(code, f"{label} is not a canonical repository-relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value:
        fail(code, f"{label} is not a canonical repository-relative path")
    return value


def is_precise_identity(value: Any) -> bool:
    if value is None or isinstance(value, float):
        return False
    if isinstance(value, (str, bool, int)):
        return True
    if isinstance(value, list):
        return bool(value) and all(is_precise_identity(item) for item in value)
    if isinstance(value, dict):
        return bool(value) and all(
            isinstance(key, str) and key and is_precise_identity(item)
            for key, item in value.items()
        )
    return False


def validate_rules(rules: Any) -> dict[str, Any]:
    require_exact_keys(
        rules,
        {
            "schema",
            "repository",
            "authority_catalog",
            "predicates",
            "non_triggering_paths",
            "verification_requirements",
            "evidence_requirements",
            "fail_closed_conditions",
        },
        "rules",
    )
    if rules["schema"] != RULES_SCHEMA:
        fail("F01", f"rules schema must be {RULES_SCHEMA}")
    if rules["repository"] != REPOSITORY:
        fail("F01", f"rules repository must be {REPOSITORY}")

    authority_catalog: dict[str, str] = {}
    if not isinstance(rules["authority_catalog"], list) or not rules["authority_catalog"]:
        fail("F01", "rules authority_catalog must be non-empty")
    for index, item in enumerate(rules["authority_catalog"]):
        require_exact_keys(item, {"id", "class"}, f"authority_catalog[{index}]")
        authority_id = item["id"]
        authority_class = item["class"]
        if not isinstance(authority_id, str) or not authority_id.startswith("A-"):
            fail("F01", f"authority_catalog[{index}].id is invalid")
        if authority_class not in AUTHORITY_CLASSES:
            fail("F01", f"{authority_id} has unsupported authority class")
        prior = authority_catalog.get(authority_id)
        if prior is not None and prior != authority_class:
            fail("F03", f"{authority_id} has conflicting authority classes")
        if prior is not None:
            fail("F03", f"{authority_id} is duplicated in the rules authority catalog")
        authority_catalog[authority_id] = authority_class

    predicates: dict[str, tuple[str, ...]] = {}
    if not isinstance(rules["predicates"], list):
        fail("F01", "rules predicates must be a list")
    for index, predicate in enumerate(rules["predicates"]):
        require_exact_keys(predicate, {"id", "paths"}, f"predicates[{index}]")
        predicate_id = predicate["id"]
        if not isinstance(predicate_id, str) or not predicate_id.startswith("P-"):
            fail("F01", f"predicates[{index}].id is invalid")
        if predicate_id in predicates:
            fail("F03", f"{predicate_id} is duplicated")
        if not isinstance(predicate["paths"], list) or not predicate["paths"]:
            fail("F01", f"{predicate_id} must contain paths")
        paths = tuple(
            sorted(
                {
                    require_canonical_path(path, f"{predicate_id} path", "F01")
                    for path in predicate["paths"]
                }
            )
        )
        if len(paths) != len(predicate["paths"]):
            fail("F03", f"{predicate_id} contains duplicate paths")
        predicates[predicate_id] = paths

    if not isinstance(rules["non_triggering_paths"], list):
        fail("F01", "non_triggering_paths must be a list")
    non_triggering_paths = tuple(
        sorted(
            {
                require_canonical_path(path, "non-triggering path", "F01")
                for path in rules["non_triggering_paths"]
            }
        )
    )
    if len(non_triggering_paths) != len(rules["non_triggering_paths"]):
        fail("F03", "non_triggering_paths contains duplicates")

    def validate_requirements(raw: Any, prefix: str, label: str) -> list[dict[str, Any]]:
        if not isinstance(raw, list):
            fail("F01", f"{label} must be a list")
        seen: set[str] = set()
        validated: list[dict[str, Any]] = []
        for index, item in enumerate(raw):
            require_exact_keys(
                item,
                {"id", "definition", "definition_authority_id", "trigger", "authority_ids"},
                f"{label}[{index}]",
            )
            item_id = require_id(item["id"], prefix, f"{label}[{index}].id")
            if item_id in seen:
                fail("F03", f"{item_id} is duplicated")
            seen.add(item_id)
            if not isinstance(item["definition"], str) or not item["definition"].strip():
                fail("F01", f"{item_id} definition is empty")
            definition_authority_id = item["definition_authority_id"]
            if definition_authority_id not in authority_catalog:
                fail("F02", f"{item_id} definition authority is unmapped")
            if not isinstance(item["authority_ids"], list) or not item["authority_ids"]:
                fail("F02", f"{item_id} has no authority provenance")
            authority_ids = sorted(set(item["authority_ids"]))
            if len(authority_ids) != len(item["authority_ids"]):
                fail("F03", f"{item_id} has duplicate authority provenance")
            for authority_id in authority_ids:
                if authority_id not in authority_catalog:
                    fail("F02", f"{item_id} references unmapped authority {authority_id}")

            trigger = item["trigger"]
            if not isinstance(trigger, dict):
                fail("F02", f"{item_id} trigger is malformed")
            kind = trigger.get("kind")
            if kind not in TRIGGER_KINDS:
                fail("F02", f"{item_id} has unsupported trigger")
            if kind == "always-required":
                require_exact_keys(trigger, {"kind"}, f"{item_id} trigger", "F02")
            elif kind == "changed-area":
                require_exact_keys(trigger, {"kind", "predicate"}, f"{item_id} trigger", "F02")
                if trigger["predicate"] not in predicates:
                    fail("F02", f"{item_id} references unmapped predicate")
            else:
                require_exact_keys(trigger, {"kind", "authority_ids"}, f"{item_id} trigger", "F02")
                explicit_ids = trigger["authority_ids"]
                if not isinstance(explicit_ids, list) or not explicit_ids:
                    fail("F02", f"{item_id} explicit-authority trigger is empty")
                if sorted(set(explicit_ids)) != sorted(explicit_ids):
                    fail("F03", f"{item_id} explicit-authority trigger has duplicates")
                for authority_id in explicit_ids:
                    if authority_id not in authority_catalog:
                        fail("F02", f"{item_id} explicit trigger is unmapped")
            normalized_trigger = json.loads(canonical_bytes(trigger))
            if kind == "explicit-authority":
                normalized_trigger["authority_ids"] = sorted(trigger["authority_ids"])
            normalized = {
                "id": item_id,
                "definition": item["definition"],
                "definition_authority_id": definition_authority_id,
                "trigger": normalized_trigger,
                "authority_ids": authority_ids,
            }
            validated.append(normalized)
        return validated

    verification = validate_requirements(
        rules["verification_requirements"], "V", "verification_requirements"
    )
    evidence = validate_requirements(
        rules["evidence_requirements"], "E", "evidence_requirements"
    )

    fail_conditions = rules["fail_closed_conditions"]
    if not isinstance(fail_conditions, list) or len(fail_conditions) != 4:
        fail("F01", "fail_closed_conditions must contain exactly F01-F04")
    validated_fail: list[dict[str, Any]] = []
    for index, item in enumerate(fail_conditions):
        require_exact_keys(
            item,
            {"id", "definition", "definition_authority_id"},
            f"fail_closed_conditions[{index}]",
        )
        if item["id"] != FAIL_ORDER[index]:
            fail("F01", "fail_closed_conditions must preserve F01-F04 order")
        if not isinstance(item["definition"], str) or not item["definition"].strip():
            fail("F01", f"{item['id']} definition is empty")
        if item["definition_authority_id"] not in authority_catalog:
            fail("F02", f"{item['id']} definition authority is unmapped")
        validated_fail.append(dict(item))

    return {
        "schema": rules["schema"],
        "repository": rules["repository"],
        "authority_catalog": authority_catalog,
        "predicates": predicates,
        "non_triggering_paths": non_triggering_paths,
        "verification_requirements": verification,
        "evidence_requirements": evidence,
        "fail_closed_conditions": validated_fail,
    }


def validate_authority(
    authority: Any,
    rules: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    require_exact_keys(
        authority,
        {
            "schema",
            "repository",
            "base_sha",
            "frozen_candidate_sha",
            "observed_current_candidate_sha",
            "changed_paths",
            "authorities",
        },
        "authority",
    )
    if authority["schema"] != AUTHORITY_SCHEMA:
        fail("F01", f"authority schema must be {AUTHORITY_SCHEMA}")
    if authority["repository"] != REPOSITORY or authority["repository"] != rules["repository"]:
        fail("F01", f"authority repository must be {REPOSITORY}")

    base_sha = require_sha(authority["base_sha"], "base_sha")
    candidate_sha = require_sha(authority["frozen_candidate_sha"], "frozen_candidate_sha")
    observed_sha = require_sha(
        authority["observed_current_candidate_sha"],
        "observed_current_candidate_sha",
        "F04",
    )
    if observed_sha != candidate_sha:
        fail("F04", "observed current candidate differs from the frozen candidate")

    if not isinstance(authority["changed_paths"], list):
        fail("F02", "changed_paths must be a list")
    changed_paths = sorted(
        {
            require_canonical_path(path, "changed path")
            for path in authority["changed_paths"]
        }
    )

    raw_authorities = authority["authorities"]
    if not isinstance(raw_authorities, list):
        fail("F01", "authorities must be a list")
    by_id: dict[str, dict[str, Any]] = {}
    identity_owners: dict[bytes, tuple[str, str]] = {}
    for index, item in enumerate(raw_authorities):
        require_exact_keys(item, {"id", "class", "identity"}, f"authorities[{index}]")
        authority_id = item["id"]
        authority_class = item["class"]
        if not isinstance(authority_id, str) or not authority_id.startswith("A-"):
            fail("F01", f"authorities[{index}].id is invalid")
        expected_class = rules["authority_catalog"].get(authority_id)
        if expected_class is None:
            fail("F02", f"authority {authority_id} is not approved")
        if authority_class != expected_class:
            fail("F03", f"authority {authority_id} has conflicting class")
        if not is_precise_identity(item["identity"]):
            fail("F01", f"authority {authority_id} cannot be frozen precisely")

        normalized = {
            "id": authority_id,
            "class": authority_class,
            "identity": item["identity"],
        }
        prior = by_id.get(authority_id)
        if prior is not None:
            if canonical_bytes(prior) == canonical_bytes(normalized):
                continue
            fail("F03", f"authority {authority_id} has conflicting duplicate identity/class")

        identity_key = canonical_bytes(item["identity"])
        prior_owner = identity_owners.get(identity_key)
        if prior_owner is not None and prior_owner != (authority_id, authority_class):
            fail("F03", "the same immutable authority identity has conflicting ownership")
        identity_owners[identity_key] = (authority_id, authority_class)
        by_id[authority_id] = normalized

    missing = sorted(set(rules["authority_catalog"]) - set(by_id))
    if missing:
        fail("F01", f"required authority is missing: {', '.join(missing)}")

    for item in by_id.values():
        authority_class = item["class"]
        identity = item["identity"]
        if authority_class == "pr-change-set":
            require_exact_keys(
                identity,
                {"repository", "pr_number", "base_sha", "candidate_sha"},
                f"{item['id']} identity",
            )
            if identity["repository"] != REPOSITORY:
                fail("F01", f"{item['id']} repository identity drifted")
            if not isinstance(identity["pr_number"], int) or isinstance(identity["pr_number"], bool):
                fail("F01", f"{item['id']} pr_number is invalid")
            if require_sha(identity["base_sha"], f"{item['id']} base_sha") != base_sha:
                fail("F01", f"{item['id']} base SHA conflicts with frozen candidate")
            if require_sha(identity["candidate_sha"], f"{item['id']} candidate_sha") != candidate_sha:
                fail("F01", f"{item['id']} candidate SHA conflicts with frozen candidate")
        elif authority_class == "repository-owned-rule":
            require_exact_keys(
                identity,
                {"repository", "path", "blob_sha"},
                f"{item['id']} identity",
            )
            if identity["repository"] != REPOSITORY:
                fail("F01", f"{item['id']} repository identity drifted")
            require_canonical_path(identity["path"], f"{item['id']} identity path", "F01")
            require_sha(identity["blob_sha"], f"{item['id']} blob_sha")

    supported_paths = set(rules["non_triggering_paths"])
    for paths in rules["predicates"].values():
        supported_paths.update(paths)
    unsupported = sorted(set(changed_paths) - supported_paths)
    if unsupported:
        fail("F02", f"unsupported or unmapped changed path: {unsupported[0]}")

    return by_id, changed_paths


def requirement_selected(
    requirement: dict[str, Any],
    authorities: dict[str, dict[str, Any]],
    changed_paths: set[str],
    predicates: dict[str, tuple[str, ...]],
) -> bool:
    trigger = requirement["trigger"]
    kind = trigger["kind"]
    if kind == "always-required":
        return True
    if kind == "changed-area":
        return bool(changed_paths.intersection(predicates[trigger["predicate"]]))
    if kind == "explicit-authority":
        return all(authority_id in authorities for authority_id in trigger["authority_ids"])
    fail("F02", f"{requirement['id']} has unsupported trigger")


def contract_requirement(requirement: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": requirement["id"],
        "definition": requirement["definition"],
        "definition_authority_id": requirement["definition_authority_id"],
        "trigger": requirement["trigger"],
        "authority_ids": requirement["authority_ids"],
    }


def resolve_contract(rules_raw: Any, authority_raw: Any) -> dict[str, Any]:
    rules = validate_rules(rules_raw)
    authorities, changed_paths = validate_authority(authority_raw, rules)
    changed_set = set(changed_paths)

    verification = [
        contract_requirement(requirement)
        for requirement in rules["verification_requirements"]
        if requirement_selected(
            requirement, authorities, changed_set, rules["predicates"]
        )
    ]
    evidence = [
        contract_requirement(requirement)
        for requirement in rules["evidence_requirements"]
        if requirement_selected(
            requirement, authorities, changed_set, rules["predicates"]
        )
    ]
    verification.sort(key=lambda item: item["id"])
    evidence.sort(key=lambda item: item["id"])

    contract: dict[str, Any] = {
        "schema": CONTRACT_SCHEMA,
        "rules_schema": rules["schema"],
        "repository": authority_raw["repository"],
        "candidate": {
            "base_sha": authority_raw["base_sha"],
            "sha": authority_raw["frozen_candidate_sha"],
        },
        "changed_paths": changed_paths,
        "authorities": sorted(authorities.values(), key=lambda item: item["id"]),
        "verification_requirements": verification,
        "evidence_requirements": evidence,
        "fail_closed_conditions": rules["fail_closed_conditions"],
    }
    contract["contract_sha256"] = hashlib.sha256(canonical_bytes(contract)).hexdigest()
    return contract


def render_contract(contract: dict[str, Any]) -> bytes:
    return canonical_bytes(contract) + b"\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Resolve frozen MyRAM verification authority into an immutable contract."
    )
    parser.add_argument("--rules", required=True)
    parser.add_argument("--authority", required=True)
    args = parser.parse_args(argv)

    try:
        rules = load_json(args.rules, "rules")
        authority = load_json(args.authority, "authority")
        sys.stdout.buffer.write(render_contract(resolve_contract(rules, authority)))
        return 0
    except ContractError as error:
        print(f"{error.code}: {error.message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
