from __future__ import annotations

import tempfile
import unittest
import urllib.error
import ssl
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

import main
from geocoding import GeocodingClient, ProviderError, _http_get_json, _verified_ssl_context, cache_key, normalize_cache_ownership, read_cache, write_cache


class GeocodingTests(unittest.TestCase):
    def test_blank_query_rejected_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = GeocodingClient(Path(tmp), lambda *_: []).search("   ")
        self.assertFalse(result["ok"])
        self.assertEqual(result["results"], [])
        self.assertIn("Enter a place", result["message"])

    def test_normal_query_returns_normalized_structured_results(self) -> None:
        calls: list[str] = []

        def fake_get(url: str, headers: dict[str, str], timeout_s: float) -> list[dict]:
            calls.append(url)
            self.assertIn("User-Agent", headers)
            return [
                {
                    "place_id": 123,
                    "display_name": "Tampa International Airport, Tampa, Hillsborough County, Florida, United States",
                    "lat": "27.97547",
                    "lon": "-82.53325",
                    "class": "aeroway",
                    "type": "aerodrome",
                    "boundingbox": ["27.9", "28.0", "-82.6", "-82.5"],
                    "address": {"aeroway": "Tampa International Airport", "city": "Tampa", "state": "Florida", "country": "United States"},
                }
            ]

        with tempfile.TemporaryDirectory() as tmp:
            result = GeocodingClient(Path(tmp), fake_get).search("  Tampa   International Airport ")

        self.assertTrue(result["ok"])
        self.assertFalse(result["cached"])
        self.assertIn("q=tampa+international+airport", calls[0])
        self.assertEqual(result["results"][0]["lat"], 27.97547)
        self.assertEqual(result["results"][0]["lon"], -82.53325)
        self.assertEqual(result["results"][0]["primary_label"], "Tampa International Airport")
        self.assertEqual(result["results"][0]["provider"], "nominatim")
        self.assertEqual(result["results"][0]["class"], "aeroway")

    def test_invalid_provider_rows_are_skipped_and_limit_is_respected(self) -> None:
        rows = [
            {"display_name": "missing lat", "lon": "1"},
            {"display_name": "bad lat", "lat": "nan?", "lon": "1"},
            *[
                {"display_name": f"Place {index}", "lat": str(index), "lon": str(index + 10)}
                for index in range(7)
            ],
        ]
        with tempfile.TemporaryDirectory() as tmp:
            result = GeocodingClient(Path(tmp), lambda *_: rows).search("places", limit=5)
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["results"]), 5)
        self.assertEqual(result["results"][0]["display_name"], "Place 0")

    def test_cache_hit_avoids_duplicate_provider_call(self) -> None:
        calls = 0

        def fake_get(url: str, headers: dict[str, str], timeout_s: float) -> list[dict]:
            nonlocal calls
            calls += 1
            return [{"display_name": "New York, United States", "lat": "40.7128", "lon": "-74.0060"}]

        with tempfile.TemporaryDirectory() as tmp:
            client = GeocodingClient(Path(tmp), fake_get)
            first = client.search("New York")
            second = client.search("  new   york ")

        self.assertTrue(first["ok"])
        self.assertFalse(first["cached"])
        self.assertTrue(second["cached"])
        self.assertEqual(calls, 1)

    def test_provider_timeout_handled(self) -> None:
        with patch("urllib.request.urlopen", side_effect=TimeoutError()):
            with self.assertRaises(ProviderError) as caught:
                _http_get_json("https://example.test", {}, 1.0)
        self.assertEqual(caught.exception.kind, "timeout")

    def test_http_provider_failure_handled(self) -> None:
        error = urllib.error.HTTPError("https://example.test", 500, "Server Error", None, None)
        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(ProviderError) as caught:
                _http_get_json("https://example.test", {}, 1.0)
        self.assertEqual(caught.exception.kind, "http_error")
        self.assertEqual(caught.exception.status, 500)

    def test_http_429_handled(self) -> None:
        error = urllib.error.HTTPError("https://example.test", 429, "Too Many Requests", None, None)
        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaisesRegex(ProviderError, "rate limit"):
                _http_get_json("https://example.test", {}, 1.0)

    def test_unreadable_response_handled(self) -> None:
        class Headers:
            def get_content_charset(self):
                return "utf-8"

        class Response:
            headers = Headers()

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self) -> bytes:
                return b"{not json"

        with patch("urllib.request.urlopen", return_value=Response()):
            with self.assertRaises(ProviderError) as caught:
                _http_get_json("https://example.test", {}, 1.0)
        self.assertEqual(caught.exception.kind, "json_error")

    def test_url_provider_failure_handled(self) -> None:
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("offline")):
            with self.assertRaises(ProviderError) as caught:
                _http_get_json("https://example.test", {}, 1.0)
        self.assertEqual(caught.exception.kind, "network_error")
        self.assertEqual(caught.exception.detail, "offline")

    def test_tls_error_classified_and_verification_not_bypassed(self) -> None:
        tls_error = ssl.SSLCertVerificationError("unable to get local issuer certificate")
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError(tls_error)):
            with self.assertRaises(ProviderError) as caught:
                _http_get_json("https://example.test", {}, 1.0)
        self.assertEqual(caught.exception.kind, "tls_error")

        context = _verified_ssl_context()
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)

    def test_cache_write_read_behavior(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / f"{cache_key('abc')}.json"
            write_cache(path, {"ok": True, "results": [{"lat": 1, "lon": 2}]})
            self.assertEqual(read_cache(path), {"ok": True, "results": [{"lat": 1, "lon": 2}]})
            path.write_text("{bad json", encoding="utf-8")
            self.assertIsNone(read_cache(path))

    def test_root_cache_write_normalizes_to_repository_owner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "geocode" / "entry.json"
            path.parent.mkdir()
            path.write_text("{}", encoding="utf-8")
            calls: list[tuple[Path, int, int]] = []
            owner = Path(__file__).resolve().parent.stat()

            def fake_chown(item: Path, uid: int, gid: int) -> None:
                calls.append((item, uid, gid))

            with patch("geocoding.os.geteuid", return_value=0), patch("geocoding.os.chown", side_effect=fake_chown):
                normalize_cache_ownership(path)

        self.assertEqual(calls, [(path.parent, owner.st_uid, owner.st_gid), (path, owner.st_uid, owner.st_gid)])


class LocationSearchApiTests(unittest.TestCase):
    def test_api_endpoint_schema(self) -> None:
        class FakeSearch:
            def search(self, query: str, limit: int = 5) -> dict:
                self.query = query
                self.limit = limit
                return {
                    "ok": True,
                    "provider": "nominatim",
                    "cached": False,
                    "results": [{"display_name": "Times Square, New York, United States", "lat": 40.758, "lon": -73.9855}],
                    "message": "",
                }

        fake = FakeSearch()
        with patch.object(main, "location_search", fake):
            response = TestClient(main.app).post("/api/location/search", json={"query": "Times Square", "limit": 3})

        self.assertEqual(response.status_code, 200, response.text)
        data = response.json()
        self.assertEqual(data["provider"], "nominatim")
        self.assertFalse(data["cached"])
        self.assertEqual(data["results"][0]["lat"], 40.758)
        self.assertEqual(fake.query, "Times Square")
        self.assertEqual(fake.limit, 3)

    def test_api_blank_query_returns_400(self) -> None:
        response = TestClient(main.app).post("/api/location/search", json={"query": "   "})
        self.assertEqual(response.status_code, 400)
        self.assertFalse(response.json()["ok"])

    def test_api_provider_failure_returns_stable_detail(self) -> None:
        class FailingSearch:
            def search(self, query: str, limit: int = 5) -> dict:
                return {
                    "ok": False,
                    "provider": "nominatim",
                    "cached": False,
                    "results": [],
                    "code": "GEOCODING_PROVIDER_UNAVAILABLE",
                    "error_kind": "tls_error",
                    "message": "Location search provider is temporarily unavailable.",
                }

        with patch.object(main, "location_search", FailingSearch()):
            response = TestClient(main.app).post("/api/location/search", json={"query": "Tampa"})

        self.assertEqual(response.status_code, 502)
        data = response.json()
        self.assertEqual(data["detail"]["code"], "GEOCODING_PROVIDER_UNAVAILABLE")
        self.assertNotIn("CERTIFICATE_VERIFY_FAILED", response.text)


if __name__ == "__main__":
    unittest.main()
