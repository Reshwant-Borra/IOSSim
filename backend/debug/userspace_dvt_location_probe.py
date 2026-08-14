#!/usr/bin/env python3
"""Experimental probe for pymobiledevice3 userspace DVT location simulation.

This is intentionally outside IOSSim's production path. It uses pymobiledevice3's
public Python APIs to establish the same in-process userspace RSD connection as
`--userspace`, then opens DVT device-info and location-simulation channels.
"""

from __future__ import annotations

import argparse
import asyncio
import time
from typing import Any

from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation


def _abbr(value: Any) -> str:
    if value is None:
        return "<none>"
    text = str(value)
    if len(text) <= 12:
        return text
    return f"{text[:6]}...{text[-6:]}"


def _service_names(rsd: Any) -> set[str]:
    peer_info = getattr(rsd, "peer_info", None)
    if isinstance(peer_info, dict):
        value = peer_info.get("Services")
        if isinstance(value, dict):
            return set(value)
    services = getattr(rsd, "services", None)
    if isinstance(services, dict):
        return set(services)
    all_values = getattr(rsd, "all_values", None)
    if isinstance(all_values, dict):
        value = all_values.get("Services")
        if isinstance(value, dict):
            return set(value)
    return set()


async def _probe(args: argparse.Namespace) -> None:
    started = time.monotonic()
    print(f"requested_udid={_abbr(args.udid)}")

    async with UserspaceRsdTunnel(serial=args.udid) as rsd:
        print(f"rsd_udid={_abbr(getattr(rsd, 'udid', None))}")
        print(f"product_type={getattr(rsd, 'product_type', '<unknown>')}")
        print(f"product_version={getattr(rsd, 'product_version', '<unknown>')}")
        print(f"in_process_tunnel={getattr(rsd, 'is_in_process_tunnel', '<unknown>')}")

        names = _service_names(rsd)
        print(f"service_count={len(names)}")
        print(f"has_dtservicehub={'com.apple.instruments.dtservicehub' in names}")
        print(f"has_coredevice_location={'com.apple.coredevice.locationservice' in names}")

        async with DvtProvider(rsd) as dvt:
            print(f"dvt_service_name={getattr(dvt, '_service_name', '<unknown>')}")

            async with DeviceInfo(dvt) as device_info:
                root_entries = await device_info.ls("/")
                print(f"device_info_ls_root_count={len(root_entries)}")
                print(f"device_info_ls_root_sample={root_entries[:5]}")

            async with LocationSimulation(dvt) as location:
                print(f"location_service_identifier={location.service.IDENTIFIER}")
                if args.skip_set:
                    print("location_set_skipped=true")
                    return

                call_started = time.monotonic()
                try:
                    result = await location.set(args.latitude, args.longitude)
                except Exception as exc:
                    elapsed = time.monotonic() - call_started
                    print(f"location_set_raised={type(exc).__name__}: {exc!r}")
                    print(f"location_set_elapsed_seconds={elapsed:.3f}")
                    raise
                elapsed = time.monotonic() - call_started
                print(f"location_set_returned={result!r}")
                print(f"location_set_elapsed_seconds={elapsed:.3f}")

                if args.hold_seconds > 0:
                    print(f"holding_seconds={args.hold_seconds}")
                    await asyncio.sleep(args.hold_seconds)

                if args.clear_after:
                    print("clearing_location=true")
                    await location.clear()

    total = time.monotonic() - started
    print(f"probe_total_seconds={total:.3f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True, help="Target device UDID. Printed only in abbreviated form.")
    parser.add_argument("--latitude", type=float, default=37.7749)
    parser.add_argument("--longitude", type=float, default=-122.4194)
    parser.add_argument("--hold-seconds", type=float, default=15.0)
    parser.add_argument("--skip-set", action="store_true", help="Open DVT channels but do not send the location selector.")
    parser.add_argument("--clear-after", action="store_true")
    args = parser.parse_args()

    asyncio.run(_probe(args))


if __name__ == "__main__":
    main()
