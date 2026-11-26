#!/usr/bin/env python3
"""Repeatable, exact-commit MyRAM native tests in the isolated Verification profile.

Examples:
  python3 Scripts/verify.py                     # iOS UI suite
  python3 Scripts/verify.py ui --only MyRAMUITests/MyRAMUITests/testNewNoteOpensWithoutAttachments
  python3 Scripts/verify.py ios --only MyRAMTests/EditorFormattingMutationApplierTests
  python3 Scripts/verify.py mac
  python3 Scripts/verify.py all
  python3 Scripts/verify.py physical-sync
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any

REPOSITORY = "benjamindrong/MyRAM-iOS"
DEPENDENCY = "benjamindrong/NearbySyncCore"
PROFILE = "automated"
SIMULATOR_ENV = "MYRAM_SIMULATOR_ID"
IDENTITY = "com.northsignalstudio.myram.automated.verification"
PHYSICAL_PROFILE = "myr371"
PHYSICAL_IOS_ID = "com.northsignalstudio.myram.myr371.transport.verification"
PHYSICAL_MAC_ID = "com.northsignalstudio.myram.mac.myr371.transport.verification"
PHYSICAL_TEST = "MyRAMUITests/MyRAMUITests/testMYR371PhysicalTransportPairAndReconnect"
PHYSICAL_DEVICE_ENV = "MYRAM_PHYSICAL_IPHONE_ID"
SYNC_PROFILE = "myr227test"
SYNC_IOS_ID = "com.northsignalstudio.myram.myr227.test.verification"
SYNC_MAC_ID = "com.northsignalstudio.myram.mac.myr227.test.verification"
SYNC_SERVICE = "_myr227-test._tcp"
SYNC_TEST = "MyRAMUITests/MyRAMUITests/testPhysicalApplicationSyncRoundTrip"
SYNC_RESTORE_TEST = "MyRAMUITests/MyRAMUITests/testPhysicalApplicationSyncOfflineRestoration"
PHYSICAL_SUITES = ("physical", "physical-sync")
SUITE_TARGETS = {"ui": "MyRAMUITests", "ios": "MyRAMTests", "mac": "MyRAMMacTests"}


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def run_output(*argv: str, cwd: Path | None = None) -> str:
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise VerificationError(f"{' '.join(argv)} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def normal_origin(url: str) -> str:
    value = url.strip().removesuffix(".git")
    for prefix in ("https://github.com/", "git@github.com:", "ssh://git@github.com/"):
        if value.startswith(prefix):
            return value[len(prefix):]
    return ""


def exact_repository(path: Path, expected: str) -> None:
    require(run_output("git", "-C", str(path), "rev-parse", "--show-toplevel") == str(path.resolve()),
            f"Unexpected Git root for {path}")
    origin = run_output("git", "-C", str(path), "remote", "get-url", "origin")
    require(normal_origin(origin) == expected, f"Repository origin does not match {expected}: {origin}")


def current_candidate(repo: Path) -> str:
    sha = run_output("git", "-C", str(repo), "rev-parse", "HEAD")
    require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "Invalid candidate SHA")
    status = run_output("git", "-C", str(repo), "status", "--porcelain=v1", "--untracked-files=all")
    require(not status, "Commit or remove local changes before producing exact-candidate evidence; no files modified")
    return sha


def pinned_nearby_sha(ci: str) -> str:
    # The repository-owned PR workflow is the source of truth for sibling identity.
    matches = re.findall(
        r"(?m)^\s*repository:\s*benjamindrong/NearbySyncCore\s*\n\s*ref:\s*([0-9a-f]{40})\s*$",
        ci,
    )
    require(len(matches) == 1, "Expected exactly one immutable NearbySyncCore pin in PR workflow")
    return matches[0]


def preflight_temurin17(home: Path) -> Path:
    root = home / ".gradle" / "jdks"
    for candidate in sorted(root.glob("*/jdk-17*/Contents/Home")):
        bins = [candidate / "bin" / n for n in ("java", "jlink", "jpackage")]
        if not all(p.is_file() and os.access(p, os.X_OK) for p in bins):
            continue
        version = subprocess.run([str(bins[0]), "-version"], text=True, capture_output=True, check=False)
        if version.returncode or not re.search(r'\bversion "17\.', version.stderr + version.stdout):
            continue
        if not re.search(r"Temurin|Eclipse Adoptium", version.stderr + version.stdout, re.I):
            continue
        if all(subprocess.run([str(binary), "--version"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, check=False).returncode == 0 for binary in bins[1:]):
            return candidate
    raise VerificationError(f"Existing compatible Temurin JDK 17 (java, jlink, jpackage) not found under {root}; provisioning prohibited")


def validate_only(suite: str, selectors: list[str]) -> None:
    require(not selectors or suite != "all", "--only requires exactly one suite: ui, ios, or mac")
    for selector in selectors:
        bits = selector.split("/")
        require(len(bits) in (2, 3) and bits[0] == SUITE_TARGETS[suite]
                and all(re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", part) for part in bits),
                f"Invalid test selector for {suite}: {selector}")
    chosen = set(selectors)
    require(len(chosen) == len(selectors), "Duplicate --only selector")
    for selector in selectors:
        bits = selector.split("/")
        require(len(bits) != 3 or "/".join(bits[:2]) not in chosen,
                f"Overlapping class and method --only selectors: {selector}")


def choose_simulator(devices_json: str, pinned: str | None) -> tuple[str, bool]:
    data = json.loads(devices_json)
    candidates = []
    for runtime, devices in data.get("devices", {}).items():
        if "SimRuntime.iOS-" not in runtime:
            continue
        for d in devices:
            if (d.get("isAvailable") and ("iPhone" in d.get("name", "") or d.get("name") == "MYRAM_SIMULATOR_ID")
                    and re.fullmatch(r"[0-9a-fA-F-]{36}", d.get("udid", ""))):
                candidates.append(d)
    require(candidates, "No existing available iOS iPhone simulator; none will be created")
    if pinned:
        chosen = next((d for d in candidates if d["udid"].lower() == pinned.lower()), None)
        require(chosen is not None, f"Pinned simulator {pinned} is not an available iOS iPhone device")
    else:
        candidates.sort(key=lambda d: (d["state"] != "Booted",
                                       d["name"] != "MYRAM_SIMULATOR_ID",
                                       d["name"] != "iPhone 17 Pro",
                                       d["name"], d["udid"]))
        chosen = candidates[0]
    return chosen["udid"], chosen["state"] == "Booted"


def choose_physical_iphone(destinations: str, pinned: str | None) -> str:
    available = destinations.split("Ineligible destinations", 1)[0]
    candidates = set()
    for entry in re.findall(r"\{([^{}\n]+)\}", available):
        fields = {}
        for part in entry.split(","):
            key, sep, value = part.strip().partition(":")
            if sep:
                fields[key] = value.strip()
        device = fields.get("id", "")
        if fields.get("platform") == "iOS" and re.fullmatch(r"[0-9a-fA-F-]{16,64}", device):
            candidates.add(device)
    require(candidates, "No available physical iOS device; no simulator may substitute")
    if pinned:
        match = next((device for device in candidates if device.lower() == pinned.lower()), None)
        require(match is not None, "Pinned physical iPhone is not an available Xcode destination")
        return match
    require(len(candidates) == 1, "Multiple physical iOS devices: set MYRAM_PHYSICAL_IPHONE_ID once")
    return next(iter(candidates))


def assert_myr371_mac_transport(log: str, expected_pid: int | None = None) -> None:
    events = []
    for line in log.splitlines():
        marker = "MYR233_TRANSPORT "
        if marker not in line:
            continue
        try:
            item = json.loads(line.split(marker, 1)[1])
        except json.JSONDecodeError as error:
            raise VerificationError("Malformed native Mac transport event") from error
        require(isinstance(item, dict) and item.get("mode") == "transportOnly",
                "Native Mac transport did not use the dedicated transport-only mode")
        if expected_pid is not None:
            require(item.get("pid") == expected_pid, "Mac transport event came from a different process")
        events.append(item)
    require(not any(e.get("event") in ("application.send", "application.received") for e in events),
            "Application synchronization was attempted in transport-only acceptance")
    # Every acceptance event must belong to the same retained MPC session and
    # diagnostics owner incarnation; combining unrelated sessions is not proof.
    def owner_key(event: dict) -> tuple[str, str, str]:
        return (event.get("incarnation", ""), event.get("session", ""), event.get("local", ""))

    created = {owner_key(e) for e in events if e.get("event") == "owner.created"}
    started = {owner_key(e) for e in events if e.get("event") == "networking.start"}
    valid_owners = {key for key in created.intersection(started) if all(key)}
    require(valid_owners, "No same-owner Mac transport creation and discovery found")
    invitations = {
        (*owner_key(e), e.get("peer", ""))
        for e in events if e.get("event") == "invitation.incoming.accepted"
        and owner_key(e) in valid_owners and e.get("peer")
    }
    sessions = {}
    for event in events:
        if event.get("event") == "session.state":
            key = (*owner_key(event), event.get("peer", ""))
            if key in invitations:
                sessions.setdefault(key, []).append(event.get("detail"))
    for states in sessions.values():
        stage = 0
        for state in states:
            if state == ("state=0" if stage == 1 else "state=2"):
                stage += 1
                if stage == 3:
                    return
    raise VerificationError("No single native Mac MCSession connected/disconnected/reconnected sequence found")


def validate_summary(output: str) -> dict[str, int]:
    data = json.loads(output)
    total = data.get("totalTestCount")
    failed = data.get("failedTests")
    result = data.get("result")
    require(type(total) is int and total > 0, "Test result contains zero or unreported tests")
    require(type(failed) is int and failed == 0 and result == "Passed",
            f"Test summary indicates failures: {result}, failedTests={failed}")
    passed = data.get("passedTests")
    skipped = data.get("skippedTests", 0)
    require(type(passed) is int and passed > 0,
            "Test summary has zero or unknown passed tests; skipped-only execution cannot pass")
    require(type(skipped) is int and skipped >= 0 and passed + skipped == total,
            "Test summary counts are inconsistent")
    return {"total": total, "failed": failed, "passed": passed, "skipped": skipped}


def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def artifacts_in(raw: Path) -> list[dict[str, Any]]:
    entries = []
    for file in sorted(raw.rglob("*")):
        require(not file.is_symlink(), f"Symlink artifact rejected: {file}")
        require(file.resolve().is_relative_to(raw.resolve()), f"Artifact escapes evidence root: {file}")
        if file.is_dir():
            continue
        require(file.is_file(), f"Nonregular artifact rejected: {file}")
        entries.append({"path": file.relative_to(raw.parent).as_posix(),
                        "size": file.stat().st_size, "sha256": sha_file(file)})
    return entries


def physical_xcode_readiness_failure(log: str) -> str | None:
    """Identify Xcode's explicit physical-device authorization blockers."""
    if (re.search(r"Unlock[^\r\n]*to Continue", log, re.I)
            or re.search(r"because the device is locked", log, re.I)):
        return "Physical iPhone is locked. Unlock it and keep it unlocked for Xcode UI-test setup; rerun only after user authorization."
    if re.search(r"Authentication canceled\.", log, re.I):
        return "Native Xcode UI-testing authentication was canceled; explicitly authorize it on the device before rerunning."
    return None


def stop_owned_process_group(process: subprocess.Popen) -> None:
    """Stop only the xcodebuild process group launched for this invocation."""
    if process.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def failure_excerpt(log: str) -> list[str]:
    lines = log.splitlines()
    # Xcode's post-failure device diagnostics can bury the actual assertion.
    # Prefer the native error lines; keep a bounded generic fallback.
    errors = [line.strip() for line in lines if re.search(
        r"(?i)(?:\berror:|\bfatal error:|\bXCTAssert\w* failed\b|\bfailed to tap\b)", line)]
    pending = [line.strip() for line in lines if "SYNC_DRAIN_PENDING:" in line]
    return (errors[-12:] if errors else lines[-28:]) + pending[-1:]


def print_sync_progress(log: Path) -> None:
    if not log.is_file():
        return
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("MYRAM_PHYSICAL_SYNC "):
            continue
        try:
            item = json.loads(line.removeprefix("MYRAM_PHYSICAL_SYNC "))
            if not isinstance(item, dict):
                continue
            event = item.get("event")
            if isinstance(event, str):
                print(f"MAC_SYNC_PHASE={event}" +
                      (f" reason={item.get('reason', 'unknown')}" if event == "failed" else ""),
                      flush=True)
        except ValueError:
            continue


class Evidence:
    def __init__(self, root: Path, sha: str, nearby: str, suite: str):
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.path = root / f"{stamp}-{os.getpid()}-{uuid.uuid4().hex[:8]}-{sha[:12]}"
        # Evidence itself may redirect to external storage; project and run roots may not.
        require(not root.is_symlink() and not root.parent.is_symlink(),
                "Nested evidence authority symlink")
        root.mkdir(parents=True, exist_ok=True)
        self.path.mkdir()  # refuse any competing/previous run identity
        self.raw = self.path / "raw"
        for folder in ("raw", "metadata", "manifests"):
            (self.path / folder).mkdir()
        self.started_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        self.sha = sha
        self.nearby = nearby
        self.suite = suite
        self.phases: list[dict[str, Any]] = []

    def run(self, name: str, cmd: list[str], cwd: Path | None = None,
            env: dict[str, str] | None = None, *, physical_readiness: bool = False) -> None:
        log = self.raw / f"{name}.log"
        print(f"RUN: {name}", flush=True)
        start = time.monotonic()
        early_failure = None
        with log.open("xb") as output:
            if physical_readiness:
                # Capture Xcode's original output while observing native device
                # readiness. Do not wait for its lengthy post-failure diagnostics.
                process = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    with log.open("rb") as observer:
                        recent = ""
                        while process.poll() is None:
                            chunk = observer.read()
                            if chunk:
                                recent = (recent + chunk.decode("utf-8", errors="replace"))[-8192:]
                                early_failure = physical_xcode_readiness_failure(recent)
                            if time.monotonic() - start > 1800:
                                early_failure = "Physical Xcode phase exceeded 30-minute bound"
                            if early_failure:
                                stop_owned_process_group(process)
                                break
                            time.sleep(0.25)
                        recent = (recent + observer.read().decode("utf-8", errors="replace"))[-8192:]
                        early_failure = early_failure or physical_xcode_readiness_failure(recent)
                    exit_code = process.wait()
                finally:
                    stop_owned_process_group(process)
            else:
                result = subprocess.run(cmd, cwd=cwd, env=env, stdout=output,
                                        stderr=subprocess.STDOUT, check=False)
                exit_code = result.returncode
            output.flush()
            os.fsync(output.fileno())
        phase = {"name": name, "exit_code": exit_code,
                 "elapsed_seconds": round(time.monotonic() - start, 2), "command": cmd}
        if early_failure:
            phase["failure_reason"] = early_failure
        self.phases.append(phase)
        if early_failure or exit_code:
            excerpt = failure_excerpt(log.read_text(encoding="utf-8", errors="replace"))
            print(f"ERROR: {name} returned {exit_code}; log={log}\n" + "\n".join(excerpt), flush=True)
            if self.suite == "physical-sync":
                for phase in ("roundtrip", "restore"):
                    print_sync_progress(self.raw / f"physical-sync-mac-{phase}.log")
            raise VerificationError(early_failure or f"Phase failed: {name} (exit {exit_code})")
        print(f"PASS: {name}", flush=True)

    def seal(self, outcome: str, reason: str | None = None) -> None:
        """One V1 authority; retain original logs and native result bundles."""
        require(outcome in ("PASS", "FAIL"), "Unsupported verification outcome")
        if outcome == "PASS":
            require(self.phases and all(p["exit_code"] == 0 for p in self.phases),
                    "Cannot claim PASS without completed successful phases")
        for folder in ("raw", "metadata", "manifests"):
            require((self.path / folder).is_dir() and not (self.path / folder).is_symlink(),
                    "Noncanonical run directory")
        if reason:
            with (self.raw / "producer-error.txt").open("xb") as output:
                output.write((reason + "\n").encode("utf-8"))
                output.flush()
                os.fsync(output.fileno())
        indexed = artifacts_in(self.raw)
        phases = {p["name"]: f"phase-{i}" for i, p in enumerate(self.phases, 1)}
        evidence, artifacts = [], []
        for entry in indexed:
            relative = entry["path"]
            name = Path(relative).name
            phase = phases.get(name.removesuffix(".log")) if name.endswith(".log") else None
            if ".xcresult/" not in relative:
                evidence.append(dict(
                    evidence_id=relative,
                    category="runner_output" if name.endswith(".log") or name == "producer-error.txt" else "generated_manifest_report",
                    category_detail=None, provenance="machine", availability="present",
                    path=relative, sha256=entry["sha256"], phase_id=phase,
                    attempt_number=1 if phase else None, captured_at=None,
                    legacy_source_ref=None,
                ))
            artifacts.append(dict(
                artifact_id=relative, path=relative, artifact_kind="file",
                retention_class="canonical", disposition="retained",
                sha256=entry["sha256"], logical_content_sha256=entry["sha256"],
                size_bytes=entry["size"], supports=[phase or "run_outcome"],
            ))
        for bundle in sorted(self.raw.glob("*.xcresult")):
            require(bundle.is_dir() and not bundle.is_symlink(), "Noncanonical Xcode result bundle")
            relative = bundle.relative_to(self.path).as_posix()
            phase = phases.get(bundle.name.removesuffix(".xcresult"))
            evidence.append(dict(
                evidence_id=relative, category="result_bundle", category_detail=None,
                provenance="machine", availability="present", path=relative,
                sha256=None, phase_id=phase, attempt_number=1 if phase else None,
                captured_at=None, legacy_source_ref=None,
            ))
        status = ("passed" if outcome == "PASS" else
                  "failed" if any(p["exit_code"] != 0 for p in self.phases) else "blocked")
        report = dict(
            manifest_schema_version=1, evidence_contract_version=1,
            project=self.path.parent.parent.name, work_unit=self.path.parent.name,
            run_id=self.path.name, origin=dict(kind="implementation_unit", key="AutomatedVerification"),
            associations=[], started_at=self.started_at,
            completed_at=dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            status=status, history_state="current", authority_state="current",
            superseded_by_run_id=None, source_revision=self.sha,
            retention_state="sealed", evidence=evidence, artifacts=artifacts,
            retention_summary=dict(
                canonical_bytes=sum(item["size_bytes"] for item in artifacts),
                canonical_artifacts=len(artifacts),
                supporting_bytes_purged=0, supporting_artifacts_purged=0,
            ),
        )
        # Recheck recorded originals before reporting any PASS; reject stale or
        # tampered retained test artifacts, including files inside .xcresult.
        for item in artifacts:
            file = self.path / item["path"]
            require(file.is_file() and not file.is_symlink()
                    and file.resolve().is_relative_to(self.path.resolve())
                    and file.stat().st_size == item["size_bytes"]
                    and sha_file(file) == item["sha256"],
                    "Retained original artifact integrity mismatch")
        location = self.path / "manifests" / "run.json"
        with location.open("xb") as output:  # no overwrite or parallel legacy manifest
            output.write((json.dumps(report, indent=2, sort_keys=True) + "\n").encode("utf-8"))
            output.flush()
            os.fsync(output.fileno())
        print(f"evidence_manifest_sha256={sha_file(location)}", flush=True)
        print(f"CANONICAL_MANIFEST={location}", flush=True)
        print(f"evidence_directory={self.path}", flush=True)

@contextlib.contextmanager
def lock_resources(directory: Path, resources: list[str]):
    directory.mkdir(parents=True, exist_ok=True)
    handles = []
    try:
        for resource in sorted(resources):
            require(re.fullmatch(r"[A-Za-z0-9_-]+", resource) is not None, "Invalid lock resource")
            handle = (directory / f"{resource}.lock").open("a+")
            handles.append(handle)
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise VerificationError(f"Another verification run owns {resource}; refusing shared test-data collision") from error
        yield
    finally:
        for handle in reversed(handles):
            with contextlib.suppress(OSError):
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            handle.close()


@contextlib.contextmanager
def verification_scratch(workspace: Path):
    scratch = Path(tempfile.mkdtemp(prefix=".myram-native-verify-", dir=workspace))
    try:
        yield scratch
    finally:
        if any((scratch / name).exists() for name in ("MyRAM-iOS", "NearbySyncCore")):
            print(f"Preserved verification scratch: {scratch}", file=sys.stderr, flush=True)
        else:
            shutil.rmtree(scratch)


def worktree_state(path: Path) -> tuple[str, str]:
    return (run_output("git", "-C", str(path), "status", "--porcelain=v1",
                       "--untracked-files=all", "--ignored"),
            run_output("git", "-C", str(path), "diff", "--binary", "HEAD"))


def remove_verified_worktree(repo: Path, path: Path, expected: tuple[str, str]) -> None:
    require(worktree_state(path) == expected, f"Unexpected worktree changes; preserving {path}")
    if expected != ("", ""):
        require(not run_output("git", "-C", str(path), "diff", "--cached", "--name-only")
                and all(line.startswith("M ") or line.startswith(" M ")
                        for line in expected[0].splitlines()),
                f"Unexpected staged/untracked/ignored content; preserving {path}")
        changed = run_output("git", "-C", str(path), "diff", "--name-only").splitlines()
        require(bool(changed), "Missing generated profile changes")
        run_output("git", "-C", str(path), "restore", "--source=HEAD", "--worktree", "--", *changed)
    require(worktree_state(path) == ("", ""), f"Worktree not clean; preserving {path}")
    run_output("git", "-C", str(repo), "worktree", "remove", str(path))
    require(not path.exists() and f"worktree {path}" not in run_output(
        "git", "-C", str(repo), "worktree", "list", "--porcelain").splitlines(),
        f"Worktree cleanup was not verified: {path}")


def xcode_phase(evidence: Evidence, root: Path, scratch: Path, suite: str,
                simulator: str | None, selectors: list[str], env: dict[str, str]) -> None:
    target = SUITE_TARGETS[suite]
    destination = "platform=macOS" if suite == "mac" else f"platform=iOS Simulator,id={simulator}"
    selected = selectors or [target]
    # Each explicit selector must produce its own positive native test result.
    # An aggregate count can otherwise hide a nonexistent second selector.
    for ordinal, selector in enumerate(selected, start=1):
        name = f"{suite}-tests" if len(selected) == 1 else f"{suite}-tests-{ordinal}"
        result_path = evidence.raw / (name + ".xcresult")
        command = ["xcodebuild", "-project", "MyRAM.xcodeproj",
                   "-scheme", "MyRAMMac" if suite == "mac" else "MyRAM",
                   "-configuration", "Debug", "-destination", destination,
                   "-parallel-testing-enabled", "NO", "-derivedDataPath", str(scratch / "DerivedData"),
                   "-resultBundlePath", str(result_path), "CODE_SIGNING_ALLOWED=NO",
                   "-only-testing:" + selector, "test"]
        evidence.run(name, command, cwd=root, env=env)
        summary = run_output("xcrun", "xcresulttool", "get", "test-results", "summary",
                             "--path", str(result_path))
        counts = validate_summary(summary)
        (evidence.raw / f"{name}-summary.json").write_text(summary + "\n", encoding="utf-8")
        evidence.phases[-1]["counts"] = counts
        print(f"PASS: {name} total={counts['total']} failed={counts['failed']}", flush=True)


def reset_automated_app(evidence: Evidence, simid: str, suite: str, env: dict[str, str]) -> None:
    # Only the repository-owned automated profile is disposable; all other identities are excluded.
    probe = subprocess.run(["xcrun", "simctl", "get_app_container", simid, IDENTITY, "app"],
                           text=True, capture_output=True, check=False)
    if probe.returncode == 0:
        evidence.run(f"{suite}-reset-dedicated-test-app", ["xcrun", "simctl", "uninstall", simid, IDENTITY], env=env)
        return
    message = probe.stderr + probe.stdout
    require(any(known in message.lower() for known in ("not installed", "no such file", "code=2", "not found")),
            "Unable to verify disposable test app presence; refusing to alter simulator: " + message.strip())


def xcode_release(evidence: Evidence, root: Path, scratch: Path, platform: str,
                  env: dict[str, str]) -> None:
    destination = "generic/platform=iOS Simulator" if platform == "ios" else "platform=macOS"
    evidence.run(f"{platform}-release", ["xcodebuild", "-project", "MyRAM.xcodeproj",
                 "-scheme", "MyRAM" if platform == "ios" else "MyRAMMac",
                 "-configuration", "Release", "-destination", destination,
                 "-derivedDataPath", str(scratch / "ReleaseDerivedData"),
                 "CODE_SIGNING_ALLOWED=NO", "build"], cwd=root, env=env)


def physical_phase(evidence: Evidence, root: Path, scratch: Path,
                   iphone: str, env: dict[str, str]) -> None:
    derived = scratch / "PhysicalDerivedData"
    evidence.run("physical-mac-build", [
        "xcodebuild", "-project", "MyRAM.xcodeproj", "-scheme", "MyRAMMac",
        "-configuration", "Debug", "-destination", "platform=macOS",
        "-derivedDataPath", str(derived), "build"
    ], cwd=root, env=env)
    app = derived / "Build" / "Products" / "Debug" / "MyRAMMac.app"
    info_path = app / "Contents" / "Info.plist"
    require(info_path.is_file(), "Signed MYR371 Mac app bundle was not produced")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleIdentifier") == PHYSICAL_MAC_ID
            and info.get("MyRAMVerificationTransportOnly") is True
            and info.get("NSBonjourServices") == ["_myr371-ice._tcp"],
            "Built Mac app does not have the immutable MYR371 transport-only identity")
    evidence.run("physical-mac-signature", [
        "codesign", "--verify", "--strict", "--deep", str(app)
    ], env=env)
    executable = app / "Contents" / "MacOS" / "MyRAMMac"
    require(executable.is_file(), "Built MYR371 Mac executable missing")
    mac_log = evidence.raw / "physical-mac-process.log"
    mobile_environment = dict(env, TEST_RUNNER_MYR371_PHYSICAL_TRANSPORT="1")
    with mac_log.open("xb") as output:
        process = subprocess.Popen([str(executable)], cwd=root, env=env,
                                   stdout=output, stderr=subprocess.STDOUT)
        (evidence.raw / "physical-mac-process-identity.json").write_text(
            json.dumps({"pid": process.pid, "bundle_id": PHYSICAL_MAC_ID,
                        "executable_sha256": sha_file(executable),
                        "info_plist_sha256": sha_file(info_path)}) + "\n", encoding="utf-8"
        )
        try:
            require(process.poll() is None, "Signed MYR371 Mac app exited at launch")
            evidence.run("physical-iphone-tests", [
                "xcodebuild", "-project", "MyRAM.xcodeproj", "-scheme", "MyRAM",
                "-configuration", "Debug", "-destination", f"platform=iOS,id={iphone}",
                "-parallel-testing-enabled", "NO", "-derivedDataPath", str(derived),
                "-resultBundlePath", str(evidence.raw / "physical-iphone-tests.xcresult"),
                "-only-testing:" + PHYSICAL_TEST, "test"
            ], cwd=root, env=mobile_environment, physical_readiness=True)
            require(process.poll() is None, "Signed MYR371 Mac app exited during physical acceptance")
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            output.flush()
            os.fsync(output.fileno())
    summary = run_output("xcrun", "xcresulttool", "get", "test-results", "summary",
                         "--path", str(evidence.raw / "physical-iphone-tests.xcresult"))
    counts = validate_summary(summary)
    require(counts["total"] == 1 and counts["passed"] == 1 and counts["skipped"] == 0,
            "Physical acceptance requires exactly one non-skipped native XCUITest")
    (evidence.raw / "physical-iphone-tests-summary.json").write_text(summary + "\n", encoding="utf-8")
    evidence.phases[-1]["counts"] = counts
    assert_myr371_mac_transport(mac_log.read_text(encoding="utf-8", errors="replace"), expected_pid=process.pid)
    print("PASS: MYR371 native iPhone connection and Mac reconnect lifecycle", flush=True)


def sync_events(log: str, token: str, candidate: str, pid: int) -> list[dict]:
    events = []
    for line in log.splitlines():
        if not line.startswith("MYRAM_PHYSICAL_SYNC "):
            continue
        item = json.loads(line.removeprefix("MYRAM_PHYSICAL_SYNC "))
        require(isinstance(item, dict) and item.get("token") == token
                and item.get("candidate") == candidate and item.get("pid") == str(pid),
                "Physical sync event identity mismatch")
        require(item.get("event") != "failed", "Mac physical sync failed: " + str(item.get("reason")))
        events.append(item)
    return events


def assert_mac_sync_drained(event: dict, *, offline: bool = False) -> None:
    lines = set(event.get("diagnostics", "").splitlines())
    required = {"unsent_count=0", "pending_incoming_count=0",
                "pending_local_obligation_count=0", "pending_incoming_transport_count=0",
                "processing_incoming=false"}
    if offline:
        required.add("mc_session_connected_count=0")
    require(required <= lines, "Mac durable sync queues or offline restoration not verified")


def valid_sync_source_edit(token: str, body: str) -> bool:
    combined = f"Sync {token} body Mac"
    insertion = " iPhone"
    return (isinstance(body, str) and len(body) == len(combined) + len(insertion)
            and body.replace(insertion, "") == combined)


def assert_sync_roundtrip(events: list[dict], token: str) -> str:
    expected = [
        ("seed-received", "A", ""),
        ("mac-title-saved", "B", ""),
        ("iphone-title-received", "C", ""),
        ("mac-combined-saved", "D", " Mac"),
        ("iphone-combined-received", "E", None),
        ("drained", "E", None),
    ]
    require([e.get("event") for e in events] == ["ready"] + [e[0] for e in expected],
            "Mac physical sync phases missing, duplicated, or out of order")
    final = events[-2].get("body")
    require(valid_sync_source_edit(token, final), "Mac did not receive exactly one native iPhone insertion")
    for item, (_, title, suffix) in zip(events[1:], expected):
        body = final if suffix is None else f"Sync {token} body{suffix}"
        require(item.get("title") == f"Sync {token} {title}" and item.get("body") == body,
                "Mac physical sync state differs from the unique fixture")
    assert_mac_sync_drained(events[-1])
    return final


def read_sync_source_edit(directory: Path, token: str) -> str:
    # xcresulttool's exported manifest maps native attachment names to files.
    # Select exactly the one run-bound source observation, never a screenshot,
    # a Mac projection, or a caller-supplied expectation.
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    matches = [
        a for test in manifest for a in test["attachments"]
        if a["suggestedHumanReadableName"].startswith("physical-sync-source-edit-" + token)
    ]
    require(len(matches) == 1, "Missing or ambiguous native iPhone source-edit attachment")
    filename = matches[0]["exportedFileName"]
    require(Path(filename).name == filename, "Invalid source attachment filename")
    path = directory / filename
    require(path.is_file() and not path.is_symlink(), "Invalid native source attachment")
    value = json.loads(path.read_text(encoding="utf-8"))
    require(value.get("token") == token and value.get("title") == f"Sync {token} E"
            and valid_sync_source_edit(token, value.get("body")),
            "Native iPhone source edit has invalid identity or content")
    return value["body"]


def require_sync_source_matches(mac_body: str, source_body: str) -> None:
    require(mac_body == source_body, "Mac convergence differs from the exact native iPhone edit")


def assert_sync_bundle(app: Path, bundle: str, candidate: str, *, mac: bool) -> None:
    info_path = app / ("Contents/Info.plist" if mac else "Info.plist")
    require(info_path.is_file(), "Signed physical sync app not built")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleIdentifier") == bundle
            and info.get("MyRAMVerificationCandidateSHA") == candidate
            and info.get("NSBonjourServices") == [SYNC_SERVICE]
            and info.get("MyRAMVerificationTransportOnly", False) is False,
            "Physical sync app identity is not the exact isolated application-sync candidate")


@contextlib.contextmanager
def sync_mac_process(evidence: Evidence, executable: Path, root: Path,
                     env: dict[str, str], token: str, phase: str):
    log = evidence.raw / f"physical-sync-mac-{phase}.log"
    launch_env = dict(env, MYRAM_PHYSICAL_SYNC_TOKEN=token,
                      MYRAM_PHYSICAL_SYNC_CANDIDATE=evidence.sha, MYRAM_PHYSICAL_SYNC_PHASE=phase)
    with log.open("xb") as output:
        process = subprocess.Popen([str(executable)], cwd=root, env=launch_env,
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            (evidence.raw / f"physical-sync-mac-{phase}-identity.json").write_text(
                json.dumps({"pid": process.pid, "sha": evidence.sha,
                            "executable_sha256": sha_file(executable), "bundle_id": SYNC_MAC_ID,
                            "token": token, "phase": phase}) + "\n", encoding="utf-8")
            yield process, log
        finally:
            stop_owned_process_group(process)
            output.flush()
            os.fsync(output.fileno())


def wait_sync_event(process: subprocess.Popen, log: Path, token: str,
                    candidate: str, event: str, seconds: int) -> list[dict]:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        require(process.poll() is None, "Isolated Mac sync app exited")
        # A concurrent writer can leave a partial final line. Never interpret it
        # as an event until the native producer writes the terminating newline.
        contents = log.read_text(encoding="utf-8", errors="replace")
        complete = contents[:contents.rfind("\n") + 1]
        events = sync_events(complete, token, candidate, process.pid)
        if any(e.get("event") == event for e in events):
            return events
        time.sleep(0.25)
    raise VerificationError("Timed out waiting for native Mac physical sync event: " + event)


def physical_sync_phase(evidence: Evidence, root: Path, scratch: Path,
                        iphone: str, env: dict[str, str]) -> None:
    # Never start a second process against the same persistent Test Host store.
    check_running = ('import AppKit; import Darwin; '
                     'let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "'
                     + SYNC_MAC_ID + '"); '
                     'for app in apps { print("BLOCKED: Quit the existing Test Host normally; PID: " '
                     '+ String(app.processIdentifier) + " bundle: " '
                     '+ (app.bundleURL?.path ?? "unknown")) }; exit(apps.isEmpty ? 0 : 1)')
    evidence.run("physical-sync-existing-host-preflight", ["xcrun", "swift", "-e", check_running], env=env)
    derived = scratch / "PhysicalSyncDerivedData"
    common = ["xcodebuild", "-project", "MyRAM.xcodeproj", "-configuration", "Debug",
              "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO"]
    mobile = common + ["-scheme", "MyRAM", "-destination", f"platform=iOS,id={iphone}"]
    evidence.run("physical-sync-mac-build", common + ["-scheme", "MyRAMMac",
                 "-destination", "platform=macOS", "build"], cwd=root, env=env)
    evidence.run("physical-sync-iphone-build", mobile + ["build-for-testing"], cwd=root, env=env,
                 physical_readiness=True)
    mac = derived / "Build/Products/Debug/MyRAMMac.app"
    ios = derived / "Build/Products/Debug-iphoneos/MyRAM.app"
    for app, bundle, is_mac in ((mac, SYNC_MAC_ID, True), (ios, SYNC_IOS_ID, False)):
        assert_sync_bundle(app, bundle, evidence.sha, mac=is_mac)
        evidence.run("physical-sync-" + ("mac" if is_mac else "iphone") + "-signature",
                     ["codesign", "--verify", "--strict", "--deep", str(app)], env=env)
    executable = mac / "Contents/MacOS/MyRAMMac"
    require(executable.is_file(), "Physical sync Mac executable missing")
    token = uuid.uuid4().hex
    result = evidence.raw / "physical-sync-iphone.xcresult"
    evidence.run("physical-sync-exclusive-launch-preflight", ["xcrun", "swift", "-e", check_running], env=env)
    with sync_mac_process(evidence, executable, root, env, token, "roundtrip") as (process, log):
        events = wait_sync_event(process, log, token, evidence.sha, "ready", 90)
        require(len(events) == 1, "Unexpected Mac sync activity before phone test")
        device = str(uuid.UUID(events[0]["device"])).upper()
        pair = f"{evidence.sha}|{evidence.sha}|{device}"
        test_env = dict(env, TEST_RUNNER_MYRAM_PHYSICAL_SYNC_TOKEN=token,
                        TEST_RUNNER_MYRAM_PHYSICAL_SYNC_PAIR=pair)
        evidence.run("physical-sync-iphone", mobile + ["-resultBundlePath", str(result),
                     "-only-testing:" + SYNC_TEST, "test-without-building"], cwd=root,
                     env=test_env, physical_readiness=True)
        mac_body = assert_sync_roundtrip(wait_sync_event(process, log, token, evidence.sha, "drained", 180), token)
    def require_native_pass(path: Path, name: str) -> None:
        summary = run_output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(path))
        counts = validate_summary(summary)
        require(counts["total"] == counts["passed"] == 1 and counts["skipped"] == 0,
                "Physical sync requires exactly one passing native XCUITest per phase")
        (evidence.raw / f"{name}-summary.json").write_text(summary + "\n", encoding="utf-8")

    require_native_pass(result, "physical-sync-iphone")
    # The exported copy is disposable: the original native attachment remains
    # retained in the canonical xcresult bundle.
    attachments = scratch / "physical-sync-source-attachments"
    attachments.mkdir()
    evidence.run("physical-sync-source-export", ["xcrun", "xcresulttool", "export", "attachments",
                 "--path", str(result), "--output-path", str(attachments)], env=env)
    source_body = read_sync_source_edit(attachments, token)
    require_sync_source_matches(mac_body, source_body)
    # No Mac Test Host may be running while the phone proves local restoration.
    evidence.run("physical-sync-offline-iphone-preflight", ["xcrun", "swift", "-e", check_running], env=env)
    restore_result = evidence.raw / "physical-sync-iphone-restore.xcresult"
    evidence.run("physical-sync-iphone-restore", mobile + ["-resultBundlePath", str(restore_result),
                 "-only-testing:" + SYNC_RESTORE_TEST, "test-without-building"], cwd=root,
                 env=dict(env, TEST_RUNNER_MYRAM_PHYSICAL_SYNC_RESTORE_TOKEN=token,
                          TEST_RUNNER_MYRAM_PHYSICAL_SYNC_EXPECTED_BODY=source_body),
                 physical_readiness=True)
    require_native_pass(restore_result, "physical-sync-iphone-restore")
    evidence.run("physical-sync-offline-mac-preflight", ["xcrun", "swift", "-e", check_running], env=env)
    restore_env = dict(env, MYRAM_PHYSICAL_SYNC_EXPECTED_BODY=source_body)
    with sync_mac_process(evidence, executable, root, restore_env, token, "restore") as (process, log):
        restored = wait_sync_event(process, log, token, evidence.sha, "restored", 90)
        require(len(restored) == 1 and restored[0].get("title") == f"Sync {token} E"
                and restored[0].get("body") == source_body,
                "Fresh Mac process did not restore exact final fixture")
        assert_mac_sync_drained(restored[0], offline=True)
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            marker = "MYR233_TRANSPORT "
            if marker in line:
                item = json.loads(line.split(marker, 1)[1])
                require(not (item.get("event") == "session.state" and item.get("detail") == "state=2"),
                        "Mac restoration saw a remote connection")
    print("PASS: bidirectional title/body sync, durable queues and both offline app restarts", flush=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run MyRAM native tests against clean HEAD in isolated Verification")
    parser.add_argument("suite", choices=("ui", "ios", "mac", "all", *PHYSICAL_SUITES), nargs="?", default="ui")
    parser.add_argument("--only", action="append", default=[], metavar="TARGET/CLASS[/TEST]",
                        help="Repeatable exact Xcode test selector for a single suite")
    parser.add_argument("--simulator", metavar="EXISTING-UDID", help="Use this existing iPhone Simulator UUID")
    parser.add_argument("--iphone-udid", metavar="PHYSICAL-ID", help="Pin an eligible physical iOS device")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if args.suite in PHYSICAL_SUITES:
        require(not args.only and not args.simulator, "Physical modes use dedicated native tests; --only/--simulator are forbidden")
    else:
        require(not args.iphone_udid, "--iphone-udid requires the physical suite")
        validate_only(args.suite, args.only)
    repo = Path(__file__).resolve().parent.parent
    evidence: Evidence | None = None
    status = "FAIL"
    reason = None
    try:
        require(sys.platform == "darwin", "This runner requires macOS and Xcode; no non-native simulation substituted")
        exact_repository(repo, REPOSITORY)
        sha = current_candidate(repo)
        nearby = repo.parent / "NearbySyncCore"
        require(nearby.is_dir(), f"Required sibling repository missing: {nearby}")
        exact_repository(nearby, DEPENDENCY)
        ci_text = (repo / ".github/workflows/pr-verification.yml").read_text(encoding="utf-8")
        near_sha = pinned_nearby_sha(ci_text)
        run_output("git", "-C", str(nearby), "cat-file", "-e", f"{near_sha}^{{commit}}")
        java_home = preflight_temurin17(Path.home())
        xcode_version = run_output("xcodebuild", "-version")
        run_output("xcrun", "--find", "xcresulttool")
        print(f"candidate_sha={sha}\nnearby_sha={near_sha}\njava_home={java_home}\n{xcode_version}", flush=True)
        profile = (SYNC_PROFILE if args.suite == "physical-sync" else
                   PHYSICAL_PROFILE if args.suite == "physical" else PROFILE)
        simid = None
        booted = True
        if args.suite in ("ui", "ios", "all"):
            simid, booted = choose_simulator(run_output("xcrun", "simctl", "list", "devices", "available", "--json"),
                                             args.simulator or os.environ.get(SIMULATOR_ENV))
            print(f"simulator_udid={simid} (existing)", flush=True)
        authority = repo.parent / "Evidence"
        require(authority.is_dir(), "Canonical workspace Evidence authority missing; refusing another root")
        evidence = Evidence(authority / "MyRAM" / "AutomatedVerification", sha, near_sha, args.suite)
        (evidence.raw / "execution.json").write_text(json.dumps({"sha": sha, "nearby": near_sha,
                       "profile": profile, "simulator": simid, "xcode": xcode_version}, indent=2) + "\n", encoding="utf-8")
        resources = (["sim-" + simid] if simid else []) + (["mac-profile"] if args.suite in ("mac", "all", *PHYSICAL_SUITES) else [])
        if args.suite in PHYSICAL_SUITES:
            resources.append("physical-iphone")
        with lock_resources(evidence.path.parent / ".locks", resources):
            with verification_scratch(repo.parent) as scratch:
                ios_worktree = scratch / "MyRAM-iOS"
                nearby_worktree = scratch / "NearbySyncCore"
                have_ios, have_nearby = False, False
                generated_state = ("", "")
                try:
                    evidence.run("worktree-myram", ["git", "-C", str(repo), "worktree", "add", "--detach",
                                                  str(ios_worktree), sha])
                    have_ios = True
                    evidence.run("worktree-nearby", ["git", "-C", str(nearby), "worktree", "add", "--detach",
                                                   str(nearby_worktree), near_sha])
                    have_nearby = True
                    require(run_output("git", "-C", str(ios_worktree), "rev-parse", "HEAD") == sha,
                            "Candidate worktree SHA changed")
                    require(run_output("git", "-C", str(nearby_worktree), "rev-parse", "HEAD") == near_sha,
                            "Sibling worktree SHA changed")
                    env = os.environ.copy()
                    env["JAVA_HOME"] = str(java_home)
                    env["PATH"] = f"{java_home / 'bin'}:{env.get('PATH', '')}"
                    profile_args = [sys.executable, "Scripts/configure-myram-verification.py",
                                    "--root", str(ios_worktree), "--profile", profile,
                                    "--manifest-output", str(evidence.raw / "isolation.json")]
                    if args.suite == "physical":
                        profile_args.append("--transport-only")
                    evidence.run("verification-profile", profile_args, cwd=ios_worktree, env=env)
                    isolated = json.loads((evidence.raw / "isolation.json").read_text(encoding="utf-8"))
                    require(set(run_output("git", "-C", str(ios_worktree), "diff", "--name-only").splitlines())
                            == set(isolated["generated_changed_files"]),
                            "Generated profile change scope differs from its audit")
                    generated_state = worktree_state(ios_worktree)
                    expected_id = (SYNC_IOS_ID if args.suite == "physical-sync" else
                                   PHYSICAL_IOS_ID if args.suite == "physical" else IDENTITY)
                    require(isolated.get("source_candidate_sha") == sha and isolated.get("profile") == profile
                            and isolated.get("application_identifiers", {}).get("verification_ios") == expected_id
                            and (args.suite != "physical" or isolated.get("transport_mode") == "transportOnly")
                            and (args.suite != "physical-sync" or (
                                isolated.get("transport_mode") == "application"
                                and isolated.get("application_identifiers", {}).get("verification_macos") == SYNC_MAC_ID)),
                            "Disposable Verification identity audit did not match exact candidate")
                    if simid is not None:
                        if not booted:
                            evidence.run("boot-existing-simulator", ["xcrun", "simctl", "boot", simid], env=env)
                        evidence.run("simulator-ready", ["xcrun", "simctl", "bootstatus", simid, "-b"], env=env)
                    if args.suite in PHYSICAL_SUITES:
                        evidence.run("physical-device-discovery", [
                            "xcodebuild", "-project", "MyRAM.xcodeproj",
                            "-scheme", "MyRAM", "-showdestinations"
                        ], cwd=ios_worktree, env=env)
                        iphone = choose_physical_iphone(
                            (evidence.raw / "physical-device-discovery.log").read_text(),
                            args.iphone_udid or os.environ.get(PHYSICAL_DEVICE_ENV)
                        )
                        (evidence.raw / "physical-device-identity.json").write_text(
                            json.dumps({"iphone": iphone,
                                        "mac_bundle_id": SYNC_MAC_ID if args.suite == "physical-sync" else PHYSICAL_MAC_ID,
                                        "iphone_bundle_id": expected_id}) + "\n", encoding="utf-8"
                        )
                        print("PHYSICAL_AUTHORIZATION=Keep the iPhone unlocked during Xcode UI-test initialization. Approve required system prompts yourself; no authentication is automated.", flush=True)
                        if args.suite == "physical-sync":
                            physical_sync_phase(evidence, ios_worktree, scratch, iphone, env)
                        else:
                            physical_phase(evidence, ios_worktree, scratch, iphone, env)
                    suites = ([] if args.suite in PHYSICAL_SUITES else
                              (["mac", "ios", "ui"] if args.suite == "all" else [args.suite]))
                    for suite in suites:
                        require(run_output("git", "-C", str(ios_worktree), "rev-parse", "HEAD") == sha,
                                "Candidate SHA drift during verification")
                        if suite != "mac":
                            reset_automated_app(evidence, simid, suite, env)
                        xcode_phase(evidence, ios_worktree, scratch, suite, simid,
                                    args.only if suite == args.suite else [], env)
                    if args.suite == "all":
                        xcode_release(evidence, ios_worktree, scratch, "mac", env)
                        xcode_release(evidence, ios_worktree, scratch, "ios", env)
                    require(current_candidate(repo) == sha, "Primary source state drifted during verification")
                finally:
                    cleanup_failures = []
                    for exists, owner, path, expected in (
                        (have_nearby, nearby, nearby_worktree, ("", "")),
                        (have_ios, repo, ios_worktree, generated_state),
                    ):
                        if exists:
                            try:
                                remove_verified_worktree(owner, path, expected)
                            except Exception as error:
                                cleanup_failures.append(str(error))
                    require(not cleanup_failures, "; ".join(cleanup_failures))
        status = "PASS"
        return 0
    except (VerificationError, OSError, ValueError, KeyError, KeyboardInterrupt) as error:
        reason = str(error)
        print(f"ERROR: {reason}", file=sys.stderr, flush=True)
        return 1
    finally:
        if evidence:
            try:
                evidence.seal(status, reason)
                if status == "PASS":
                    print(f"VERIFICATION=PASS candidate_sha={evidence.sha}", flush=True)
            except Exception as error:
                print(f"ERROR: evidence sealing failed: {error}", file=sys.stderr, flush=True)
                # No success claim may survive failed sealing.
                if status == "PASS":
                    raise


if __name__ == "__main__":
    raise SystemExit(main())
