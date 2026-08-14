from __future__ import annotations

from typing import Any


VERDICTS = {
    "drive_observed": "DRIVE OBSERVED",
    "trip_observed": "TRIP OBSERVED",
    "no_event_observed": "NO EVENT OBSERVED",
    "still_processing": "OBSERVATION PENDING",
    "application_not_checked": "OBSERVATION PENDING",
    "inconclusive": "INCONCLUSIVE",
    "test_failed": "TEST FAILED",
    "other": "INCONCLUSIVE",
}


def generate_report(record: dict[str, Any]) -> str:
    profile = record.get("profile") or {}
    summary = record.get("summary") or {}
    qc = record.get("qc") or {}
    observations = record.get("observations") or []
    observation = observations[-1] if observations else {}
    result = observation.get("result", "application_not_checked")
    verdict = VERDICTS.get(result, "INCONCLUSIVE")
    lines = [
        "# IOSSim Drive Testing Experiment Report",
        "",
        f"Experiment ID: {record.get('experiment_id')}",
        f"Run ID: {record.get('run_id') or 'Not started'}",
        f"Repository commit: {record.get('repository_commit', 'unknown')}",
        f"Date: {record.get('created_at')}",
        f"IOSSim version: {record.get('iossim_version')}",
        f"Profile: {record.get('profile_name')}",
        f"Test method: {record.get('method')}",
        f"QC result: {qc.get('status', 'INCOMPLETE')}",
        "",
        "## Planned Metrics",
        "",
        f"Requested distance: {float(profile.get('requested_distance_m', 0.0)):.2f} m",
        f"Generated distance: {float(profile.get('generated_distance_m', 0.0)):.2f} m",
        f"Planned duration: {float(profile.get('planned_duration_s', 0.0)):.2f} s",
        f"Host-planned apparent speed: {float(profile.get('target_apparent_speed_mph', 0.0)):.2f} mph",
        "",
        "## Actual Host-Side Metrics",
        "",
        f"Emitted distance: {float(summary.get('emitted_distance_m', 0.0)):.2f} m",
        f"Actual duration: {float(summary.get('actual_duration_s', 0.0)):.2f} s",
        f"Host-calculated average apparent speed: {float(summary.get('host_calculated_average_apparent_speed_mph', 0.0)):.2f} mph",
        f"Successful location writes: {int(summary.get('successful_writes', 0))}",
        f"Failed location writes: {int(summary.get('failed_writes', 0))}",
        "",
        "## Observed Result",
        "",
        result.replace("_", " ").capitalize() + ".",
        "",
        "## Recorded Test Conditions",
        "",
        f"Phone state: {observation.get('phone_state', 'not recorded')}",
        f"Screen state: {observation.get('screen_state', 'not recorded')}",
        f"Application state: {observation.get('application_state', 'not recorded')}",
        f"Motion & Fitness enabled: {observation.get('motion_fitness_enabled', 'not recorded')}",
        f"Notes: {observation.get('notes', '')}",
        "",
        "## Interpretation",
        "",
        observation.get("interpretation") or "This run records an exploratory association under the entered conditions. It does not identify which external application signals caused the observation.",
        "",
        "## Uncertainty",
        "",
        "IOSSim controls coordinate sequence and host timing. It does not directly measure CLLocation.speed, CLLocation.course, motion sensors, Core Motion automotive classification, Arity confidence, or a third-party application's internal trip state.",
        "",
        "## Recommended Next Test",
        "",
        "Repeat the same configuration at least three times before suggesting a pattern, then vary one parameter only.",
        "",
        "## Verdict",
        "",
        verdict,
        "",
    ]
    return "\n".join(lines)


def qc_markdown(qc: dict[str, Any]) -> str:
    lines = ["# Quality Control Report", "", f"Status: {qc.get('status')}", ""]
    for check in qc.get("checks", []):
        marker = "PASS" if check.get("passed") else check.get("severity", "FAIL").upper()
        lines.append(f"- [{marker}] {check.get('name')}: {check.get('detail', '')}")
    return "\n".join(lines) + "\n"
