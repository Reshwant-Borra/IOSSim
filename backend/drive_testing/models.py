from __future__ import annotations

from typing import Literal


SCHEMA_VERSION = "1.0"

ExperimentState = Literal[
    "idle",
    "validating",
    "ready",
    "starting",
    "running",
    "paused",
    "stopping",
    "completed",
    "cancelled",
    "error",
]

TestMethod = Literal[
    "timed_static",
    "legacy_gpx",
    "timestamped_gpx",
    "gpx_pacing",
    "stable_baseline",
]

OBSERVATION_RESULTS = {
    "drive_observed",
    "trip_observed",
    "no_event_observed",
    "still_processing",
    "application_not_checked",
    "inconclusive",
    "test_failed",
    "other",
}

ACTIVE_STATES = {"validating", "ready", "starting", "running", "paused", "stopping"}
LOCATION_WRITING_STATES = {"starting", "running", "paused", "stopping"}
