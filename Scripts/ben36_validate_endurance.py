#!/usr/bin/env python3
"""Deterministically validate a paired BEN-36 MyRAM endurance run."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any


RESULT_SCHEMA = 1
TELEMETRY_SCHEMA = 3
CONTROL_SCHEMA = 1
EXPECTED_PLATFORMS = ("iOS", "macOS")


class ValidationError(Exception):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ValidationError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationError(f"{path}: expected a JSON object")
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except Exception as exc:
        raise ValidationError(f"{path}: unreadable: {exc}") from exc
    if not lines:
        raise ValidationError(f"{path}: empty JSONL artifact")
    for index, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except Exception as exc:
            raise ValidationError(f"{path}:{index}: invalid JSON: {exc}") from exc
        if not isinstance(event, dict):
            raise ValidationError(f"{path}:{index}: expected an object")
        events.append(event)
    if not events:
        raise ValidationError(f"{path}: no JSONL events")
    return events


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def validate_result(
    result: dict[str, Any], platform: str, run_id: str, failures: list[str]
) -> dict[str, str]:
    require(result.get("schemaVersion") == RESULT_SCHEMA, f"{platform}: result schemaVersion != {RESULT_SCHEMA}", failures)
    require(result.get("runID") == run_id, f"{platform}: result runID mismatch", failures)
    require(result.get("platform") == platform, f"{platform}: result platform mismatch", failures)
    require(result.get("outcome") == "locallyComplete", f"{platform}: result is not locallyComplete", failures)
    require(result.get("failedOperations") == 0, f"{platform}: failedOperations is nonzero", failures)
    require(result.get("finalUnsentBatchCount") == 0, f"{platform}: final unsent queue is not empty", failures)
    require(result.get("connectedAtFinish") is True, f"{platform}: not connected at finish", failures)

    attempted = result.get("attemptedOperations")
    committed = result.get("committedOperations")
    require(isinstance(attempted, int) and attempted >= 100, f"{platform}: fewer than 100 attempted operations", failures)
    require(isinstance(committed, int) and committed >= 100, f"{platform}: fewer than 100 committed operations", failures)

    expected_count = result.get("expectedBenchmarkNoteCount")
    notes = result.get("observedBenchmarkNotes")
    require(isinstance(expected_count, int) and expected_count > 0, f"{platform}: invalid expected note count", failures)
    require(isinstance(notes, list), f"{platform}: observedBenchmarkNotes is not a list", failures)

    digests: dict[str, str] = {}
    if isinstance(notes, list):
        for index, note in enumerate(notes):
            if not isinstance(note, dict):
                failures.append(f"{platform}: observed note {index} is not an object")
                continue
            title = note.get("title")
            digest = note.get("bodySHA256")
            if not isinstance(title, str) or not title:
                failures.append(f"{platform}: observed note {index} has invalid title")
                continue
            if not isinstance(digest, str) or len(digest) != 64:
                failures.append(f"{platform}: observed note {title!r} has invalid SHA-256")
                continue
            if title in digests:
                failures.append(f"{platform}: duplicate observed note title {title!r}")
                continue
            digests[title] = digest
        if isinstance(expected_count, int):
            require(len(digests) == expected_count, f"{platform}: observed note count does not equal expected count", failures)
    return digests


def validate_control(
    events: list[dict[str, Any]], platform: str, run_id: str, failures: list[str]
) -> Counter[str]:
    kinds: Counter[str] = Counter()
    for index, event in enumerate(events, start=1):
        require(event.get("schemaVersion") == CONTROL_SCHEMA, f"{platform}: control event {index} schema mismatch", failures)
        require(event.get("runID") == run_id, f"{platform}: control event {index} runID mismatch", failures)
        require(event.get("platform") == platform, f"{platform}: control event {index} platform mismatch", failures)
        kind = event.get("kind")
        if isinstance(kind, str):
            kinds[kind] += 1

    require(kinds["launch"] >= 1, f"{platform}: missing launch control event", failures)
    require(kinds["checkpoint"] >= 1, f"{platform}: missing workload checkpoints", failures)
    require(kinds["verification"] >= 1, f"{platform}: missing final verification control event", failures)
    require(kinds["completed"] >= 1, f"{platform}: missing completed control event", failures)
    require(kinds["failed"] == 0, f"{platform}: control stream contains failed event", failures)
    require(kinds["localMutationFailure"] == 0, f"{platform}: control stream contains local mutation failures", failures)

    phases = {event.get("phase") for event in events if event.get("kind") == "phase"}
    for required_phase in ("seed", "workload", "finalDrain"):
        require(required_phase in phases, f"{platform}: missing {required_phase} phase", failures)

    if platform == "macOS":
        network_outcomes = [event.get("outcome") for event in events if event.get("kind") == "network"]
        require(network_outcomes.count("suspended") == 4, "macOS: expected exactly four intentional network suspensions", failures)
        require(network_outcomes.count("resumed") >= 4, "macOS: expected at least four network resumptions", failures)
        state = "resumed"
        completed_pairs = 0
        for outcome in network_outcomes:
            if outcome == "suspended":
                if state != "resumed":
                    failures.append("macOS: overlapping network suspension events")
                state = "suspended"
            elif outcome == "resumed":
                if state == "suspended":
                    completed_pairs += 1
                state = "resumed"
        require(completed_pairs == 4, "macOS: network suspension/resumption pairs are incomplete", failures)
        require(state == "resumed", "macOS: network remained suspended at end of control stream", failures)
    return kinds


def validate_telemetry(
    events: list[dict[str, Any]], platform: str, run_id: str, failures: list[str]
) -> Counter[str]:
    event_types: Counter[str] = Counter()
    connection_outcomes: Counter[str] = Counter()
    for index, event in enumerate(events, start=1):
        require(event.get("schemaVersion") == TELEMETRY_SCHEMA, f"{platform}: telemetry event {index} schema mismatch", failures)
        require(event.get("runID") == run_id, f"{platform}: telemetry event {index} runID mismatch", failures)
        require(event.get("platform") == platform, f"{platform}: telemetry event {index} platform mismatch", failures)
        event_type = event.get("eventType")
        if isinstance(event_type, str):
            event_types[event_type] += 1
            if event_type == "peerConnectionState" and isinstance(event.get("outcome"), str):
                connection_outcomes[event["outcome"]] += 1

    require(event_types["sessionStarted"] >= 1, f"{platform}: missing telemetry sessionStarted", failures)
    require(event_types["batchQueued"] >= 20, f"{platform}: fewer than 20 queued batches; endurance traffic was too thin", failures)
    require(event_types["batchSendStarted"] >= 20, f"{platform}: fewer than 20 batch send attempts", failures)
    require(event_types["batchReceived"] >= 20, f"{platform}: fewer than 20 received batches", failures)
    require(event_types["batchAcknowledgementReceived"] >= 20, f"{platform}: fewer than 20 received acknowledgements", failures)
    require(connection_outcomes["notConnected"] >= 4, f"{platform}: fewer than four observed disconnects", failures)
    require(connection_outcomes["connected"] >= 5, f"{platform}: fewer than five observed connections/reconnections", failures)
    return event_types


def validate(args: argparse.Namespace) -> dict[str, Any]:
    failures: list[str] = []
    results = {
        "iOS": load_json(args.ios_result),
        "macOS": load_json(args.mac_result),
    }
    controls = {
        "iOS": load_jsonl(args.ios_control),
        "macOS": load_jsonl(args.mac_control),
    }
    telemetry = {
        "iOS": load_jsonl(args.ios_telemetry),
        "macOS": load_jsonl(args.mac_telemetry),
    }

    digests = {
        platform: validate_result(results[platform], platform, args.run_id, failures)
        for platform in EXPECTED_PLATFORMS
    }
    control_counts = {
        platform: validate_control(controls[platform], platform, args.run_id, failures)
        for platform in EXPECTED_PLATFORMS
    }
    telemetry_counts = {
        platform: validate_telemetry(telemetry[platform], platform, args.run_id, failures)
        for platform in EXPECTED_PLATFORMS
    }

    require(set(digests["iOS"]) == set(digests["macOS"]), "cross-device benchmark note title sets differ", failures)
    for title in sorted(set(digests["iOS"]) & set(digests["macOS"])):
        require(digests["iOS"][title] == digests["macOS"][title], f"cross-device content digest mismatch for {title!r}", failures)

    summary = {
        "schemaVersion": 1,
        "runID": args.run_id,
        "verdict": "pass" if not failures else "fail",
        "failures": failures,
        "platforms": {
            platform: {
                "attemptedOperations": results[platform].get("attemptedOperations"),
                "committedOperations": results[platform].get("committedOperations"),
                "observedBenchmarkNoteCount": len(digests[platform]),
                "controlEventCounts": dict(sorted(control_counts[platform].items())),
                "telemetryEventCounts": dict(sorted(telemetry_counts[platform].items())),
            }
            for platform in EXPECTED_PLATFORMS
        },
    }
    return summary


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--ios-result", type=Path, required=True)
    parser.add_argument("--mac-result", type=Path, required=True)
    parser.add_argument("--ios-control", type=Path, required=True)
    parser.add_argument("--mac-control", type=Path, required=True)
    parser.add_argument("--ios-telemetry", type=Path, required=True)
    parser.add_argument("--mac-telemetry", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        summary = validate(args)
    except ValidationError as exc:
        summary = {
            "schemaVersion": 1,
            "runID": args.run_id,
            "verdict": "fail",
            "failures": [str(exc)],
            "platforms": {},
        }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["verdict"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
