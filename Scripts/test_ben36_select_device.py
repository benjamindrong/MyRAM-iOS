#!/usr/bin/env python3

import unittest

from ben36_select_device import select_device


def device(
    identifier: str,
    device_type: str,
    product_type: str,
    *,
    reality: str = "physical",
) -> dict:
    return {
        "identifier": identifier,
        "connectionProperties": {"pairingState": "paired"},
        "deviceProperties": {"name": identifier},
        "hardwareProperties": {
            "deviceType": device_type,
            "platform": "iOS",
            "productType": product_type,
            "reality": reality,
            "udid": f"{identifier}-udid",
        },
        "visibilityClass": "default",
    }


class SelectDeviceTests(unittest.TestCase):
    def test_automatic_selection_ignores_ipad(self) -> None:
        iphone = device("phone", "iPhone", "iPhone17,1")
        ipad = device("tablet", "iPad", "iPad7,5")

        self.assertEqual(select_device([ipad, iphone]), ("phone", "phone-udid", "phone"))

    def test_override_accepts_iphone_identifier_or_udid(self) -> None:
        iphone = device("phone", "iPhone", "iPhone17,1")

        self.assertEqual(select_device([iphone], "phone"), ("phone", "phone-udid", "phone"))
        self.assertEqual(select_device([iphone], "phone-udid"), ("phone", "phone-udid", "phone"))

    def test_override_rejects_ipad_and_nonphysical_iphone(self) -> None:
        ipad = device("tablet", "iPad", "iPad7,5")
        simulated_iphone = device(
            "simulated", "iPhone", "iPhone17,1", reality="simulated"
        )

        with self.assertRaises(ValueError):
            select_device([ipad, simulated_iphone], "tablet")
        with self.assertRaises(ValueError):
            select_device([ipad, simulated_iphone], "simulated")


if __name__ == "__main__":
    unittest.main()
