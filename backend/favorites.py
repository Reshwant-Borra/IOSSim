"""
favorites.py — Persist named locations to a local JSON file.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

FAVORITES_FILE = Path(__file__).parent / "data" / "favorites.json"


def _load() -> list[dict]:
    FAVORITES_FILE.parent.mkdir(exist_ok=True)
    if not FAVORITES_FILE.exists():
        return []
    try:
        return json.loads(FAVORITES_FILE.read_text())
    except Exception:
        return []


def _save(favorites: list[dict]) -> None:
    FAVORITES_FILE.parent.mkdir(exist_ok=True)
    FAVORITES_FILE.write_text(json.dumps(favorites, indent=2))


def list_favorites() -> list[dict]:
    return _load()


def add_favorite(name: str, lat: float, lon: float, note: str = "") -> dict:
    favorites = _load()
    entry = {"id": _next_id(favorites), "name": name, "lat": lat, "lon": lon, "note": note}
    favorites.append(entry)
    _save(favorites)
    return entry


def delete_favorite(fav_id: int) -> bool:
    favorites = _load()
    new = [f for f in favorites if f.get("id") != fav_id]
    if len(new) == len(favorites):
        return False
    _save(new)
    return True


def _next_id(favorites: list[dict]) -> int:
    if not favorites:
        return 1
    return max(f.get("id", 0) for f in favorites) + 1
