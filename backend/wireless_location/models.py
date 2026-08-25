from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any


class WirelessSessionState(str, Enum):
    DISCONNECTED = "DISCONNECTED"
    DISCOVERING = "DISCOVERING"
    CONNECTING = "CONNECTING"
    CONNECTED = "CONNECTED"
    SIMULATING = "SIMULATING"
    CLEARING = "CLEARING"
    RECONNECTING = "RECONNECTING"
    FAILED = "FAILED"


class SetupState(str, Enum):
    NOT_STARTED = "NOT_STARTED"
    USB_REQUIRED = "USB_REQUIRED"
    PREPARING = "PREPARING"
    READY_TO_UNPLUG = "READY_TO_UNPLUG"
    VERIFYING_WIRELESS = "VERIFYING_WIRELESS"
    WIRELESS_READY = "WIRELESS_READY"
    FAILED = "FAILED"


@dataclass
class SavedWirelessDevice:
    udid: str
    name: str = "iPhone"
    product_type: str | None = None
    ios_version: str | None = None
    wireless_setup_valid: bool = False
    setup_state: str = SetupState.NOT_STARTED.value
    last_seen_at: str | None = None
    last_usb_seen_at: str | None = None
    last_wireless_seen_at: str | None = None
    last_wireless_success_at: str | None = None
    last_transport_state: str = "UNKNOWN"
    created_at: str | None = None
    updated_at: str | None = None

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "SavedWirelessDevice":
        return cls(
            udid=str(payload.get("udid") or ""),
            name=str(payload.get("name") or "iPhone"),
            product_type=payload.get("product_type"),
            ios_version=payload.get("ios_version"),
            wireless_setup_valid=bool(payload.get("wireless_setup_valid")),
            setup_state=str(payload.get("setup_state") or SetupState.NOT_STARTED.value),
            last_seen_at=payload.get("last_seen_at"),
            last_usb_seen_at=payload.get("last_usb_seen_at"),
            last_wireless_seen_at=payload.get("last_wireless_seen_at"),
            last_wireless_success_at=payload.get("last_wireless_success_at"),
            last_transport_state=str(payload.get("last_transport_state") or "UNKNOWN"),
            created_at=payload.get("created_at"),
            updated_at=payload.get("updated_at"),
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class DeviceVisibility:
    usb_present: bool
    network_present: bool
    usb_count: int
    network_count: int
    usb_match_count: int
    network_match_count: int
    selected_usb: dict[str, Any] | None
    selected_network: dict[str, Any] | None
    errors: list[str]

    def to_public_dict(self) -> dict[str, Any]:
        return {
            "usb_present": self.usb_present,
            "network_present": self.network_present,
            "usb_count": self.usb_count,
            "network_count": self.network_count,
            "usb_match_count": self.usb_match_count,
            "network_match_count": self.network_match_count,
            "errors": list(self.errors),
        }
