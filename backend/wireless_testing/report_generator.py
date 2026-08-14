from __future__ import annotations

from typing import Any


def generate_report(record: dict[str, Any]) -> str:
    summary = record.get("summary") or {}
    observations = record.get("observations") or []
    latest_observation = observations[-1] if observations else {}
    attempts = summary.get("tunnel_attempts") or []
    attempt_lines = []
    for attempt in attempts:
        if not isinstance(attempt, dict):
            continue
        protocol = str(attempt.get("protocol") or "unknown").upper()
        if attempt.get("ok"):
            attempt_lines.append(f"- {protocol}: PASS, RSD endpoint emitted.")
        else:
            attempt_lines.append(f"- {protocol}: {attempt.get('failure_class') or 'unknown'} - {attempt.get('failure_message') or 'no detail'}")
    lines = [
        "# IOSSim Wireless Testing Report",
        "",
        f"Experiment ID: {record.get('experiment_id')}",
        f"Test type: {record.get('test_type')}",
        f"Date: {record.get('created_at')}",
        f"Repository commit: {record.get('repository_commit', 'unknown')}",
        f"IOSSim version: {record.get('iossim_version')}",
        f"pymobiledevice3 version: {summary.get('pymobiledevice3_version', 'unknown')}",
        f"iOS version: {summary.get('ios_version', 'unknown')}",
        "",
        "## Evidence",
        "",
        f"USB connected at test start: {summary.get('usb_connected_at_start', 'unknown')}",
        f"USB confirmed absent before Wi-Fi tunnel: {summary.get('usb_absent_before_tunnel', 'unknown')}",
        f"Wireless device discovered: {summary.get('wireless_discovery', 'unknown')}",
        f"Pairing bootstrap: {summary.get('pairing_bootstrap_status', 'unknown')}",
        f"Wi-Fi connections enabled: {summary.get('wifi_connections_status', 'unknown')}",
        f"Pairing preparation: {summary.get('pairing_preparation_status', 'unknown')}",
        f"Wi-Fi developer tunnel established: {summary.get('wifi_tunnel', 'unknown')}",
        f"Fresh RSD obtained over Wi-Fi: {summary.get('fresh_wifi_rsd', 'unknown')}",
        f"Set Location command result: {summary.get('set_location', 'unknown')}",
        f"Manual location confirmation: {summary.get('manual_location_confirmation', latest_observation.get('location_changed', 'not recorded'))}",
        f"Reset GPS command result: {summary.get('reset_gps', 'unknown')}",
        f"Tunnel stable after operations: {summary.get('tunnel_stable', 'unknown')}",
        f"Repeatability: {summary.get('repeatability', 'not established by one run')}",
        "",
        "## Provenance",
        "",
        f"Tunnel created after USB absence: {summary.get('tunnel_created_after_usb_absence', 'unknown')}",
        f"Tunnel creation timestamp: {summary.get('tunnel_created_at', 'not recorded')}",
        f"Discovery method: {summary.get('discovery_method', 'unknown')}",
        f"Transport requested: {summary.get('transport_requested', 'unknown')}",
        f"Transport reported: {summary.get('transport_reported', 'unknown')}",
        f"RSD endpoint source: {summary.get('rsd_source', 'unknown')}",
        f"Selected tunnel protocol: {summary.get('selected_protocol', 'unknown')}",
        f"Last tunnel failure class: {summary.get('last_tunnel_failure_class', 'none')}",
        "",
        "## Tunnel Attempts",
        "",
        *(attempt_lines or ["No tunnel attempts recorded."]),
        "",
        "## Interpretation",
        "",
        summary.get(
            "interpretation",
            "This report records one hardware/configuration-specific wireless IOSSim experiment. It does not generalize to every iPhone, iOS version, host OS, or network.",
        ),
        "",
        "## Recovery",
        "",
        "If wireless reset failed or the device state is uncertain, reconnect USB, return to stable IOSSim, initialize the USB tunnel, and run Reset GPS.",
        "",
        "## Verdict",
        "",
        record.get("verdict", "INCONCLUSIVE"),
        "",
    ]
    return "\n".join(lines)
