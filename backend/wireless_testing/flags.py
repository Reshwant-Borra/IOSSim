from __future__ import annotations

import os


TRUTHY = {"1", "true", "yes", "on"}


def _enabled(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in TRUTHY


def experimental_enabled() -> bool:
    return _enabled("IOS_SIM_ENABLE_EXPERIMENTAL")


def wireless_testing_flag_enabled() -> bool:
    return _enabled("IOS_SIM_ENABLE_WIRELESS_TESTING")


def wireless_testing_enabled() -> bool:
    return experimental_enabled() and wireless_testing_flag_enabled()


def flag_status() -> dict[str, bool]:
    return {
        "backend_experimental_enabled": experimental_enabled(),
        "backend_wireless_testing_enabled": wireless_testing_flag_enabled(),
        "wireless_testing_enabled": wireless_testing_enabled(),
    }

