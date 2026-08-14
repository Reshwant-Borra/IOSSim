from __future__ import annotations

import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

from drive_controller import LatLon, haversine_m, route_distance_m
from drive_testing.experiment_store import ExperimentStore, redact
from drive_testing.gpx_generator import coordinate_only_gpx, timestamped_gpx
from drive_testing.metrics import calculate_metrics
from drive_testing.profile_generator import generate_profile, mph_to_mps, mps_to_mph
from drive_testing.quality_control import evaluate_quality
from drive_testing.route_sampler import truncate_route
from drive_testing.schemas import ObservationBody


ROUTE = [
    {"lat": 28.0, "lon": -82.0},
    {"lat": 28.0, "lon": -81.98},
    {"lat": 28.02, "lon": -81.98},
]


class DriveTestingCoreTests(unittest.TestCase):
    def test_speed_conversions(self) -> None:
        self.assertAlmostEqual(mph_to_mps(20), 8.9408, places=4)
        self.assertAlmostEqual(mps_to_mph(8.9408), 20, places=4)

    def test_haversine_and_route_truncation_add_exact_final_point(self) -> None:
        self.assertAlmostEqual(haversine_m(LatLon(0, 0), LatLon(0, 0)), 0)
        truncated = truncate_route(ROUTE, 804.672)
        self.assertGreaterEqual(len(truncated), 2)
        self.assertAlmostEqual(route_distance_m(truncated), 804.672, delta=0.1)
        self.assertNotEqual(truncated[-1], LatLon(**ROUTE[1]))

    def test_constant_profile_is_exact_and_deterministic(self) -> None:
        settings = {"name": "20 mph", "kind": "constant", "target_speed_mph": 20, "distance_miles": 0.6, "update_interval_s": 1, "random_seed": 19}
        first = generate_profile(ROUTE, settings)
        second = generate_profile(ROUTE, settings)
        self.assertEqual(first, second)
        self.assertAlmostEqual(first["generated_distance_m"], first["requested_distance_m"], delta=0.2)
        self.assertAlmostEqual(first["samples"][1]["target_apparent_speed_mps"], 8.9408, places=4)
        self.assertEqual(first["samples"][-1]["phase"], "completed")

    def test_acceleration_deceleration_city_and_highway_profiles(self) -> None:
        cases = [
            ({"kind": "acceleration", "target_speed_mph": 20, "transition_s": 15}, "accelerating"),
            ({"kind": "deceleration", "target_speed_mph": 25, "transition_s": 15}, "decelerating"),
            ({"kind": "city", "target_speed_mph": 25}, "stopped"),
            ({"kind": "highway", "target_speed_mph": 60}, "accelerating"),
        ]
        for values, expected_phase in cases:
            profile = generate_profile(ROUTE, {**values, "distance_miles": 0.6, "update_interval_s": 1, "random_seed": 2})
            phases = {sample["phase"] for sample in profile["samples"]}
            self.assertIn(expected_phase, phases)
            self.assertLess(len(profile["samples"]), 1000)

    def test_variable_timing_is_seeded_and_bounded(self) -> None:
        settings = {"kind": "irregular_timing", "target_speed_mph": 20, "distance_miles": 0.4, "update_interval_s": 2, "random_seed": 77}
        profile = generate_profile(ROUTE, settings)
        intervals = [sample["planned_interval_s"] for sample in profile["samples"][1:]]
        self.assertGreater(len(set(intervals)), 3)
        self.assertTrue(all(1.1 <= value <= 2.9 for value in intervals[:-1]))
        self.assertEqual(profile, generate_profile(ROUTE, settings))

    def test_coordinate_only_and_timestamped_gpx(self) -> None:
        profile = generate_profile(ROUTE, {"kind": "constant", "target_speed_mph": 20, "distance_m": 30, "update_interval_s": 1})
        plain = coordinate_only_gpx(profile["samples"])
        timed = timestamped_gpx(profile["samples"], datetime(2026, 1, 1, tzinfo=timezone.utc))
        plain_root = ET.fromstring(plain)
        timed_root = ET.fromstring(timed)
        self.assertEqual(len(plain_root.findall(".//time")), 0)
        times = [node.text for node in timed_root.findall(".//time")]
        self.assertEqual(len(times), len(profile["samples"]))
        self.assertEqual(times, sorted(times))
        self.assertEqual(len(timed_root.findall(".//ele")), 0)
        self.assertNotIn("speed", timed)
        self.assertNotIn("course", timed)

    def test_event_logging_redaction_metrics_and_manifest(self) -> None:
        profile = generate_profile(ROUTE, {"name": "test", "kind": "constant", "target_speed_mph": 20, "distance_m": 20, "update_interval_s": 1})
        with tempfile.TemporaryDirectory() as tmp:
            store = ExperimentStore(Path(tmp))
            manifest = store.create(ROUTE, profile, {"repeats": 1, "device": {"udid": "1234567890ABCDEF"}, "start_address": "private"})
            experiment_id = manifest["experiment_id"]
            stored = store.read_json(experiment_id, "manifest.json")
            self.assertNotIn("1234567890ABCDEF", json.dumps(stored))
            self.assertNotIn("private", json.dumps(stored))
            event = store.append_event(experiment_id, {"event_type": "location_write", "experiment_id": experiment_id, "sequence_number": 0, "location_write_success": True, "actual_elapsed_s": 1.0, "distance_from_previous_m": 5.0, "actual_interval_s": 1.0, "planned_interval_s": 1.0, "timing_drift_s": 0.0, "write_latency_s": 0.1, "host_calculated_apparent_speed_mps": 5.0})
            self.assertEqual(store.events(experiment_id), [event])
            metrics = calculate_metrics(profile, [event], "completed")
            self.assertEqual(metrics["successful_writes"], 1)
            self.assertEqual(metrics["emitted_distance_m"], 5.0)
            store.write_json(experiment_id, "summary.json", metrics)
            stored = store.update_manifest(experiment_id, state="completed", repeat_number=1, config={"feature_flags_enabled": True, "device_connected_before_start": True, "tunnel_ready_before_start": True})
            qc = evaluate_quality(stored, profile, metrics, [event], store.path_for(experiment_id), [])
            self.assertIn(qc["status"], {"FAIL", "PASS WITH WARNINGS"})

    def test_output_redaction_and_observation_validation(self) -> None:
        value = redact({"udid": "secret", "rsd_address": "fd00::1", "nested": {"command_details": "secret"}})
        self.assertNotIn("secret", json.dumps(value))
        observation = ObservationBody(result="Trip observed", phone_state="stationary", notes="manual")
        self.assertEqual(observation.result, "trip_observed")
        with self.assertRaises(ValueError):
            ObservationBody(result="guaranteed drive")
        with self.assertRaises(ValueError):
            ObservationBody(result="inconclusive", screenshot_filename="../private.png")


if __name__ == "__main__":
    unittest.main()
