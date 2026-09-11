#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

PRODUCTION = {
    "ios_app_bundle_ids": [
        "com.northsignalstudio.myram.dev",
        "com.northsignalstudio.myram",
    ],
    "ios_widget_bundle_ids": [
        "com.northsignalstudio.myram.dev.widget",
        "com.northsignalstudio.myram.widget",
    ],
    "ios_app_groups": [
        "group.com.northsignalstudio.myram.dev.widget",
        "group.com.northsignalstudio.myram.widget",
    ],
    "mac_app_bundle_ids": [
        "com.northsignalstudio.myram.mac.dev",
        "com.northsignalstudio.myram.mac",
    ],
    "mac_widget_bundle_ids": [
        "com.northsignalstudio.myram.mac.dev.widget",
        "com.northsignalstudio.myram.mac.widget",
    ],
    "mac_app_groups": [
        "group.com.northsignalstudio.myram.mac.dev.widget",
        "group.com.northsignalstudio.myram.mac.widget",
    ],
    "storage_root_name": "MyRAM",
    "swiftdata_store_name": "MyRAM_Main",
    "multipeer_service_type": "myram-sync",
    "bonjour_service": "_myram-sync._tcp",
    "ios_url_scheme": "myram",
    "macos_url_scheme": "myram-mac",
}

EXPECTED_STORAGE_ROOT_FILES = {
    "MyRAM/Mac/Sync/MacLegacySyncReceiver.swift",
    "MyRAM/Mac/Sync/MacSyncBatchController.swift",
    "MyRAM/Sync/AnchoredSequence/FileBackedSyncOperationIDReservationStore.swift",
    "MyRAM/Sync/Batch/FileBackedSyncBatchAnchoredRecoveryStore.swift",
    "MyRAM/Sync/Batch/SyncBatchPayload.swift",
    "MyRAM/Sync/MyRAMSyncController.swift",
    "MyRAM/Sync/MyRAMSyncModels.swift",
    "MyRAM/Sync/Recovery/PendingSyncRecoveryJournal.swift",
    "MyRAM/Sync/SyncConflictStore.swift",
}

FIXED_CHANGED_FILES = {
    "MyRAM.xcodeproj/project.pbxproj",
    "MyRAM/Info.plist",
    "MyRAM/Mac/Info.plist",
    "MyRAM/PersistenceManager.swift",
    "MyRAM/WidgetShared/MyRAMWidgetDeepLink.swift",
    "MyRAM/Sync/MyRAMSyncController.swift",
    "MyRAM/Mac/Sync/MacSyncBatchController.swift",
}


class ConfigurationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ConfigurationError(message)


def run_git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        fail(
            f"git {' '.join(args)} failed ({result.returncode}): "
            f"{result.stderr.strip()}"
        )
    return result.stdout.strip()


def load_identity(root: Path) -> dict[str, Any]:
    path = root / "Scripts" / "myram-verification-identities.json"
    try:
        identity = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Unable to load verification identity manifest: {error}")

    required = [
        "environment",
        "display_name",
        "storage_root_name",
        "swiftdata_store_name",
        "multipeer_service_type",
        "bonjour_service",
        "ios",
        "macos",
    ]
    missing = [key for key in required if not identity.get(key)]
    if missing:
        fail(f"Verification identity manifest missing: {', '.join(missing)}")
    if identity["environment"] != "verification":
        fail("Verification manifest environment must be exactly 'verification'.")

    service = identity["multipeer_service_type"]
    if len(service) > 15 or re.fullmatch(r"[a-z0-9-]+", service) is None:
        fail("Multipeer service type must be <=15 lowercase ASCII letters/digits/hyphens.")
    if identity["bonjour_service"] != f"_{service}._tcp":
        fail("Bonjour service must exactly match the Multipeer service type.")

    ios = identity["ios"]
    macos = identity["macos"]
    for platform, values in (("ios", ios), ("macos", macos)):
        for key in (
            "app_bundle_identifier",
            "widget_bundle_identifier",
            "widget_app_group_identifier",
            "url_scheme",
        ):
            if not values.get(key):
                fail(f"Verification manifest {platform}.{key} is required.")

    production_values = {
        *PRODUCTION["ios_app_bundle_ids"],
        *PRODUCTION["ios_widget_bundle_ids"],
        *PRODUCTION["ios_app_groups"],
        *PRODUCTION["mac_app_bundle_ids"],
        *PRODUCTION["mac_widget_bundle_ids"],
        *PRODUCTION["mac_app_groups"],
        PRODUCTION["storage_root_name"],
        PRODUCTION["swiftdata_store_name"],
        PRODUCTION["multipeer_service_type"],
        PRODUCTION["ios_url_scheme"],
        PRODUCTION["macos_url_scheme"],
    }
    verification_values = {
        ios["app_bundle_identifier"],
        ios["widget_bundle_identifier"],
        ios["widget_app_group_identifier"],
        macos["app_bundle_identifier"],
        macos["widget_bundle_identifier"],
        macos["widget_app_group_identifier"],
        identity["storage_root_name"],
        identity["swiftdata_store_name"],
        identity["multipeer_service_type"],
        ios["url_scheme"],
        macos["url_scheme"],
    }
    overlap = production_values & verification_values
    if overlap:
        fail(f"Verification identities collide with Production: {sorted(overlap)}")
    if ios["widget_app_group_identifier"] == macos["widget_app_group_identifier"]:
        fail("iOS and macOS Verification App Groups must remain platform-isolated.")

    return identity


def require_disposable_detached_worktree(root: Path) -> str:
    dot_git = root / ".git"
    if not dot_git.is_file():
        fail(
            "Refusing to mutate this checkout. Verification configuration may run "
            "only inside a disposable Git worktree whose .git entry is a file."
        )
    if run_git(root, "rev-parse", "--abbrev-ref", "HEAD") != "HEAD":
        fail("Verification worktree must be detached at an immutable source commit.")
    if run_git(root, "status", "--porcelain"):
        fail("Verification worktree must be clean before configuration.")
    return run_git(root, "rev-parse", "HEAD")


def replace_required(path: Path, old: str, new: str, *, minimum: int = 1) -> int:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count < minimum:
        fail(f"{path}: expected at least {minimum} occurrence(s) of {old!r}, found {count}.")
    path.write_text(text.replace(old, new), encoding="utf-8")
    return count


def configure_project(root: Path, identity: dict[str, Any]) -> None:
    project = root / "MyRAM.xcodeproj" / "project.pbxproj"
    ios = identity["ios"]
    macos = identity["macos"]

    replacements = []
    replacements.extend(
        (
            f"PRODUCT_BUNDLE_IDENTIFIER = {old};",
            f"PRODUCT_BUNDLE_IDENTIFIER = {ios['app_bundle_identifier']};",
        )
        for old in PRODUCTION["ios_app_bundle_ids"]
    )
    replacements.extend(
        (
            f"PRODUCT_BUNDLE_IDENTIFIER = {old};",
            f"PRODUCT_BUNDLE_IDENTIFIER = {ios['widget_bundle_identifier']};",
        )
        for old in PRODUCTION["ios_widget_bundle_ids"]
    )
    replacements.extend(
        (
            f"MYRAM_WIDGET_APP_GROUP_IDENTIFIER = {old};",
            f"MYRAM_WIDGET_APP_GROUP_IDENTIFIER = {ios['widget_app_group_identifier']};",
        )
        for old in PRODUCTION["ios_app_groups"]
    )
    replacements.extend(
        (
            f"PRODUCT_BUNDLE_IDENTIFIER = {old};",
            f"PRODUCT_BUNDLE_IDENTIFIER = {macos['app_bundle_identifier']};",
        )
        for old in PRODUCTION["mac_app_bundle_ids"]
    )
    replacements.extend(
        (
            f"PRODUCT_BUNDLE_IDENTIFIER = {old};",
            f"PRODUCT_BUNDLE_IDENTIFIER = {macos['widget_bundle_identifier']};",
        )
        for old in PRODUCTION["mac_widget_bundle_ids"]
    )
    replacements.extend(
        (
            f"MYRAM_WIDGET_APP_GROUP_IDENTIFIER = {old};",
            f"MYRAM_WIDGET_APP_GROUP_IDENTIFIER = {macos['widget_app_group_identifier']};",
        )
        for old in PRODUCTION["mac_app_groups"]
    )

    for old, new in replacements:
        replace_required(project, old, new)

    replace_required(
        project,
        "INFOPLIST_KEY_CFBundleDisplayName = MyRAM;",
        f'INFOPLIST_KEY_CFBundleDisplayName = "{identity["display_name"]}";',
    )
    replace_required(
        project,
        "INFOPLIST_KEY_CFBundleDisplayName = MyRAMMac;",
        f'INFOPLIST_KEY_CFBundleDisplayName = "{identity["display_name"]}";',
    )


def configure_plists(root: Path, identity: dict[str, Any]) -> None:
    ios_path = root / "MyRAM" / "Info.plist"
    with ios_path.open("rb") as handle:
        ios_plist = plistlib.load(handle)
    if ios_plist.get("NSBonjourServices") != [PRODUCTION["bonjour_service"]]:
        fail("iOS Info.plist Production Bonjour identity drifted.")
    url_types = ios_plist.get("CFBundleURLTypes")
    if not isinstance(url_types, list) or not url_types:
        fail("iOS Info.plist URL registration is missing.")
    if url_types[0].get("CFBundleURLSchemes") != [PRODUCTION["ios_url_scheme"]]:
        fail("iOS Info.plist Production URL scheme drifted.")

    ios = identity["ios"]
    ios_plist["CFBundleDisplayName"] = identity["display_name"]
    ios_plist["NSBonjourServices"] = [identity["bonjour_service"]]
    url_types[0]["CFBundleURLSchemes"] = [ios["url_scheme"]]

    exported = ios_plist.get("UTExportedTypeDeclarations")
    document_types = ios_plist.get("CFBundleDocumentTypes")
    if not isinstance(exported, list) or len(exported) != 1:
        fail("iOS export type declaration shape drifted.")
    if not isinstance(document_types, list) or not document_types:
        fail("iOS document type declaration shape drifted.")
    export = exported[0]
    export["UTTypeIdentifier"] = ios["export_type_identifier"]
    export["UTTypeDescription"] = "MyRAM Verification Export"
    tag_spec = export.get("UTTypeTagSpecification")
    if not isinstance(tag_spec, dict):
        fail("iOS export tag specification is missing.")
    tag_spec["public.filename-extension"] = [ios["export_filename_extension"]]
    tag_spec["public.mime-type"] = ios["export_mime_type"]

    document_types[0]["CFBundleTypeExtensions"] = [ios["export_filename_extension"]]
    document_types[0]["CFBundleTypeName"] = "MyRAM Verification Export"
    document_types[0]["LSItemContentTypes"] = [ios["export_type_identifier"]]

    with ios_path.open("wb") as handle:
        plistlib.dump(ios_plist, handle, fmt=plistlib.FMT_XML, sort_keys=False)

    mac_path = root / "MyRAM" / "Mac" / "Info.plist"
    with mac_path.open("rb") as handle:
        mac_plist = plistlib.load(handle)
    if mac_plist.get("NSBonjourServices") != [PRODUCTION["bonjour_service"]]:
        fail("macOS Info.plist Production Bonjour identity drifted.")
    mac_url_types = mac_plist.get("CFBundleURLTypes")
    if not isinstance(mac_url_types, list) or not mac_url_types:
        fail("macOS Info.plist URL registration is missing.")
    if mac_url_types[0].get("CFBundleURLSchemes") != [PRODUCTION["macos_url_scheme"]]:
        fail("macOS Info.plist Production URL scheme drifted.")

    macos = identity["macos"]
    mac_plist["CFBundleDisplayName"] = identity["display_name"]
    mac_plist["NSBonjourServices"] = [identity["bonjour_service"]]
    mac_url_types[0]["CFBundleURLSchemes"] = [macos["url_scheme"]]

    with mac_path.open("wb") as handle:
        plistlib.dump(mac_plist, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def configure_storage_roots(root: Path, identity: dict[str, Any]) -> None:
    token = '.appendingPathComponent("MyRAM", isDirectory: true)'
    replacement = (
        f'.appendingPathComponent("{identity["storage_root_name"]}", isDirectory: true)'
    )
    found: set[str] = set()
    myram_root = root / "MyRAM"
    for path in sorted(myram_root.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        if token not in text:
            continue
        relative = path.relative_to(root).as_posix()
        found.add(relative)
        path.write_text(text.replace(token, replacement), encoding="utf-8")

    if found != EXPECTED_STORAGE_ROOT_FILES:
        fail(
            "Application Support topology drifted. "
            f"Expected {sorted(EXPECTED_STORAGE_ROOT_FILES)}, found {sorted(found)}."
        )


def configure_runtime_identities(root: Path, identity: dict[str, Any]) -> None:
    service = identity["multipeer_service_type"]
    for relative in (
        "MyRAM/Sync/MyRAMSyncController.swift",
        "MyRAM/Mac/Sync/MacSyncBatchController.swift",
    ):
        replace_required(
            root / relative,
            'private let serviceType = "myram-sync"',
            f'private let serviceType = "{service}"',
        )

    deep_link = root / "MyRAM" / "WidgetShared" / "MyRAMWidgetDeepLink.swift"
    replace_required(
        deep_link,
        'case .iOS: "myram"',
        f'case .iOS: "{identity["ios"]["url_scheme"]}"',
    )
    replace_required(
        deep_link,
        'case .macOS: "myram-mac"',
        f'case .macOS: "{identity["macos"]["url_scheme"]}"',
    )

    persistence = root / "MyRAM" / "PersistenceManager.swift"
    replace_required(
        persistence,
        '"MyRAM_Main"',
        f'"{identity["swiftdata_store_name"]}"',
    )


def audit(root: Path, identity: dict[str, Any], source_sha: str) -> dict[str, Any]:
    project = root / "MyRAM.xcodeproj" / "project.pbxproj"
    project_text = project.read_text(encoding="utf-8")
    ios = identity["ios"]
    macos = identity["macos"]

    for old in (
        *PRODUCTION["ios_app_bundle_ids"],
        *PRODUCTION["ios_widget_bundle_ids"],
        *PRODUCTION["mac_app_bundle_ids"],
        *PRODUCTION["mac_widget_bundle_ids"],
    ):
        if f"PRODUCT_BUNDLE_IDENTIFIER = {old};" in project_text:
            fail(f"Generated project still contains Production bundle identity {old}.")
    for old in (*PRODUCTION["ios_app_groups"], *PRODUCTION["mac_app_groups"]):
        if f"MYRAM_WIDGET_APP_GROUP_IDENTIFIER = {old};" in project_text:
            fail(f"Generated project still contains Production App Group {old}.")

    for value in (
        ios["app_bundle_identifier"],
        ios["widget_bundle_identifier"],
        ios["widget_app_group_identifier"],
        macos["app_bundle_identifier"],
        macos["widget_bundle_identifier"],
        macos["widget_app_group_identifier"],
    ):
        if value not in project_text:
            fail(f"Generated project is missing Verification identity {value}.")

    for relative in (
        "MyRAM/Sync/MyRAMSyncController.swift",
        "MyRAM/Mac/Sync/MacSyncBatchController.swift",
    ):
        text = (root / relative).read_text(encoding="utf-8")
        expected = f'private let serviceType = "{identity["multipeer_service_type"]}"'
        if expected not in text or 'private let serviceType = "myram-sync"' in text:
            fail(f"{relative}: Multipeer namespace isolation audit failed.")

    deep_link_text = (
        root / "MyRAM" / "WidgetShared" / "MyRAMWidgetDeepLink.swift"
    ).read_text(encoding="utf-8")
    if f'case .iOS: "{ios["url_scheme"]}"' not in deep_link_text:
        fail("Generated iOS deep-link identity is missing.")
    if f'case .macOS: "{macos["url_scheme"]}"' not in deep_link_text:
        fail("Generated macOS deep-link identity is missing.")
    if 'case .iOS: "myram"' in deep_link_text or 'case .macOS: "myram-mac"' in deep_link_text:
        fail("Generated deep-link source still contains a Production scheme.")

    persistence_text = (root / "MyRAM" / "PersistenceManager.swift").read_text(
        encoding="utf-8"
    )
    if f'"{identity["swiftdata_store_name"]}"' not in persistence_text:
        fail("Generated SwiftData store identity is missing.")
    if '"MyRAM_Main"' in persistence_text:
        fail("Generated persistence source still contains the Production store identity.")

    production_root_token = '.appendingPathComponent("MyRAM", isDirectory: true)'
    verification_root_token = (
        f'.appendingPathComponent("{identity["storage_root_name"]}", isDirectory: true)'
    )
    for relative in EXPECTED_STORAGE_ROOT_FILES:
        text = (root / relative).read_text(encoding="utf-8")
        if production_root_token in text:
            fail(f"{relative}: Production Application Support root remains.")
        if verification_root_token not in text:
            fail(f"{relative}: Verification Application Support root is missing.")

    with (root / "MyRAM" / "Info.plist").open("rb") as handle:
        ios_plist = plistlib.load(handle)
    if ios_plist.get("CFBundleDisplayName") != identity["display_name"]:
        fail("iOS Verification display name audit failed.")
    if ios_plist.get("NSBonjourServices") != [identity["bonjour_service"]]:
        fail("iOS Verification Bonjour namespace audit failed.")
    if ios_plist["CFBundleURLTypes"][0]["CFBundleURLSchemes"] != [ios["url_scheme"]]:
        fail("iOS Verification URL scheme audit failed.")

    with (root / "MyRAM" / "Mac" / "Info.plist").open("rb") as handle:
        mac_plist = plistlib.load(handle)
    if mac_plist.get("CFBundleDisplayName") != identity["display_name"]:
        fail("macOS Verification display name audit failed.")
    if mac_plist.get("NSBonjourServices") != [identity["bonjour_service"]]:
        fail("macOS Verification Bonjour namespace audit failed.")
    if mac_plist["CFBundleURLTypes"][0]["CFBundleURLSchemes"] != [macos["url_scheme"]]:
        fail("macOS Verification URL scheme audit failed.")

    changed_files = {
        line
        for line in run_git(root, "diff", "--name-only").splitlines()
        if line.strip()
    }
    expected_changed_files = FIXED_CHANGED_FILES | EXPECTED_STORAGE_ROOT_FILES
    if changed_files != expected_changed_files:
        fail(
            "Generated change surface drifted. "
            f"Expected {sorted(expected_changed_files)}, got {sorted(changed_files)}."
        )

    if run_git(root, "diff", "--check"):
        fail("Generated Verification diff failed git diff --check.")

    return {
        "source_candidate_sha": source_sha,
        "environment": identity["environment"],
        "display_name": identity["display_name"],
        "application_identifiers": {
            "production_ios": PRODUCTION["ios_app_bundle_ids"],
            "verification_ios": ios["app_bundle_identifier"],
            "production_macos": PRODUCTION["mac_app_bundle_ids"],
            "verification_macos": macos["app_bundle_identifier"],
        },
        "app_groups": {
            "production_ios": PRODUCTION["ios_app_groups"],
            "verification_ios": ios["widget_app_group_identifier"],
            "production_macos": PRODUCTION["mac_app_groups"],
            "verification_macos": macos["widget_app_group_identifier"],
        },
        "storage": {
            "production_root": PRODUCTION["storage_root_name"],
            "verification_root": identity["storage_root_name"],
            "production_swiftdata_store": PRODUCTION["swiftdata_store_name"],
            "verification_swiftdata_store": identity["swiftdata_store_name"],
        },
        "multipeer": {
            "production_service_type": PRODUCTION["multipeer_service_type"],
            "verification_service_type": identity["multipeer_service_type"],
            "verification_bonjour_service": identity["bonjour_service"],
        },
        "deep_links": {
            "production_ios": PRODUCTION["ios_url_scheme"],
            "verification_ios": ios["url_scheme"],
            "production_macos": PRODUCTION["macos_url_scheme"],
            "verification_macos": macos["url_scheme"],
        },
        "generated_changed_files": sorted(changed_files),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Convert a clean detached MyRAM worktree into the isolated "
            "MyRAM Verification environment. Refuses to modify a primary checkout."
        )
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="Root of the disposable detached MyRAM worktree.",
    )
    parser.add_argument(
        "--manifest-output",
        type=Path,
        help="Optional path for the generated isolation audit JSON.",
    )
    args = parser.parse_args()
    root = args.root.resolve()

    try:
        source_sha = require_disposable_detached_worktree(root)
        identity = load_identity(root)
        configure_project(root, identity)
        configure_plists(root, identity)
        configure_storage_roots(root, identity)
        configure_runtime_identities(root, identity)
        report = audit(root, identity, source_sha)
        rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.manifest_output:
            args.manifest_output.parent.mkdir(parents=True, exist_ok=True)
            args.manifest_output.write_text(rendered, encoding="utf-8")
        sys.stdout.write(rendered)
        return 0
    except ConfigurationError as error:
        print(f"MYR-221 Verification configuration failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
