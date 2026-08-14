"""
drive_controller.py - Deterministic Drive Mode state machine.

The controller emits a sequence of static location writes over time. It does
not know about pymobiledevice3; callers inject writer functions so route math
and state transitions can be tested without an iPhone.
"""
from __future__ import annotations

import math
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Callable, Literal, Optional


DriveState = Literal["idle", "starting", "driving", "paused", "arrived", "stopped", "error"]


@dataclass(frozen=True)
class LatLon:
    lat: float
    lon: float


@dataclass
class DriveSession:
    id: str
    state: DriveState
    route: list[LatLon]
    speed_mps: float
    tick_s: float
    total_distance_m: float
    elapsed_drive_s: float = 0.0
    current_location: Optional[LatLon] = None
    stay_at_end: bool = True
    message: str = ""
    started_at: float = field(default_factory=time.time)


LocationWriter = Callable[[float, float], dict]
ClearWriter = Callable[[], dict]


class DriveController:
    """Owns one active drive session and its worker thread."""

    def __init__(self, location_writer: LocationWriter, clear_writer: ClearWriter) -> None:
        self._write_location = location_writer
        self._clear_location = clear_writer
        self._lock = threading.RLock()
        self._stop_event = threading.Event()
        self._worker: Optional[threading.Thread] = None
        self._session: Optional[DriveSession] = None

    def start(
        self,
        waypoints: list[dict],
        speed_mps: float,
        tick_s: float = 2.0,
        stay_at_end: bool = True,
    ) -> dict:
        route = [LatLon(float(wp["lat"]), float(wp["lon"])) for wp in waypoints]
        if len(route) < 2:
            return {"ok": False, "message": "Need at least 2 waypoints"}
        if speed_mps <= 0:
            return {"ok": False, "message": "speed_mps must be positive"}
        if tick_s < 1.0:
            return {"ok": False, "message": "tick_s must be at least 1 second"}

        total_distance = route_distance_m(route)
        if total_distance <= 0:
            return {"ok": False, "message": "Route distance must be greater than zero"}

        self.stop(clear_location=False, wait=True)

        session = DriveSession(
            id=f"drive_{uuid.uuid4().hex[:10]}",
            state="starting",
            route=route,
            speed_mps=speed_mps,
            tick_s=tick_s,
            total_distance_m=total_distance,
            current_location=route[0],
            stay_at_end=stay_at_end,
            message="Starting drive",
        )

        with self._lock:
            self._session = session
            self._stop_event.clear()
            self._worker = threading.Thread(target=self._run, args=(session.id,), daemon=True)
            self._worker.start()

        return self.status()

    def pause(self) -> dict:
        with self._lock:
            if not self._session or self._session.state in {"idle", "stopped"}:
                return {"ok": False, "message": "No active drive"}
            if self._session.state != "driving":
                return self.status()
            self._session.state = "paused"
            self._session.message = "Drive paused"
        return self.status()

    def resume(self) -> dict:
        with self._lock:
            if not self._session or self._session.state in {"idle", "stopped"}:
                return {"ok": False, "message": "No active drive"}
            if self._session.state != "paused":
                return self.status()
            self._session.state = "driving"
            self._session.message = "Drive resumed"
        return self.status()

    def stop(self, clear_location: bool = False, wait: bool = True) -> dict:
        worker: Optional[threading.Thread]
        with self._lock:
            session = self._session
            worker = self._worker
            if not session:
                if clear_location:
                    return self._clear_location()
                return self.status()
            if session.state not in {"arrived", "error"}:
                session.state = "stopped"
                session.message = "Drive stopped"
            self._stop_event.set()

        if wait and worker and worker.is_alive() and worker is not threading.current_thread():
            worker.join(timeout=10)

        if clear_location:
            return self._clear_location()
        return self.status()

    def status(self) -> dict:
        with self._lock:
            session = self._session
            if not session:
                return {
                    "ok": True,
                    "session_id": None,
                    "state": "idle",
                    "current_location": None,
                    "speed_mps": None,
                    "elapsed_s": 0.0,
                    "eta_s": None,
                    "progress": 0.0,
                    "total_distance_m": 0.0,
                    "distance_remaining_m": 0.0,
                    "stay_at_end": True,
                    "message": "",
                }
            return _session_status(session)

    def _run(self, session_id: str) -> None:
        last_progress_at: Optional[float] = None
        next_emit_at = 0.0

        while not self._stop_event.is_set():
            now = time.monotonic()
            with self._lock:
                session = self._session
                if not session or session.id != session_id:
                    return

                if session.state == "starting":
                    session.state = "driving"
                    session.message = "Drive in progress"
                    last_progress_at = now

                if session.state == "paused":
                    last_progress_at = None
                    should_emit = False
                    coord = session.current_location
                elif session.state == "driving":
                    if last_progress_at is None:
                        last_progress_at = now
                    session.elapsed_drive_s += max(0.0, now - last_progress_at)
                    last_progress_at = now
                    distance = min(session.total_distance_m, session.elapsed_drive_s * session.speed_mps)
                    coord = interpolate_route(session.route, distance)
                    session.current_location = coord
                    should_emit = now >= next_emit_at
                else:
                    return

            if should_emit and coord:
                result = self._write_location(coord.lat, coord.lon)
                if not result.get("ok"):
                    with self._lock:
                        session = self._session
                        if session and session.id == session_id:
                            session.state = "error"
                            session.message = result.get("message", "Location write failed")
                    return
                with self._lock:
                    tick_s = self._session.tick_s if self._session and self._session.id == session_id else 2.0
                next_emit_at = time.monotonic() + max(1.0, tick_s)

            with self._lock:
                session = self._session
                if not session or session.id != session_id:
                    return
                arrived = session.elapsed_drive_s * session.speed_mps >= session.total_distance_m
                final_coord = session.route[-1]

            if arrived:
                result = self._write_location(final_coord.lat, final_coord.lon)
                clear_at_end = False
                with self._lock:
                    session = self._session
                    if not session or session.id != session_id:
                        return
                    session.current_location = final_coord
                    session.elapsed_drive_s = session.total_distance_m / session.speed_mps
                    clear_at_end = not session.stay_at_end
                    if result.get("ok"):
                        session.state = "arrived" if session.stay_at_end else "stopped"
                        session.message = "Arrived at destination"
                    else:
                        session.state = "error"
                        session.message = result.get("message", "Final location write failed")
                if result.get("ok") and clear_at_end:
                    self._clear_location()
                return

            time.sleep(0.2)


def _session_status(session: DriveSession) -> dict:
    distance_traveled = min(session.total_distance_m, session.elapsed_drive_s * session.speed_mps)
    remaining = max(0.0, session.total_distance_m - distance_traveled)
    eta_s = remaining / session.speed_mps if session.speed_mps > 0 else None
    progress = distance_traveled / session.total_distance_m if session.total_distance_m > 0 else 0.0
    return {
        "ok": True,
        "session_id": session.id,
        "state": session.state,
        "current_location": (
            {"lat": session.current_location.lat, "lon": session.current_location.lon}
            if session.current_location
            else None
        ),
        "speed_mps": session.speed_mps,
        "elapsed_s": round(session.elapsed_drive_s, 3),
        "eta_s": round(eta_s, 3) if eta_s is not None else None,
        "progress": round(max(0.0, min(1.0, progress)), 4),
        "total_distance_m": round(session.total_distance_m, 3),
        "distance_remaining_m": round(remaining, 3),
        "stay_at_end": session.stay_at_end,
        "message": session.message,
    }


def route_distance_m(route: list[LatLon]) -> float:
    return sum(haversine_m(a, b) for a, b in zip(route, route[1:]))


def interpolate_route(route: list[LatLon], distance_m: float) -> LatLon:
    if distance_m <= 0:
        return route[0]

    remaining = distance_m
    for start, end in zip(route, route[1:]):
        segment_m = haversine_m(start, end)
        if segment_m <= 0:
            continue
        if remaining <= segment_m:
            fraction = remaining / segment_m
            return LatLon(
                lat=start.lat + (end.lat - start.lat) * fraction,
                lon=start.lon + (end.lon - start.lon) * fraction,
            )
        remaining -= segment_m
    return route[-1]


def haversine_m(a: LatLon, b: LatLon) -> float:
    radius_m = 6371000.0
    lat1 = math.radians(a.lat)
    lat2 = math.radians(b.lat)
    dlat = math.radians(b.lat - a.lat)
    dlon = math.radians(b.lon - a.lon)
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * radius_m * math.asin(math.sqrt(h))
