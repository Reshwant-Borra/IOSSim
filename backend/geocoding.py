"""
General location search/geocoding helpers for IOSSim.

Uses the public Nominatim endpoint for light personal testing only. Responses
are cached locally to avoid repeated provider calls for identical queries.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

import certifi


USER_AGENT = "ios-location-sim/0.1 personal-testing"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
DEFAULT_LIMIT = 5
MAX_LIMIT = 5

HttpGetter = Callable[[str, dict[str, str], float], Any]
logger = logging.getLogger(__name__)


class ProviderError(RuntimeError):
    def __init__(self, message: str, *, kind: str, detail: str = "", status: int | None = None) -> None:
        super().__init__(message)
        self.kind = kind
        self.detail = detail
        self.status = status


class GeocodingClient:
    def __init__(
        self,
        cache_dir: Path | None = None,
        http_get_json: HttpGetter | None = None,
    ) -> None:
        self.cache_dir = cache_dir or Path(__file__).parent / "data" / "route_cache" / "geocode"
        self.http_get_json = http_get_json or _http_get_json

    def search(self, query: str, limit: int = DEFAULT_LIMIT) -> dict:
        normalized = normalize_query(query)
        if not normalized:
            return {
                "ok": False,
                "provider": "nominatim",
                "cached": False,
                "results": [],
                "message": "Enter a place or address to search.",
            }

        result_limit = max(1, min(MAX_LIMIT, int(limit or DEFAULT_LIMIT)))
        cache_path = self.cache_dir / f"{cache_key(f'{normalized}:{result_limit}')}.json"
        cached = read_cache(cache_path)
        if cached is not None:
            cached["cached"] = True
            return cached

        params = urllib.parse.urlencode(
            {
                "q": normalized,
                "format": "jsonv2",
                "limit": str(result_limit),
                "addressdetails": "1",
            }
        )
        try:
            data = self.http_get_json(f"{NOMINATIM_URL}?{params}", _headers(), 20.0)
        except ProviderError as exc:
            logger.warning(
                "GEOCODING_PROVIDER_ERROR provider=nominatim kind=%s status=%s detail=%s",
                exc.kind,
                exc.status,
                exc.detail or str(exc),
            )
            return {
                "ok": False,
                "provider": "nominatim",
                "cached": False,
                "results": [],
                "code": "GEOCODING_PROVIDER_UNAVAILABLE",
                "error_kind": exc.kind,
                "message": str(exc),
            }

        if not isinstance(data, list):
            logger.warning(
                "GEOCODING_PROVIDER_ERROR provider=nominatim kind=unexpected_schema detail=response_type:%s",
                type(data).__name__,
            )
            return {
                "ok": False,
                "provider": "nominatim",
                "cached": False,
                "results": [],
                "code": "GEOCODING_PROVIDER_UNAVAILABLE",
                "error_kind": "unexpected_schema",
                "message": "Location search provider is temporarily unavailable.",
            }

        results = []
        for item in data:
            if len(results) >= result_limit:
                break
            parsed = parse_geocode_result(item)
            if parsed is not None:
                results.append(parsed)

        result = {
            "ok": True,
            "provider": "nominatim",
            "cached": False,
            "results": results,
            "message": "" if results else "No locations found. Try a city, place name, or full address.",
        }
        if not write_cache(cache_path, result):
            logger.warning("GEOCODING_CACHE_WRITE_FAILED path=%s", cache_path)
        return result


def parse_geocode_result(item: Any) -> dict | None:
    if not isinstance(item, dict):
        return None
    try:
        lat = float(item["lat"])
        lon = float(item["lon"])
    except (KeyError, TypeError, ValueError):
        return None
    if not -90 <= lat <= 90 or not -180 <= lon <= 180:
        return None

    display_name = str(item.get("display_name") or "").strip()
    if not display_name:
        return None

    result: dict[str, Any] = {
        "display_name": display_name,
        "lat": lat,
        "lon": lon,
        "primary_label": primary_label(item, display_name),
        "secondary_label": secondary_label(item, display_name),
        "provider": "nominatim",
    }

    for key in ("place_id", "osm_type", "osm_id", "class", "type"):
        if item.get(key) is not None:
            result[key] = item[key]

    bbox = item.get("boundingbox")
    if isinstance(bbox, list) and len(bbox) == 4:
        result["boundingbox"] = [str(value) for value in bbox]

    address = item.get("address")
    if isinstance(address, dict):
        result["address"] = {str(k): str(v) for k, v in address.items() if v is not None}

    return result


def primary_label(item: dict, display_name: str) -> str:
    address = item.get("address")
    if isinstance(address, dict):
        for key in ("amenity", "building", "tourism", "leisure", "aeroway", "shop", "office", "road", "neighbourhood", "suburb", "city", "town", "village", "county", "state", "country"):
            value = address.get(key)
            if value:
                return str(value)
    return display_name.split(",", 1)[0].strip() or display_name


def secondary_label(item: dict, display_name: str) -> str:
    primary = primary_label(item, display_name)
    parts = [part.strip() for part in display_name.split(",") if part.strip()]
    if parts and parts[0] == primary:
        parts = parts[1:]
    return ", ".join(parts[:4])


def normalize_query(query: str) -> str:
    return re.sub(r"\s+", " ", query.strip()).lower()


def cache_key(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


def read_cache(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def write_cache(path: Path, data: dict) -> bool:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        normalize_cache_ownership(path)
        return True
    except OSError:
        return False


def normalize_cache_ownership(path: Path) -> None:
    """Keep sudo-launched cache writes owned by the repository owner."""
    if os.geteuid() != 0:
        return
    try:
        owner = Path(__file__).resolve().parent.stat()
        for item in (path.parent, path):
            os.chown(item, owner.st_uid, owner.st_gid)
    except OSError:
        logger.warning("GEOCODING_CACHE_OWNERSHIP_NORMALIZE_FAILED path=%s", path)


def _headers() -> dict[str, str]:
    return {
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        "Accept-Language": "en-US,en;q=0.9",
    }


def _verified_ssl_context() -> ssl.SSLContext:
    return ssl.create_default_context(cafile=certifi.where())


def _http_get_json(url: str, headers: dict[str, str], timeout_s: float) -> Any:
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout_s, context=_verified_ssl_context()) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            body = response.read().decode(charset)
            return json.loads(body)
    except urllib.error.HTTPError as exc:
        body = _http_error_body(exc)
        if exc.code == 429:
            raise ProviderError(
                "Location search provider is rate limiting requests. Wait before retrying.",
                kind="rate_limited",
                status=exc.code,
                detail=body,
            ) from exc
        raise ProviderError(
            "Location search provider is temporarily unavailable.",
            kind="http_error",
            status=exc.code,
            detail=body or exc.reason,
        ) from exc
    except urllib.error.URLError as exc:
        kind = _url_error_kind(exc.reason)
        raise ProviderError(
            "Location search provider is temporarily unavailable.",
            kind=kind,
            detail=str(exc.reason),
        ) from exc
    except (TimeoutError, socket.timeout) as exc:
        raise ProviderError(
            "Location search provider is temporarily unavailable.",
            kind="timeout",
            detail=str(exc),
        ) from exc
    except json.JSONDecodeError as exc:
        raise ProviderError(
            "Location search provider is temporarily unavailable.",
            kind="json_error",
            detail=str(exc),
        ) from exc


def _url_error_kind(reason: Any) -> str:
    if isinstance(reason, ssl.SSLCertVerificationError):
        return "tls_error"
    if isinstance(reason, TimeoutError) or isinstance(reason, socket.timeout):
        return "timeout"
    if isinstance(reason, socket.gaierror):
        return "dns_error"
    return "network_error"


def _http_error_body(exc: urllib.error.HTTPError) -> str:
    try:
        body = exc.read().decode("utf-8", errors="replace")
    except Exception:
        body = ""
    return " ".join(body.strip().split())[:500]
