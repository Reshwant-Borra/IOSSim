from __future__ import annotations

import statistics
from typing import Any

from .profile_generator import mps_to_mph


def _values(events: list[dict], key: str) -> list[float]:
    result = []
    for event in events:
        value = event.get(key)
        if isinstance(value, (int, float)):
            result.append(float(value))
    return result


def _mean(values: list[float]) -> float:
    return statistics.fmean(values) if values else 0.0


def _median(values: list[float]) -> float:
    return statistics.median(values) if values else 0.0


def _std(values: list[float]) -> float:
    return statistics.pstdev(values) if len(values) > 1 else 0.0


def calculate_metrics(profile: dict[str, Any], all_events: list[dict[str, Any]], state: str) -> dict[str, Any]:
    events = [event for event in all_events if event.get("event_type") == "location_write"]
    successful = [event for event in events if event.get("location_write_success")]
    speeds = _values(successful, "host_calculated_apparent_speed_mps")
    moving_speeds = [value for value in speeds if value > 0.05]
    actual_intervals = _values(successful, "actual_interval_s")
    planned_intervals = _values(events, "planned_interval_s")
    drift = _values(events, "timing_drift_s")
    latency = _values(events, "write_latency_s")
    emitted_distance = sum(_values(successful, "distance_from_previous_m"))
    planned_distance = float(profile.get("generated_distance_m", 0.0))
    actual_duration = max(_values(events, "actual_elapsed_s"), default=0.0)
    planned_duration = float(profile.get("planned_duration_s", 0.0))
    stationary_duration = sum(float(event.get("actual_interval_s") or 0.0) for event in successful if float(event.get("host_calculated_apparent_speed_mps") or 0.0) <= 0.05)
    moving_duration = max(0.0, actual_duration - stationary_duration)
    sequences = [event.get("sequence_number") for event in successful]
    duplicates = sum(1 for event in successful if float(event.get("distance_from_previous_m") or 0.0) <= 0.01)
    disconnects = sum(1 for event in events if event.get("device_connected_before_write") is False or event.get("device_connected_after_write") is False)
    failures = len(events) - len(successful)
    return {
        "schema_version": "1.0",
        "state": state,
        "planned_route_distance_m": float(profile.get("requested_distance_m", 0.0)),
        "generated_profile_distance_m": planned_distance,
        "emitted_distance_m": emitted_distance,
        "distance_error_m": emitted_distance - planned_distance,
        "distance_error_percent": ((emitted_distance - planned_distance) / planned_distance * 100.0) if planned_distance else 0.0,
        "planned_duration_s": planned_duration,
        "actual_duration_s": actual_duration,
        "duration_error_s": actual_duration - planned_duration,
        "planned_average_apparent_speed_mph": mps_to_mph(float(profile.get("planned_average_apparent_speed_mps", 0.0))),
        "host_calculated_average_apparent_speed_mph": mps_to_mph(emitted_distance / actual_duration) if actual_duration else 0.0,
        "median_apparent_speed_mph": mps_to_mph(_median(moving_speeds)),
        "maximum_apparent_speed_mph": mps_to_mph(max(speeds, default=0.0)),
        "minimum_moving_apparent_speed_mph": mps_to_mph(min(moving_speeds, default=0.0)),
        "apparent_speed_standard_deviation_mph": mps_to_mph(_std(moving_speeds)),
        "planned_interval_mean_s": _mean(planned_intervals),
        "actual_interval_mean_s": _mean(actual_intervals),
        "actual_interval_median_s": _median(actual_intervals),
        "actual_interval_standard_deviation_s": _std(actual_intervals),
        "timing_drift_mean_s": _mean(drift),
        "timing_drift_maximum_s": max((abs(value) for value in drift), default=0.0),
        "command_latency_mean_s": _mean(latency),
        "command_latency_median_s": _median(latency),
        "command_latency_maximum_s": max(latency, default=0.0),
        "successful_writes": len(successful),
        "failed_writes": failures,
        "write_failure_rate": failures / len(events) if events else 0.0,
        "disconnect_count": disconnects,
        "duplicate_coordinate_count": duplicates,
        "stationary_duration_s": stationary_duration,
        "moving_duration_s": moving_duration,
        "completed_percentage": min(100.0, emitted_distance / planned_distance * 100.0) if planned_distance else (100.0 if state == "completed" else 0.0),
        "sample_sequence_complete": sequences == list(range(len(sequences))) if sequences else False,
    }
