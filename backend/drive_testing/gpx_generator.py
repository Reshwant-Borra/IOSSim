from __future__ import annotations

import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from typing import Any


def build_gpx(samples: list[dict[str, Any]], include_timestamps: bool, start_time: datetime | None = None) -> str:
    if not samples:
        raise ValueError("At least one sample is required")
    start = start_time or datetime.now(timezone.utc)
    if start.tzinfo is None:
        start = start.replace(tzinfo=timezone.utc)

    root = ET.Element("gpx", version="1.1", creator="ios-location-sim-drive-testing")
    trk = ET.SubElement(root, "trk")
    ET.SubElement(trk, "name").text = "IOSSim Drive Testing Lab"
    segment = ET.SubElement(trk, "trkseg")
    last_elapsed = -1.0
    for sample in samples:
        elapsed = float(sample["planned_elapsed_s"])
        if elapsed < last_elapsed:
            raise ValueError("Sample timestamps must be monotonic")
        last_elapsed = elapsed
        point = ET.SubElement(
            segment,
            "trkpt",
            lat=str(sample["latitude"]),
            lon=str(sample["longitude"]),
        )
        if include_timestamps:
            timestamp = start + timedelta(seconds=elapsed)
            ET.SubElement(point, "time").text = timestamp.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="unicode")


def coordinate_only_gpx(samples: list[dict[str, Any]]) -> str:
    return build_gpx(samples, include_timestamps=False)


def timestamped_gpx(samples: list[dict[str, Any]], start_time: datetime | None = None) -> str:
    return build_gpx(samples, include_timestamps=True, start_time=start_time)
