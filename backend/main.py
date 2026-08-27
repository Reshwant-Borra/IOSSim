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
import threading

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

from device_manager import DeviceManager
from drive_controller import DriveController
from drive_routing import DriveRoutingClient
from drive_testing.experiment_controller import DriveExperimentController
from drive_testing.experiment_queue import ExperimentQueueController
from drive_testing.experiment_store import ExperimentStore
from drive_testing.flags import drive_testing_enabled as _drive_testing_enabled
from drive_testing.router import build_router as build_drive_testing_router
from favorites import add_favorite, delete_favorite, list_favorites
from location_service import LocationService
from wireless_testing.controller import WirelessTestingController
from wireless_testing.experiment_store import WirelessExperimentStore as WirelessTestingStore
from wireless_testing.router import build_router as build_wireless_testing_router
from wireless_location.controller import WirelessLocationController
from wireless_location.router import build_router as build_wireless_location_router

app = FastAPI(title="iOS Location Sim", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_methods=["*"],
    allow_headers=["*"],
)

manager = DeviceManager()
svc = LocationService(manager)
drive = DriveController(svc.set_location, svc.clear_location)
drive_routing = DriveRoutingClient()
location_search = drive_routing.geocoder
location_operation_lock = threading.RLock()
drive_testing_store = ExperimentStore()
drive_testing = DriveExperimentController(
    svc.set_location,
    svc.clear_location,
    drive_testing_store,
    manager.status,
    drive.status,
    gpx_starter=svc.start_gpx_playback,
    gpx_canceller=svc.cancel_gpx_playback,
    operation_lock=location_operation_lock,
)
drive_testing_queue = ExperimentQueueController(drive_testing)
wireless_testing_store = WirelessTestingStore()
wireless_testing = WirelessTestingController(
    manager.status,
    svc.set_location,
    svc.clear_location,
    drive.status,
    drive_testing.is_location_operation_active,
    wireless_testing_store,
    operation_lock=location_operation_lock,
)
wireless_location = WirelessLocationController(
    stable_status_provider=manager.status,
    operation_lock=location_operation_lock,
)


def experimental_enabled() -> bool:
    return os.getenv("IOS_SIM_ENABLE_EXPERIMENTAL", "").lower() in {"1", "true", "yes", "on"}


def drive_testing_enabled() -> bool:
    """Dedicated Drive Testing gate; generic experimental mode alone is insufficient."""
    return _drive_testing_enabled()


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
    connection_mode: str | None = Field(default=None, pattern="^(automatic|usb|wireless)$")
    device_udid: str | None = None


class RouteBody(BaseModel):
    waypoints: list[LocationBody] = Field(..., min_length=2)
    speed_mps: float = Field(1.4, ge=0.1, le=50.0)


class DriveStartBody(BaseModel):
    waypoints: list[LocationBody] = Field(..., min_length=2)
    speed_mps: float = Field(8.3, ge=0.5, le=35.0)
    tick_s: float = Field(2.0, ge=1.0, le=10.0)
    stay_at_end: bool = True


class DriveGeocodeBody(BaseModel):
    address: str = Field(..., min_length=1, max_length=300)


class LocationSearchBody(BaseModel):
    query: str = Field(..., min_length=1, max_length=300)
    limit: int = Field(5, ge=1, le=5)


class DriveRouteBody(BaseModel):
    start: LocationBody
    destination: LocationBody


class RoadRouteStartBody(BaseModel):
    coordinates: list[LocationBody] = Field(..., min_length=2)
    speed_mps: float = Field(8.3, ge=0.5, le=35.0)
    tick_s: float = Field(2.0, ge=1.0, le=10.0)
    stay_at_end: bool = True


class DriveStopBody(BaseModel):
    clear_location: bool = False


class FavoriteBody(BaseModel):
    name: str = Field(..., min_length=1, max_length=80)
    lat: float = Field(..., ge=-90, le=90)
    lon: float = Field(..., ge=-180, le=180)
    note: str = ""


# â”€â”€ status â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

@app.get("/api/status")
def status() -> dict:
    stable = manager.status()
    return {
        **stable,
        "wireless_location": wireless_location.status(refresh=True),
    }


@app.on_event("startup")
def startup_wireless_discovery() -> None:
    try:
        wireless_location.refresh_saved_devices()
    except Exception:
        logging.exception("Wireless saved-device discovery failed during startup")


@app.on_event("shutdown")
def shutdown_wireless_session() -> None:
    try:
        wireless_location.disconnect_wireless()
    except Exception:
        logging.exception("Wireless session cleanup failed during shutdown")


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
    if drive_testing.is_location_operation_active():
        return JSONResponse(
            status_code=409,
            content={"ok": False, "code": "drive_testing_conflict", "message": "Stop Drive Testing before setting a static location."},
        )
    drive.stop(clear_location=False)
    if wireless_location.should_use_wireless(body.connection_mode, body.device_udid):
        result = wireless_location.set_location(body.lat, body.lon, udid=body.device_udid)
    else:
        result = svc.set_location(body.lat, body.lon)
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/clear")
def clear_location():
    active_experiment = drive_testing.active_experiment_id()
    if active_experiment:
        drive_testing.stop(active_experiment, reset_gps=False)
    drive.stop(clear_location=False)
    wireless_state = wireless_location.session_status()
    if wireless_state.get("simulation_enabled"):
        result = wireless_location.clear_location()
    else:
        result = svc.clear_location()
        if not result.get("ok") and result.get("message") == "No device connected":
            return {"ok": True, "message": "GPS is already using the real location."}
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/route")
def play_route(body: RouteBody):
    if not experimental_enabled():
        return experimental_disabled("Route playback")
    if drive_testing.is_location_operation_active():
        return JSONResponse(status_code=409, content={"ok": False, "code": "drive_testing_conflict", "message": "Stop Drive Testing before legacy route playback."})
    wps = [{"lat": w.lat, "lon": w.lon} for w in body.waypoints]
    result = svc.play_route(wps, speed_mps=body.speed_mps)
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/drive/start")
def drive_start(body: DriveStartBody):
    with location_operation_lock:
        if drive_testing.is_location_operation_active():
            return JSONResponse(status_code=409, content={"ok": False, "code": "drive_testing_conflict", "message": "Stop Drive Testing before starting stable Drive Mode."})
        wps = [{"lat": w.lat, "lon": w.lon} for w in body.waypoints]
        result = drive.start(
            wps,
            speed_mps=body.speed_mps,
            tick_s=body.tick_s,
            stay_at_end=body.stay_at_end,
        )
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/drive/geocode")
def drive_geocode(body: DriveGeocodeBody):
    result = drive_routing.geocode(body.address)
    if not result["ok"]:
        return JSONResponse(status_code=502, content=result)
    return result


@app.post("/api/location/search")
def search_location(body: LocationSearchBody):
    result = location_search.search(body.query, limit=body.limit)
    if not result["ok"]:
        if "Enter a place" in result.get("message", ""):
            return JSONResponse(status_code=400, content=result)
        return JSONResponse(
            status_code=502,
            content={
                "ok": False,
                "provider": result.get("provider", "nominatim"),
                "cached": False,
                "results": [],
                "detail": {
                    "message": "Location search provider is temporarily unavailable.",
                    "code": result.get("code", "GEOCODING_PROVIDER_UNAVAILABLE"),
                },
            },
        )
    return result


@app.post("/api/location/drive/route")
def drive_route(body: DriveRouteBody):
    result = drive_routing.route(
        {"lat": body.start.lat, "lon": body.start.lon},
        {"lat": body.destination.lat, "lon": body.destination.lon},
    )
    if not result["ok"]:
        return JSONResponse(status_code=502, content=result)
    return result


@app.post("/api/location/drive/start-road-route")
def drive_start_road_route(body: RoadRouteStartBody):
    with location_operation_lock:
        if drive_testing.is_location_operation_active():
            return JSONResponse(status_code=409, content={"ok": False, "code": "drive_testing_conflict", "message": "Stop Drive Testing before starting stable Drive Mode."})
        coordinates = [{"lat": coord.lat, "lon": coord.lon} for coord in body.coordinates]
        result = drive.start(
            coordinates,
            speed_mps=body.speed_mps,
            tick_s=body.tick_s,
            stay_at_end=body.stay_at_end,
        )
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/drive/pause")
def drive_pause():
    result = drive.pause()
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/drive/resume")
def drive_resume():
    result = drive.resume()
    if not result["ok"]:
        return _location_error(result)
    return result


@app.post("/api/location/drive/stop")
def drive_stop(body: DriveStopBody | None = None):
    result = drive.stop(clear_location=body.clear_location if body else False)
    if not result["ok"]:
        return _location_error(result)
    return result


@app.get("/api/location/drive/status")
def drive_status():
    return drive.status()


app.include_router(
    build_drive_testing_router(
        drive_testing,
        drive_testing_queue,
        manager.status,
        drive.status,
    )
)
app.include_router(build_wireless_testing_router(wireless_testing))
app.include_router(build_wireless_location_router(wireless_location))


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
