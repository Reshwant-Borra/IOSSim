"""
drive_routing.py - Light geocoding and road-routing helpers for Drive Mode.

Uses public Nominatim and OSRM endpoints for personal testing only. Responses
are cached locally to avoid repeat requests while experimenting.
"""
from __future__ import annotations

import urllib.parse
from pathlib import Path
from typing import Any, Callable

from geocoding import GeocodingClient, ProviderError, _headers, _http_get_json, cache_key, normalize_query, read_cache, write_cache

OSRM_ROUTE_URL = "https://router.project-osrm.org/route/v1/driving"

HttpGetter = Callable[[str, dict[str, str], float], Any]


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
        self.geocoder = GeocodingClient(self.geocode_cache_dir, self.http_get_json)

    def geocode(self, address: str) -> dict:
        return self.geocoder.search(address)

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
    return normalize_query(address)


def lat_lon(value: dict) -> tuple[float, float]:
    try:
        lat = float(value["lat"])
        lon = float(value["lon"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("Expected lat/lon coordinates.") from exc
    if not -90 <= lat <= 90 or not -180 <= lon <= 180:
        raise ValueError("Coordinates are outside valid latitude/longitude bounds.")
    return lat, lon
