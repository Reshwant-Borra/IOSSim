"""
drive_routing.py - Light geocoding and road-routing helpers for Drive Mode.

Uses public Nominatim and OSRM endpoints for personal testing only. Responses
are cached locally to avoid repeat requests while experimenting.
"""
from __future__ import annotations

import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable


USER_AGENT = "ios-location-sim/0.1 personal-testing"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
OSRM_ROUTE_URL = "https://router.project-osrm.org/route/v1/driving"

HttpGetter = Callable[[str, dict[str, str], float], Any]


class ProviderError(RuntimeError):
    pass


class DriveRoutingClient:
    def __init__(
        self,
        cache_dir: Path | None = None,
        http_get_json: HttpGetter | None = None,
    ) -> None:
        self.cache_dir = cache_dir or Path(__file__).parent / "data" / "route_cache"
        self.geocode_cache_dir = self.cache_dir / "geocode"
        self.route_cache_dir = self.cache_dir / "route"
        self.http_get_json = http_get_json or _http_get_json

    def geocode(self, address: str) -> dict:
        normalized = normalize_address(address)
        if not normalized:
            return {"ok": False, "message": "Enter an address to geocode."}

        cache_path = self.geocode_cache_dir / f"{cache_key(normalized)}.json"
        cached = read_cache(cache_path)
        if cached is not None:
            cached["cached"] = True
            return cached

        params = urllib.parse.urlencode(
            {
                "q": normalized,
                "format": "jsonv2",
                "limit": "5",
                "addressdetails": "0",
            }
        )
        try:
            data = self.http_get_json(f"{NOMINATIM_URL}?{params}", _headers(), 20.0)
        except ProviderError as exc:
            return {"ok": False, "message": str(exc)}

        results = []
        for item in data:
            try:
                results.append(
                    {
                        "display_name": item.get("display_name", ""),
                        "lat": float(item["lat"]),
                        "lon": float(item["lon"]),
                    }
                )
            except (KeyError, TypeError, ValueError):
                continue

        result = {
            "ok": bool(results),
            "provider": "nominatim",
            "cached": False,
            "results": results,
            "message": "" if results else "No geocoding matches found. Try a more specific address.",
        }
        write_cache(cache_path, result)
        return result

    def route(self, start: dict, destination: dict) -> dict:
        try:
            start_lat, start_lon = lat_lon(start)
            dest_lat, dest_lon = lat_lon(destination)
        except ValueError as exc:
            return {"ok": False, "message": str(exc)}

        key = cache_key(
            f"{round(start_lat, 5)},{round(start_lon, 5)}:"
            f"{round(dest_lat, 5)},{round(dest_lon, 5)}:driving"
        )
        cache_path = self.route_cache_dir / f"{key}.json"
        cached = read_cache(cache_path)
        if cached is not None:
            cached["cached"] = True
            return cached

        coords = f"{start_lon},{start_lat};{dest_lon},{dest_lat}"
        params = urllib.parse.urlencode(
            {
                "overview": "full",
                "geometries": "geojson",
                "alternatives": "false",
                "steps": "false",
            }
        )
        try:
            data = self.http_get_json(f"{OSRM_ROUTE_URL}/{coords}?{params}", _headers(), 30.0)
        except ProviderError as exc:
            return {"ok": False, "message": str(exc)}

        if data.get("code") != "Ok" or not data.get("routes"):
            message = data.get("message") or "OSRM could not build a driving route for those points."
            return {"ok": False, "message": message}

        route = data["routes"][0]
        geometry = route.get("geometry") or {}
        raw_coords = geometry.get("coordinates") or []
        coordinates = []
        for pair in raw_coords:
            if not isinstance(pair, (list, tuple)) or len(pair) < 2:
                continue
            coordinates.append({"lat": float(pair[1]), "lon": float(pair[0])})

        if len(coordinates) < 2:
            return {"ok": False, "message": "OSRM returned an empty route geometry."}

        result = {
            "ok": True,
            "provider": "osrm",
            "profile": "driving",
            "cached": False,
            "coordinates": coordinates,
            "distance_m": float(route.get("distance", 0.0)),
            "osrm_duration_s": float(route.get("duration", 0.0)),
            "message": "",
        }
        write_cache(cache_path, result)
        return result


def normalize_address(address: str) -> str:
    return re.sub(r"\s+", " ", address.strip()).lower()


def cache_key(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


def lat_lon(value: dict) -> tuple[float, float]:
    try:
        lat = float(value["lat"])
        lon = float(value["lon"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("Expected lat/lon coordinates.") from exc
    if not -90 <= lat <= 90 or not -180 <= lon <= 180:
        raise ValueError("Coordinates are outside valid latitude/longitude bounds.")
    return lat, lon


def read_cache(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def write_cache(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _headers() -> dict[str, str]:
    return {
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
    }


def _http_get_json(url: str, headers: dict[str, str], timeout_s: float) -> Any:
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout_s) as response:
            body = response.read().decode("utf-8")
            return json.loads(body)
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            raise ProviderError(
                "Provider rate limit reached. Nominatim/OSRM public endpoints are for light personal testing; wait before retrying."
            ) from exc
        raise ProviderError(f"Provider returned HTTP {exc.code}. Try again later.") from exc
    except urllib.error.URLError as exc:
        raise ProviderError(f"Provider request failed: {exc.reason}") from exc
    except TimeoutError as exc:
        raise ProviderError("Provider request timed out. Try again later.") from exc
    except json.JSONDecodeError as exc:
        raise ProviderError("Provider returned an unreadable response.") from exc
