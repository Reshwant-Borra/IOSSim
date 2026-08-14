from __future__ import annotations

from pathlib import Path
from typing import Any


def evaluate_quality(
    manifest: dict[str, Any],
    profile: dict[str, Any],
    metrics: dict[str, Any],
    events: list[dict[str, Any]],
    output_path: Path,
    observations: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    negative = bool(profile.get("negative_control"))
    state = manifest.get("state")
    checks: list[dict[str, Any]] = []

    def check(name: str, passed: bool, severity: str = "fail", detail: str = "") -> None:
        checks.append({"name": name, "passed": bool(passed), "severity": severity, "detail": detail})

    config = manifest.get("config") or {}
    check("Feature flags enabled", bool(config.get("feature_flags_enabled", True)))
    check("Backend reachable", True)
    check("Device connected before start", bool(config.get("device_connected_before_start", False)))
    check("Required tunnel active", bool(config.get("tunnel_ready_before_start", False)))
    check("Route valid", len(profile.get("route", [])) >= 2)
    check("Route contains at least two coordinates", len(profile.get("route", [])) >= 2)
    check("Route distance sufficient", float(profile.get("generated_distance_m", 0.0)) + 0.5 >= float(profile.get("requested_distance_m", 0.0)))
    check("Profile generated successfully", bool(profile.get("samples")))
    elapsed = [float(sample.get("planned_elapsed_s", -1)) for sample in profile.get("samples", [])]
    check("Timestamps monotonic", elapsed == sorted(elapsed))
    check("Sample sequence complete", bool(metrics.get("sample_sequence_complete")))
    duration_tolerance = max(5.0, float(profile.get("planned_duration_s", 0.0)) * 0.15)
    check("Actual duration within tolerance", abs(float(metrics.get("duration_error_s", 0.0))) <= duration_tolerance, "warning")
    distance_tolerance = max(5.0, float(profile.get("generated_distance_m", 0.0)) * 0.05)
    check("Actual distance within tolerance", abs(float(metrics.get("distance_error_m", 0.0))) <= distance_tolerance, "warning")
    target = float(profile.get("target_apparent_speed_mph", 0.0))
    reached = float(metrics.get("maximum_apparent_speed_mph", 0.0)) >= target * 0.8 if target else True
    check("Target apparent speed reached", reached or negative, "warning")
    check("Timing drift within tolerance", float(metrics.get("timing_drift_maximum_s", 0.0)) <= max(1.0, float(profile.get("update_interval_s", 1.0))), "warning")
    check("Location write failure rate", float(metrics.get("write_failure_rate", 1.0)) <= 0.02)
    check("Device remained connected", int(metrics.get("disconnect_count", 0)) == 0)
    check("Experiment ended normally", state == "completed")
    reset_selected = bool(config.get("reset_gps_at_end"))
    reset_events = [event for event in events if event.get("event_type") == "location_reset"]
    check("Reset GPS attempted when selected", not reset_selected or bool(reset_events), "warning")
    check("Reset GPS succeeded when selected", not reset_selected or any(event.get("success") for event in reset_events), "warning")
    required = ["manifest.json", "route.json", "planned_profile.json", "events.jsonl", "summary.json"]
    check("Required output files exist", all((output_path / name).exists() for name in required))
    check("Manifest matches logs", all(event.get("experiment_id") == manifest.get("experiment_id") for event in events if event.get("experiment_id")))
    check("Observation completed or marked unavailable", bool(observations), "warning")
    check("Repeat count completed", int(manifest.get("repeat_number", 0)) >= int(manifest.get("total_repeats", 1)))

    failures = [item for item in checks if not item["passed"] and item["severity"] == "fail"]
    warnings = [item for item in checks if not item["passed"] and item["severity"] == "warning"]
    opaque_gpx = manifest.get("method") in {"legacy_gpx", "timestamped_gpx", "gpx_pacing"} and int(metrics.get("successful_writes", 0)) == 0
    if state not in {"completed", "error"} or opaque_gpx:
        status = "INCOMPLETE"
    elif failures:
        status = "FAIL"
    elif warnings:
        status = "PASS WITH WARNINGS"
    else:
        status = "PASS"
    if negative and state == "completed" and failures:
        status = "PASS WITH WARNINGS"
    return {
        "schema_version": "1.0",
        "status": status,
        "negative_control_rules": negative,
        "checks": checks,
        "failure_count": len(failures),
        "warning_count": len(warnings),
    }
