from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from drive_routing import DriveRoutingClient, cache_key, normalize_address


class DriveRoutingTests(unittest.TestCase):
    def test_normalize_address_and_cache_key_are_stable(self) -> None:
        self.assertEqual(normalize_address("  1  Main St,   Boston "), "1 main st, boston")
        self.assertEqual(cache_key("abc"), cache_key("abc"))
        self.assertNotEqual(cache_key("abc"), cache_key("abcd"))

    def test_geocode_uses_cache_after_first_provider_call(self) -> None:
        calls: list[str] = []

        def fake_get(url: str, headers: dict[str, str], timeout_s: float) -> list[dict]:
            calls.append(url)
            self.assertIn("User-Agent", headers)
            return [{"display_name": "Test Place", "lat": "37.1", "lon": "-122.2"}]

        with tempfile.TemporaryDirectory() as tmp:
            client = DriveRoutingClient(Path(tmp), fake_get)
            first = client.geocode("Test Place")
            second = client.geocode("  test   place ")

        self.assertTrue(first["ok"])
        self.assertFalse(first["cached"])
        self.assertTrue(second["cached"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(first["results"][0]["lat"], 37.1)

    def test_route_parses_osrm_geojson_coordinates(self) -> None:
        def fake_get(url: str, headers: dict[str, str], timeout_s: float) -> dict:
            self.assertIn("router.project-osrm.org", url)
            return {
                "code": "Ok",
                "routes": [
                    {
                        "distance": 1234.5,
                        "duration": 240.0,
                        "geometry": {
                            "coordinates": [
                                [-122.0, 37.0],
                                [-122.1, 37.1],
                                [-122.2, 37.2],
                            ]
                        },
                    }
                ],
            }

        with tempfile.TemporaryDirectory() as tmp:
            client = DriveRoutingClient(Path(tmp), fake_get)
            result = client.route({"lat": 37.0, "lon": -122.0}, {"lat": 37.2, "lon": -122.2})

        self.assertTrue(result["ok"])
        self.assertEqual(result["provider"], "osrm")
        self.assertEqual(result["profile"], "driving")
        self.assertEqual(len(result["coordinates"]), 3)
        self.assertEqual(result["coordinates"][1], {"lat": 37.1, "lon": -122.1})
        self.assertEqual(result["distance_m"], 1234.5)


if __name__ == "__main__":
    unittest.main()
