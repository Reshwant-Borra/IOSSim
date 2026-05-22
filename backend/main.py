"""
main.py â€” FastAPI backend for iOS Location Sim.

Endpoints:
  GET  /api/status              â€” device + tunnel status
  POST /api/setup/mount-ddi     â€” mount developer disk image
  POST /api/setup/tunnel        â€” start tunneld (iOS 17+)
  DELETE /api/setup/tunnel      â€” stop tunnel
  POST /api/location/set        â€” set lat/lon
  POST /api/location/clear      â€” reset to real GPS
  POST /api/location/route      â€” play route from waypoints
  GET  /api/favorites           â€” list saved locations
  POST /api/favorites           â€” add favorite
  DELETE /api/favorites/{id}    â€” delete favorite

Run (from ios-location-sim/):
  cd backend
  uvicorn main:app --host 0.0.0.0 --port 8765 --reload
"""
from __future__ import annotations

import sys
from pathlib import Path

# allow running from backend/ or project root
sys.path.insert(0, str(Path(__file__).parent))

import logging
import os

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

from device_manager import DeviceManager
from favorites import add_favorite, delete_favorite, list_favorites
from location_service import LocationService

app = FastAPI(title="iOS Location Sim", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_methods=["*"],
    allow_headers=["*"],
)

manager = DeviceManager()
svc = LocationService(manager)


def experimental_enabled() -> bool:
    return os.getenv("IOS_SIM_ENABLE_EXPERIMENTAL", "").lower() in {"1", "true", "yes", "on"}


def experimental_disabled(feature: str) -> JSONResponse:
    return JSONResponse(
        status_code=403,
        content={
            "ok": False,
            "message": (
                f"{feature} is experimental and disabled in stable mode. "
                "Set IOS_SIM_ENABLE_EXPERIMENTAL=1 for test builds."
            ),
        },
    )


@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
    logging.exception("Unhandled error on %s", request.url.path)
    return JSONResponse(status_code=500, content={"ok": False, "message": str(exc)})


# â”€â”€ request / response models â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class LocationBody(BaseModel):
    lat: float = Field(..., ge=-90, le=90)
    lon: float = Field(..., ge=-180, le=180)


class RouteBody(BaseModel):
    waypoints: list[LocationBody] = Field(..., min_length=2)
    speed_mps: float = Field(1.4, ge=0.1, le=50.0)


class FavoriteBody(BaseModel):
    name: str = Field(..., min_length=1, max_length=80)
    lat: float = Field(..., ge=-90, le=90)
    lon: float = Field(..., ge=-180, le=180)
    note: str = ""


# â”€â”€ status â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

@app.get("/api/status")
def status() -> dict:
    return manager.status()


# â”€â”€ setup â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

@app.post("/api/setup/mount-ddi")
def mount_ddi() -> dict:
    result = manager.mount_ddi()
    if not result["ok"]:
        raise HTTPException(500, detail=result["message"])
    return result


@app.post("/api/setup/tunnel")
def start_tunnel() -> dict:
    result = manager.start_tunnel()
    if not result["ok"]:
        raise HTTPException(500, detail=result["message"])
    return result


@app.delete("/api/setup/tunnel")
def stop_tunnel() -> dict:
    manager.stop_tunnel()
    return {"ok": True}


# â”€â”€ location â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

def _location_error(result: dict) -> JSONResponse:
    return JSONResponse(
        status_code=500,
        content={
            "ok": False,
            "message": result.get("message", ""),
            "stdout": result.get("stdout", ""),
            "stderr": result.get("stderr", ""),
        },
    )


@app.post("/api/location/set")
def set_location(body: LocationBody):
    result = svc.set_location(body.lat, body.lon)
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/clear")
def clear_location():
    result = svc.clear_location()
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/route")
def play_route(body: RouteBody):
    if not experimental_enabled():
        return experimental_disabled("Route playback")
    wps = [{"lat": w.lat, "lon": w.lon} for w in body.waypoints]
    result = svc.play_route(wps, speed_mps=body.speed_mps)
    if not result["ok"]:
        return _location_error(result)
    return result


# â”€â”€ favorites â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

@app.get("/api/favorites")
def get_favorites() -> list:
    return list_favorites()


@app.post("/api/favorites")
def create_favorite(body: FavoriteBody) -> dict:
    return add_favorite(body.name, body.lat, body.lon, body.note)


@app.delete("/api/favorites/{fav_id}")
def remove_favorite(fav_id: int) -> dict:
    if not delete_favorite(fav_id):
        raise HTTPException(404, detail="Favorite not found")
    return {"ok": True}


# â”€â”€ serve built frontend (production) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

_dist = Path(__file__).parent.parent / "frontend" / "dist"
if _dist.exists():
    app.mount("/", StaticFiles(directory=str(_dist), html=True), name="static")

