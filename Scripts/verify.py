#!/usr/bin/env python3
"""Repeatable, exact-commit MyRAM native tests in the isolated Verification profile.

Examples:
  python3 Scripts/verify.py                     # iOS UI suite
  python3 Scripts/verify.py ui --only MyRAMUITests/MyRAMUITests/testNewNoteOpensWithoutAttachments
  python3 Scripts/verify.py ios --only MyRAMTests/EditorFormattingMutationApplierTests
  python3 Scripts/verify.py mac
  python3 Scripts/verify.py all
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


def assert_myr371_mac_transport(log: str) -> None:
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
        events.append(item)
    require(any(e.get("event") == "owner.created" for e in events),
            "Native Mac transport owner was not observed")
    require(any(e.get("event") == "networking.start" for e in events),
            "Native Mac transport discovery never started")
    require(not any(e.get("event") in ("application.send", "application.received") for e in events),
            "Application synchronization was attempted in transport-only acceptance")
    invitations = {e.get("peer") for e in events if e.get("event") == "invitation.incoming.accepted"}
    sessions = {}
    for event in events:
        if event.get("event") == "session.state":
            key = (event.get("local"), event.get("peer"))
            sessions.setdefault(key, []).append(event.get("detail"))
    for (local, peer), states in sessions.items():
        if not local or not peer or peer not in invitations:
            continue
        stage = 0
        for state in states:
            if state == ("state=0" if stage == 1 else "state=2"):
                stage += 1
                if stage == 3:
                    return
    raise VerificationError("No real Mac MCSession connected/disconnected/reconnected sequence found")


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

    def run(self, name: str, cmd: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
        log = self.raw / f"{name}.log"
        print(f"RUN: {name}", flush=True)
        start = time.monotonic()
        with log.open("xb") as output:
            result = subprocess.run(cmd, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=False)
            output.flush()
            os.fsync(output.fileno())
        self.phases.append({"name": name, "exit_code": result.returncode,
                            "elapsed_seconds": round(time.monotonic() - start, 2), "command": cmd})
        if result.returncode:
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-28:]
            print(f"ERROR: {name} returned {result.returncode}; log={log}\n" + "\n".join(tail), flush=True)
            raise VerificationError(f"Phase failed: {name} (exit {result.returncode})")
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
        try:
            require(process.poll() is None, "Signed MYR371 Mac app exited at launch")
            evidence.run("physical-iphone-tests", [
                "xcodebuild", "-project", "MyRAM.xcodeproj", "-scheme", "MyRAM",
                "-configuration", "Debug", "-destination", f"platform=iOS,id={iphone}",
                "-parallel-testing-enabled", "NO", "-derivedDataPath", str(derived),
                "-resultBundlePath", str(evidence.raw / "physical-iphone-tests.xcresult"),
                "-only-testing:" + PHYSICAL_TEST, "test"
            ], cwd=root, env=mobile_environment)
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
    assert_myr371_mac_transport(mac_log.read_text(encoding="utf-8", errors="replace"))
    print("PASS: MYR371 native iPhone connection and Mac reconnect lifecycle", flush=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run MyRAM native tests against clean HEAD in isolated Verification")
    parser.add_argument("suite", choices=("ui", "ios", "mac", "all", "physical"), nargs="?", default="ui")
    parser.add_argument("--only", action="append", default=[], metavar="TARGET/CLASS[/TEST]",
                        help="Repeatable exact Xcode test selector for a single suite")
    parser.add_argument("--simulator", metavar="EXISTING-UDID", help="Use this existing iPhone Simulator UUID")
    parser.add_argument("--iphone-udid", metavar="PHYSICAL-ID", help="Pin an eligible physical iOS device")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if args.suite == "physical":
        require(not args.only and not args.simulator, "Physical MYR371 uses its dedicated native test; --only/--simulator are forbidden")
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
        profile = PHYSICAL_PROFILE if args.suite == "physical" else PROFILE
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
        resources = (["sim-" + simid] if simid else []) + (["mac-profile"] if args.suite in ("mac", "all", "physical") else [])
        if args.suite == "physical":
            resources.append("physical-iphone")
        with lock_resources(evidence.path.parent / ".locks", resources):
            with tempfile.TemporaryDirectory(prefix=".myram-native-verify-", dir=repo.parent) as directory:
                scratch = Path(directory)
                ios_worktree = scratch / "MyRAM-iOS"
                nearby_worktree = scratch / "NearbySyncCore"
                have_ios, have_nearby = False, False
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
                    expected_id = PHYSICAL_IOS_ID if args.suite == "physical" else IDENTITY
                    require(isolated.get("source_candidate_sha") == sha and isolated.get("profile") == profile
                            and isolated.get("application_identifiers", {}).get("verification_ios") == expected_id
                            and (args.suite != "physical" or isolated.get("transport_mode") == "transportOnly"),
                            "Disposable Verification identity audit did not match exact candidate")
                    if simid is not None:
                        if not booted:
                            evidence.run("boot-existing-simulator", ["xcrun", "simctl", "boot", simid], env=env)
                        evidence.run("simulator-ready", ["xcrun", "simctl", "bootstatus", simid, "-b"], env=env)
                    if args.suite == "physical":
                        evidence.run("physical-device-discovery", [
                            "xcodebuild", "-project", "MyRAM.xcodeproj",
                            "-scheme", "MyRAM", "-showdestinations"
                        ], cwd=ios_worktree, env=env)
                        iphone = choose_physical_iphone(
                            (evidence.raw / "physical-device-discovery.log").read_text(),
                            args.iphone_udid or os.environ.get(PHYSICAL_DEVICE_ENV)
                        )
                        (evidence.raw / "physical-device-identity.json").write_text(
                            json.dumps({"iphone": iphone, "mac_bundle_id": PHYSICAL_MAC_ID,
                                        "iphone_bundle_id": PHYSICAL_IOS_ID}) + "\n", encoding="utf-8"
                        )
                        physical_phase(evidence, ios_worktree, scratch, iphone, env)
                    suites = ([] if args.suite == "physical" else
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
                    status = "PASS"
                finally:
                    # Worktree removal is scoped to paths created by this invocation, never active checkouts.
                    if have_nearby:
                        subprocess.run(["git", "-C", str(nearby), "worktree", "remove", "--force",
                                        str(nearby_worktree)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if have_ios:
                        subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force",
                                        str(ios_worktree)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0
    except (VerificationError, OSError, ValueError, json.JSONDecodeError) as error:
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
