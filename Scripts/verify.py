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
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any

REPOSITORY = "benjamindrong/MyRAM-iOS"
DEPENDENCY = "benjamindrong/NearbySyncCore"
PROFILE = "automated"
SIMULATOR_ENV = "MYRAM_SIMULATOR_ID"
IDENTITY = "com.northsignalstudio.myram.automated.verification"
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


def validate_summary(output: str) -> dict[str, int]:
    data = json.loads(output)
    total = data.get("totalTestCount")
    failed = data.get("failedTests")
    result = data.get("result")
    require(type(total) is int and total > 0, "Test result contains zero or unreported tests")
    require(type(failed) is int and failed == 0 and result == "Passed",
            f"Test summary indicates failures: {result}, failedTests={failed}")
    return {"total": total, "failed": failed, "passed": data.get("passedTests", 0),
            "skipped": data.get("skippedTests", 0)}


def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def artifacts_in(raw: Path) -> list[dict[str, Any]]:
    entries = []
    for file in sorted(p for p in raw.rglob("*") if p.is_file()):
        require(not file.is_symlink(), f"Symlink artifact rejected: {file}")
        entries.append({"path": file.relative_to(raw.parent).as_posix(),
                        "size": file.stat().st_size, "sha256": sha_file(file)})
    return entries


class Evidence:
    def __init__(self, root: Path, sha: str, nearby: str, suite: str):
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.path = root / f"{stamp}-{os.getpid()}-{sha[:12]}"
        self.raw = self.path / "raw"
        self.raw.mkdir(parents=True)
        self.sha = sha
        self.nearby = nearby
        self.suite = suite
        self.phases: list[dict[str, Any]] = []

    def run(self, name: str, cmd: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
        log = self.raw / f"{name}.log"
        print(f"RUN: {name}", flush=True)
        start = time.monotonic()
        with log.open("wb") as output:
            result = subprocess.run(cmd, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=False)
        self.phases.append({"name": name, "exit_code": result.returncode,
                            "elapsed_seconds": round(time.monotonic() - start, 2), "command": cmd})
        if result.returncode:
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-28:]
            print(f"ERROR: {name} returned {result.returncode}; log={log}\n" + "\n".join(tail), flush=True)
            raise VerificationError(f"Phase failed: {name} (exit {result.returncode})")
        print(f"PASS: {name}", flush=True)

    def seal(self, outcome: str, reason: str | None = None) -> None:
        report = {"schema": "myram.native-verification.v1", "repository": REPOSITORY,
                  "candidate_sha": self.sha, "nearby_sha": self.nearby, "suite": self.suite,
                  "retention_state": "sealed", "outcome": outcome, "reason": reason,
                  "phases": self.phases, "canonical_artifacts": artifacts_in(self.raw)}
        payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
        temp = self.path / "manifest.json.tmp"
        temp.write_text(payload, encoding="utf-8")
        os.replace(temp, self.path / "manifest.json")
        print(f"evidence_manifest_sha256={sha_file(self.path / 'manifest.json')}", flush=True)
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
    name = f"{suite}-tests"
    result_path = evidence.raw / (name + ".xcresult")
    destination = "platform=macOS" if suite == "mac" else f"platform=iOS Simulator,id={simulator}"
    command = ["xcodebuild", "-project", "MyRAM.xcodeproj",
               "-scheme", "MyRAMMac" if suite == "mac" else "MyRAM",
               "-configuration", "Debug", "-destination", destination,
               "-parallel-testing-enabled", "NO", "-derivedDataPath", str(scratch / "DerivedData"),
               "-resultBundlePath", str(result_path), "CODE_SIGNING_ALLOWED=NO"]
    command.extend("-only-testing:" + selector for selector in (selectors or [target]))
    command.append("test")
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


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run MyRAM native tests against clean HEAD in isolated Verification")
    parser.add_argument("suite", choices=("ui", "ios", "mac", "all"), nargs="?", default="ui")
    parser.add_argument("--only", action="append", default=[], metavar="TARGET/CLASS[/TEST]",
                        help="Repeatable exact Xcode test selector for a single suite")
    parser.add_argument("--simulator", metavar="EXISTING-UDID", help="Use this existing iPhone Simulator UUID")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
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
        simid = None
        booted = True
        if args.suite in ("ui", "ios", "all"):
            simid, booted = choose_simulator(run_output("xcrun", "simctl", "list", "devices", "available", "--json"),
                                             args.simulator or os.environ.get(SIMULATOR_ENV))
            print(f"simulator_udid={simid} (existing)", flush=True)
        evidence = Evidence(repo.parent / "Evidence" / "MyRAM" / "AutomatedVerification", sha, near_sha, args.suite)
        (evidence.raw / "execution.json").write_text(json.dumps({"sha": sha, "nearby": near_sha,
                       "profile": PROFILE, "simulator": simid, "xcode": xcode_version}, indent=2) + "\n", encoding="utf-8")
        resources = (["sim-" + simid] if simid else []) + (["mac-profile"] if args.suite in ("mac", "all") else [])
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
                    evidence.run("verification-profile", [sys.executable,
                                 "Scripts/configure-myram-verification.py", "--root", str(ios_worktree),
                                 "--profile", PROFILE,
                                 "--manifest-output", str(evidence.raw / "isolation.json")], cwd=ios_worktree, env=env)
                    isolated = json.loads((evidence.raw / "isolation.json").read_text(encoding="utf-8"))
                    require(isolated.get("source_candidate_sha") == sha and isolated.get("profile") == PROFILE
                            and isolated.get("application_identifiers", {}).get("verification_ios") == IDENTITY,
                            "Disposable Verification identity audit did not match exact candidate")
                    if simid is not None:
                        if not booted:
                            evidence.run("boot-existing-simulator", ["xcrun", "simctl", "boot", simid], env=env)
                        evidence.run("simulator-ready", ["xcrun", "simctl", "bootstatus", simid, "-b"], env=env)
                    for suite in (["mac", "ios", "ui"] if args.suite == "all" else [args.suite]):
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
        print(f"VERIFICATION={status} candidate_sha={sha}", flush=True)
        return 0
    except (VerificationError, OSError, ValueError, json.JSONDecodeError) as error:
        reason = str(error)
        print(f"ERROR: {reason}", file=sys.stderr, flush=True)
        return 1
    finally:
        if evidence:
            try:
                evidence.seal(status, reason)
            except Exception as error:
                print(f"ERROR: evidence sealing failed: {error}", file=sys.stderr, flush=True)
                # No success claim may survive failed sealing.
                if status == "PASS":
                    raise


if __name__ == "__main__":
    raise SystemExit(main())
