#!/usr/bin/env python3
"""Durable provenance and canonical run-index support for BEN-36."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
DISPOSITIONS = {
    "running", "successful", "failed", "aborted", "incomplete",
    "telemetry-missing", "malformed", "build-mismatched",
    "provenance-incomplete",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def load_index(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schemaVersion": SCHEMA_VERSION, "runs": []}
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schemaVersion") != SCHEMA_VERSION or not isinstance(value.get("runs"), list):
        raise ValueError(f"invalid BEN-36 run index: {path}")
    return value


@contextmanager
def index_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(path.suffix + ".lock").open("a", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield


def initiate(index_path: Path, run_id: str, evidence_path: str, duration: int, head: str) -> None:
    with index_lock(index_path):
        index = load_index(index_path)
        if any(entry.get("runID") == run_id for entry in index["runs"]):
            raise ValueError(f"run already indexed: {run_id}")
        index["runs"].append({
            "runID": run_id,
            "evidencePath": evidence_path,
            "durationSeconds": duration,
            "sourceRevision": head,
            "disposition": "running",
            "scenarioStartedAt": utc_now(),
            "lastUpdatedAt": utc_now(),
        })
        atomic_write_json(index_path, index)


def update(index_path: Path, run_id: str, disposition: str, detail: str | None) -> None:
    if disposition not in DISPOSITIONS:
        raise ValueError(f"unsupported disposition: {disposition}")
    with index_lock(index_path):
        index = load_index(index_path)
        matches = [entry for entry in index["runs"] if entry.get("runID") == run_id]
        if len(matches) != 1:
            raise ValueError(f"expected exactly one indexed run {run_id}; found {len(matches)}")
        entry = matches[0]
        entry["disposition"] = disposition
        entry["lastUpdatedAt"] = utc_now()
        if disposition != "running":
            entry["finishedAt"] = utc_now()
        if detail:
            entry["detail"] = detail
        atomic_write_json(index_path, index)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    init_parser = subparsers.add_parser("initiate")
    init_parser.add_argument("--index", type=Path, required=True)
    init_parser.add_argument("--run-id", required=True)
    init_parser.add_argument("--evidence-path", required=True)
    init_parser.add_argument("--duration", type=int, required=True)
    init_parser.add_argument("--head", required=True)
    update_parser = subparsers.add_parser("update")
    update_parser.add_argument("--index", type=Path, required=True)
    update_parser.add_argument("--run-id", required=True)
    update_parser.add_argument("--disposition", choices=sorted(DISPOSITIONS), required=True)
    update_parser.add_argument("--detail")
    args = parser.parse_args()
    if args.command == "initiate":
        initiate(args.index, args.run_id, args.evidence_path, args.duration, args.head)
    else:
        update(args.index, args.run_id, args.disposition, args.detail)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
