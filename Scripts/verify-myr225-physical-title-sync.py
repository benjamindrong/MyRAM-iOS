#!/usr/bin/env python3
"""MYR-225 preserved Test Host title-sync acceptance; physical iPhone + Mac queue."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

BRANCH = "MYR-225-Mac-editor-visual-parity-title-editing-and-stable-zoom-geometry"
REPOSITORY = "benjamindrong/MyRAM-iOS"
BLACKSMITH_SHA = "4109afce20c80fa5cc0ca67b799f36dd521268be"
IOS_BUNDLE = "com.northsignalstudio.myram.myr227.test.verification"
MAC_BUNDLE = "com.northsignalstudio.myram.mac.myr227.test.verification"
PROFILE = "myr227test"
TEST = "MyRAMUITests/MyRAMUITests/testMYR225PhysicalRetainedMacTitleArrivesAndSurvivesRestart"
DEFAULT_BATCH = "527E25AB-87D4-45DB-9504-FDB2A2329BA3"


def run(args, *, cwd=None, env=None, log=None, check=True):
    if log:
        with open(log, "wb") as output:
            process = subprocess.run(args, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
        result = subprocess.CompletedProcess(args, process.returncode, b"", b"")
    else:
        result = subprocess.run(args, cwd=cwd, env=env, capture_output=True)
    if check and result.returncode:
        detail = str(log) if log else result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"Command exited {result.returncode}: {args[0]} (details: {detail})")
    return result


def git(repo, *args):
    return run(["git", "-C", str(repo), *args]).stdout.decode().strip()


def snapshot_queue(path, batch_id, copy=None):
    raw = path.read_bytes()
    data = json.loads(raw)
    if data.get("version") != 2 or not isinstance(data.get("batches"), list):
        raise RuntimeError("Mac outgoing queue is not a supported, readable version-2 durable queue")
    ids = [b["id"].upper() for b in data["batches"]]
    if copy:
        copy.write_bytes(raw)
    return batch_id.upper() in ids, len(ids), hashlib.sha256(raw).hexdigest()


def physical_iphone(worktree):
    result = run(["xcodebuild", "-project", "MyRAM.xcodeproj", "-scheme", "MyRAM", "-showdestinations"], cwd=worktree)
    output = result.stdout.decode(errors="replace").split("Ineligible destinations")[0]
    candidates = []
    for block in re.findall(r"\{([^{}]+)\}", output):
        fields = dict((key.strip(), value.strip()) for key, value in re.findall(r"(\w+):\s*([^,}]+)", block))
        udid = fields.get("id", "")
        if fields.get("platform") == "iOS" and re.fullmatch(r"[A-Fa-f0-9-]{20,}", udid):
            candidates.append(udid)
    return sorted(set(candidates))


def archive_manifest(run_dir, identity, status):
    entries = []
    for path in sorted((run_dir / "raw").rglob("*")):
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
            entries.append({"path": str(path.relative_to(run_dir)), "sha256": digest.hexdigest(),
                            "size_bytes": path.stat().st_size})
    manifest = {"schema": "myram.myr225.physical-title-ui-evidence.v1",
                "identity": identity, "status": status, "raw_files": entries,
                "retention_state": "sealed" if status == "PASS" else "diagnostic"}
    target = run_dir / "manifests" / "run.json"
    target.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"evidence={run_dir}")
    print(f"manifest_sha256={hashlib.sha256(target.read_bytes()).hexdigest()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="/Users/Shared/Dev/MyRAM-iOS")
    parser.add_argument("--device-id", help="Existing physical iPhone UDID; auto-selects when exactly one is connected")
    parser.add_argument("--batch-id", default=DEFAULT_BATCH)
    parser.add_argument("--previous-title", default="ANOTHER NEW TITLE")
    parser.add_argument("--expected-title", default="ANOTHER NEW [Mac] TITLE")
    args = parser.parse_args()
    if not args.previous_title or not args.expected_title or args.previous_title == args.expected_title:
        parser.error("Distinct, nonempty previous/expected titles are required")
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", args.batch_id):
        parser.error("A canonical 36-character batch UUID is required")

    repo = Path(args.repo).resolve()
    evidence = Path("/Users/Shared/Dev/Evidence")
    volume = Path("/Volumes/DevArchive")
    if not os.path.ismount(volume) or not evidence.exists():
        raise RuntimeError("External DevArchive / canonical Evidence is not mounted")
    if not str(evidence.resolve()).startswith(str(volume.resolve()) + "/"):
        raise RuntimeError("Canonical Evidence must resolve onto the mounted DevArchive")
    if REPOSITORY.lower() not in git(repo, "remote", "get-url", "origin").lower():
        # HTTPS and SSH remote URLs both identify the exact same canonical repository.
        remote = git(repo, "remote", "get-url", "origin")
        if "benjamindrong/MyRAM-iOS" not in remote:
            raise RuntimeError("Repository origin is not benjamindrong/MyRAM-iOS")
    mac_app = Path.home() / "Applications" / "MyRAM MYR-227 Test Host.app"
    with (mac_app / "Contents" / "Info.plist").open("rb") as source:
        if plistlib.load(source).get("CFBundleIdentifier") != MAC_BUNDLE:
            raise RuntimeError("Existing Mac app does not have the registered MYR-227 Test Host identity")
    mac_queue = Path.home() / "Library" / "Application Support" / "MyRAM MYR227 Test Host" / "mac-unsent-batch-queue.json"
    if not mac_queue.is_file():
        raise RuntimeError("Existing Mac Test Host durable outgoing queue is missing")
    pending, _, _ = snapshot_queue(mac_queue, args.batch_id)
    if not pending:
        raise RuntimeError("The exact retained Mac batch is not pending; refusing a vacuous acceptance")

    remote_rows = git(repo, "ls-remote", "origin", f"refs/heads/{BRANCH}").splitlines()
    if len(remote_rows) != 1:
        raise RuntimeError("Unable to resolve the one published PR #176 branch head")
    candidate = remote_rows[0].split()[0]
    try:
        git(repo, "cat-file", "-e", f"{candidate}^{{commit}}")
    except RuntimeError:
        git(repo, "fetch", "origin", BRANCH)
    git(repo, "cat-file", "-e", f"{candidate}^{{commit}}")
    run_id = "MYR225-PHYSICAL-TITLE-UI-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = evidence / "MyRAM" / "MYR-225" / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    for folder in ("raw", "manifests", "metadata"):
        (run_dir / folder).mkdir()
    temp_root = volume / "TemporaryBuilds" / run_id
    temp_root.mkdir(parents=True, exist_ok=False)
    worktree = temp_root / "MyRAM-iOS"
    nearby_link = temp_root / "NearbySyncCore"
    derived = temp_root / "DerivedData"
    identity = {"candidate_sha": candidate, "blacksmith_sha": BLACKSMITH_SHA,
                "repository": REPOSITORY, "profile": PROFILE, "batch_id": args.batch_id,
                "previous_title": args.previous_title, "expected_title": args.expected_title}
    status = "BLOCKED"
    created_worktree = False
    cleanup_error = None

    print(f"runner=MYR225-PHYSICAL-TITLE-UI-v1 candidate={candidate}", flush=True)
    try:
        print("RUN: exact Test Host worktree and sibling dependency preflight", flush=True)
        nearby = repo.parent / "NearbySyncCore"
        if git(nearby, "remote", "get-url", "origin").split("/")[-1].removesuffix(".git") != "NearbySyncCore":
            raise RuntimeError("Expected NearbySyncCore sibling repository")
        if git(nearby, "rev-parse", "HEAD") != "4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2":
            raise RuntimeError("NearbySyncCore HEAD does not match the approved dependency identity")
        nearby_link.symlink_to(nearby, target_is_directory=True)
        git(repo, "worktree", "add", "--detach", str(worktree), candidate)
        created_worktree = True
        run(["python3", str(worktree / "Scripts" / "configure-myram-verification.py"),
             "--root", str(worktree), "--profile", PROFILE,
             "--manifest-output", str(run_dir / "metadata" / "verification-identity.json")])
        git(worktree, "diff", "--check")
        if git(worktree, "rev-parse", "HEAD") != candidate:
            raise RuntimeError("Verification checkout is not the exact candidate")
        (run_dir / "raw" / "mac-queue-before.json").write_bytes(mac_queue.read_bytes())

        devices = physical_iphone(worktree)
        selected = args.device_id if args.device_id in devices else (devices[0] if len(devices) == 1 and not args.device_id else None)
        if selected is None:
            raise RuntimeError("Exactly one available physical iPhone required, or specify --device-id from: " + ", ".join(devices))
        identity["iphone_udid"] = selected
        destination = f"platform=iOS,id={selected}"
        print(f"PASS: exact candidate and physical iPhone {selected}", flush=True)
        common = ["xcodebuild", "-project", "MyRAM.xcodeproj", "-scheme", "MyRAM",
                  "-configuration", "Debug", "-destination", destination,
                  "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO"]
        print("RUN: physical iPhone signed build-for-testing (external DerivedData)", flush=True)
        run(common + ["build-for-testing"], cwd=worktree, log=run_dir / "raw" / "xcode-build.log")
        built_app = derived / "Build" / "Products" / "Debug-iphoneos" / "MyRAM.app"
        with (built_app / "Info.plist").open("rb") as source:
            if plistlib.load(source).get("CFBundleIdentifier") != IOS_BUNDLE:
                raise RuntimeError("Built iPhone app identity does not match MYR-227 Test Host")
        run(["codesign", "--verify", "--deep", "--strict", str(built_app)])
        pending, _, _ = snapshot_queue(mac_queue, args.batch_id)
        if not pending:
            raise RuntimeError("Mac batch disappeared before the physical UI acceptance started")

        env = os.environ.copy()
        env.update({"TEST_RUNNER_MYR225_PHYSICAL_TITLE_SYNC": "1",
                    "TEST_RUNNER_MYR225_PREVIOUS_TITLE": args.previous_title,
                    "TEST_RUNNER_MYR225_EXPECTED_TITLE": args.expected_title})
        result_path = run_dir / "raw" / "physical-title.xcresult"
        print("RUN: candidate iPhone XCUITest (no UITEST_MODE or note mutations)", flush=True)
        run(common + ["-resultBundlePath", str(result_path),
                      "-only-testing:" + TEST, "test-without-building"],
            cwd=worktree, env=env, log=run_dir / "raw" / "xcode-ui-test.log")
        summary_bytes = run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                             "--path", str(result_path), "--format", "json"]).stdout
        (run_dir / "raw" / "xcresult-summary.json").write_bytes(summary_bytes)
        summary = json.loads(summary_bytes)
        if (int(summary.get("passedTests", 0)) != 1
                or int(summary.get("failedTests", -1)) != 0
                or int(summary.get("skippedTests", -1)) != 0):
            raise RuntimeError("XCUITest must have exactly one pass, zero failures, zero skips")

        print("RUN: verify durable Mac sender dequeue for captured batch", flush=True)
        deadline = time.monotonic() + 90
        while True:
            pending, depth, digest = snapshot_queue(mac_queue, args.batch_id)
            if not pending:
                (run_dir / "raw" / "mac-queue-after.json").write_bytes(mac_queue.read_bytes())
                identity["mac_queue_final_depth"] = depth
                identity["mac_queue_after_sha256"] = digest
                status = "PASS"
                print("PASS: retained title visible after iPhone restart; Mac durable batch dequeued", flush=True)
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Mac retained batch still pending after successful iPhone UI acceptance")
            time.sleep(2)
    except Exception as error:
        (run_dir / "raw" / "failure.txt").write_text(str(error) + "\n")
        print(f"BLOCKED: {error}", file=sys.stderr, flush=True)
    finally:
        # The worktree is owned by this run; preserve unfamiliar modifications,
        # never force-remove a worktree, and report any cleanup blocker.
        try:
            if created_worktree:
                manifest_path = run_dir / "metadata" / "verification-identity.json"
                expected = set(json.loads(manifest_path.read_text())["generated_changed_files"])
                observed = set(git(worktree, "diff", "--name-only").splitlines())
                if observed != expected:
                    raise RuntimeError("Unexpected worktree edits; preserving checkout for inspection")
                git(worktree, "restore", "--source=HEAD", "--worktree", "--", ".")
                git(repo, "worktree", "remove", str(worktree))
                if str(worktree) in git(repo, "worktree", "list", "--porcelain"):
                    raise RuntimeError("Removed worktree still registered in Git")
            if nearby_link.is_symlink():
                nearby_link.unlink()
            if not worktree.exists():
                shutil.rmtree(temp_root)
        except Exception as error:
            cleanup_error = str(error)
            print(f"CLEANUP BLOCKED: {cleanup_error}; preserved {temp_root}", file=sys.stderr)
        identity["worktree_cleanup"] = "PASS" if cleanup_error is None else "BLOCKED"
        archive_manifest(run_dir, identity, status if cleanup_error is None else "BLOCKED")
    return 0 if status == "PASS" and cleanup_error is None else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"BLOCKED before verification: {error}", file=sys.stderr)
        sys.exit(1)
