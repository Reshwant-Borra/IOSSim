from __future__ import annotations

import time
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from drive_controller import DriveController, LatLon, interpolate_route, route_distance_m


class DriveControllerTests(unittest.TestCase):
    def test_route_distance_and_interpolation(self) -> None:
        route = [LatLon(0.0, 0.0), LatLon(0.0, 0.001)]
        total = route_distance_m(route)

        self.assertGreater(total, 100)
        midpoint = interpolate_route(route, total / 2)
        self.assertAlmostEqual(midpoint.lat, 0.0, places=6)
        self.assertAlmostEqual(midpoint.lon, 0.0005, places=4)

    def test_interpolation_follows_route_geometry(self) -> None:
        route = [LatLon(0.0, 0.0), LatLon(0.0, 0.001), LatLon(0.001, 0.001)]
        first_leg = route_distance_m(route[:2])
        coord = interpolate_route(route, first_leg + 10)

        self.assertAlmostEqual(coord.lon, 0.001, places=6)
        self.assertGreater(coord.lat, 0.0)

    def test_eta_uses_selected_speed(self) -> None:
        controller = DriveController(
            lambda lat, lon: {"ok": True},
            lambda: {"ok": True},
        )
        status = controller.start(
            [{"lat": 0.0, "lon": 0.0}, {"lat": 0.0, "lon": 0.001}],
            speed_mps=10.0,
            tick_s=1.0,
        )

        self.assertTrue(status["ok"])
        self.assertAlmostEqual(status["eta_s"], status["total_distance_m"] / 10.0, delta=0.5)
        controller.stop()

    def test_drive_arrives_and_keeps_final_location(self) -> None:
        writes: list[tuple[float, float]] = []

        controller = DriveController(
            lambda lat, lon: writes.append((lat, lon)) or {"ok": True},
            lambda: {"ok": True},
        )

        result = controller.start(
            [{"lat": 0.0, "lon": 0.0}, {"lat": 0.0, "lon": 0.0001}],
            speed_mps=35.0,
            tick_s=1.0,
            stay_at_end=True,
        )

        self.assertTrue(result["ok"])
        deadline = time.monotonic() + 3
        status = controller.status()
        while status["state"] not in {"arrived", "error"} and time.monotonic() < deadline:
            time.sleep(0.05)
            status = controller.status()

        self.assertEqual(status["state"], "arrived")
        self.assertGreaterEqual(status["progress"], 1.0)
        self.assertTrue(writes)
        self.assertAlmostEqual(writes[-1][1], 0.0001, places=6)

    def test_pause_freezes_elapsed_time(self) -> None:
        controller = DriveController(
            lambda lat, lon: {"ok": True},
            lambda: {"ok": True},
        )
        controller.start(
            [{"lat": 0.0, "lon": 0.0}, {"lat": 0.0, "lon": 0.01}],
            speed_mps=1.0,
            tick_s=1.0,
        )
        time.sleep(0.1)
        paused = controller.pause()
        self.assertEqual(paused["state"], "paused")
        elapsed = paused["elapsed_s"]
        time.sleep(0.25)
        self.assertAlmostEqual(controller.status()["elapsed_s"], elapsed, places=2)

        resumed = controller.resume()
        self.assertEqual(resumed["state"], "driving")
        controller.stop()


if __name__ == "__main__":
    unittest.main()
