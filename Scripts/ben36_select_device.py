#!/usr/bin/env python3
"""Resolve one paired, visible, physical iPhone from devicectl JSON."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def nested_value(device: dict[str, Any], *paths: str) -> Any | None:
    for path in paths:
        current: Any = device
        for part in path.split("."):
            if not isinstance(current, dict) or part not in current:
                break
            current = current[part]
        else:
            if current not in (None, ""):
                return current
    return None


def physical_iphone_record(device: dict[str, Any]) -> tuple[str, str, str] | None:
    identifier = str(device.get("identifier", ""))
    udid = str(
        nested_value(device, "properties.udid", "hardwareProperties.udid")
        or identifier
    )
    name = str(
        nested_value(device, "properties.name", "deviceProperties.name") or "unknown"
    )
    platform = str(
        nested_value(device, "properties.platform", "hardwareProperties.platform") or ""
    )
    device_type = str(
        nested_value(device, "properties.deviceType", "hardwareProperties.deviceType")
        or ""
    )
    product_type = str(
        nested_value(device, "properties.productType", "hardwareProperties.productType")
        or ""
    )
    reality = str(
        nested_value(device, "properties.reality", "hardwareProperties.reality") or ""
    )
    pairing = str(
        nested_value(device, "properties.pairingState", "connectionProperties.pairingState")
        or ""
    )
    visibility = str(
        nested_value(device, "properties.state.visibilityClass", "visibilityClass") or ""
    )

    is_iphone = device_type.lower() == "iphone" or product_type.lower().startswith(
        "iphone"
    )
    if not (
        identifier
        and platform.lower() == "ios"
        and is_iphone
        and reality.lower() == "physical"
        and visibility in ("", "default")
        and pairing in ("", "paired")
    ):
        return None
    return identifier, udid, name


def select_device(
    devices: list[Any], requested_id: str = ""
) -> tuple[str, str, str]:
    candidates = [
        record
        for device in devices
        if isinstance(device, dict)
        if (record := physical_iphone_record(device)) is not None
    ]

    if requested_id:
        matches = [
            record
            for record in candidates
            if requested_id in (record[0], record[1])
        ]
        if len(matches) != 1:
            raise ValueError(
                "MYRAM_DEVICE_ID must identify exactly one paired, visible, physical iPhone"
            )
        return matches[0]

    if len(candidates) != 1:
        raise ValueError(
            "could not resolve exactly one paired, visible, physical iPhone; "
            "set MYRAM_DEVICE_ID when multiple iPhones are present"
        )
    return candidates[0]


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(
            "usage: ben36_select_device.py DEVICES_JSON [MYRAM_DEVICE_ID]",
            file=sys.stderr,
        )
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    devices = payload.get("result", {}).get("devices", [])
    requested_id = sys.argv[2] if len(sys.argv) == 3 else ""
    try:
        selected = select_device(devices, requested_id)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 3
    print("\t".join(selected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
