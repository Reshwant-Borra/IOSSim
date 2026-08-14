from __future__ import annotations

import math
import random
from typing import Any

from drive_controller import haversine_m, route_distance_m

from .route_sampler import coordinate_at_distance, route_as_dicts, to_latlon_list, truncate_route


MPS_PER_MPH = 0.44704
METERS_PER_MILE = 1609.344


def mph_to_mps(mph: float) -> float:
    return float(mph) * MPS_PER_MPH


def mps_to_mph(mps: float) -> float:
    return float(mps) / MPS_PER_MPH


def profile_presets() -> list[dict[str, Any]]:
    presets: list[dict[str, Any]] = [
        _preset("STATIONARY", "Stationary coordinate baseline", "stationary", 0, 0.4),
        _preset("STABLE-BASELINE", "Existing stable Drive Mode baseline", "constant", 20, 0.6, method="stable_baseline"),
        _preset("LEGACY-GPX", "Legacy GPX baseline", "constant", 20, 0.6, method="legacy_gpx"),
        _preset("TIMESTAMPED-GPX", "Timestamped GPX baseline", "constant", 20, 0.6, method="timestamped_gpx"),
    ]
    for mph in (3, 10, 14, 15, 16, 20, 25, 35, 45, 60):
        presets.append(_preset(f"SPEED-{mph}", f"Constant {mph} mph", "constant", mph, 0.6))
    presets.extend(
        [
            _preset("ACCEL-16", "0 to 16 mph over 10 seconds", "acceleration", 16, 0.6, transition_s=10),
            _preset("ACCEL-20", "0 to 20 mph over 15 seconds", "acceleration", 20, 0.6, transition_s=15),
            _preset("ACCEL-25", "0 to 25 mph over 20 seconds", "acceleration", 25, 1.0, transition_s=20),
            _preset("ACCEL-35", "0 to 35 mph over 25 seconds", "acceleration", 35, 1.0, transition_s=25),
            _preset("DECEL-25", "25 to 0 mph over 15 seconds", "deceleration", 25, 0.6, transition_s=15),
            _preset("DECEL-35", "35 to 0 mph over 20 seconds", "deceleration", 35, 0.6, transition_s=20),
            _preset("PROFILE-CITY", "City profile", "city", 25, 1.0),
            _preset("PROFILE-SUBURBAN", "Suburban profile", "suburban", 35, 1.0),
            _preset("PROFILE-HIGHWAY", "Highway profile", "highway", 60, 2.0),
            _preset("NEG-JUMP", "Negative control - instant coordinate jumps", "instant_jumps", 200, 1.0, negative=True),
            _preset("NEG-IMPOSSIBLE", "Negative control - impossible apparent speed", "impossible_speed", 500, 2.0, negative=True),
            _preset("NEG-DUPLICATE", "Negative control - repeated identical points", "repeated_points", 20, 0.6, negative=True),
            _preset("NEG-IRREGULAR", "Negative control - highly irregular timing", "irregular_timing", 20, 0.6, negative=True),
        ]
    )
    return presets


def test_matrix_templates() -> dict[str, list[dict[str, Any]]]:
    speeds = [_preset(f"SPEED-{mph}", f"{mph} mph, 0.6 mile", "constant", mph, 0.6) for mph in (14, 15, 16, 20, 25)]
    distances = [_preset(code, f"20 mph, {miles} mile", "constant", 20, miles) for code, miles in (("DIST-04", 0.4), ("DIST-05", 0.5), ("DIST-06", 0.6), ("DIST-10", 1.0))]
    timing = [{**_preset(f"TICK-{tick}", f"{tick}-second interval", "constant", 20, 0.6), "update_interval_s": float(tick)} for tick in (1, 2, 3, 5)]
    methods = [
        _preset("METHOD-STATIC", "Timed static DVT updates", "constant", 20, 0.6, method="timed_static"),
        _preset("METHOD-LEGACY-GPX", "Coordinate-only GPX", "constant", 20, 0.6, method="legacy_gpx"),
        _preset("METHOD-TIMED-GPX", "Timestamped GPX", "constant", 20, 0.6, method="timestamped_gpx"),
        _preset("METHOD-STABLE-BASELINE", "Drive Mode-equivalent", "constant", 20, 0.6, method="stable_baseline"),
    ]
    profiles = [item for item in profile_presets() if item["id"] in {"SPEED-20", "ACCEL-20", "PROFILE-CITY", "PROFILE-SUBURBAN", "PROFILE-HIGHWAY", "NEG-JUMP"}]
    return {"speed_series": speeds, "distance_series": distances, "timing_series": timing, "method_series": methods, "profile_series": profiles}


def _preset(identifier: str, name: str, kind: str, mph: float, miles: float, method: str = "timed_static", transition_s: float | None = None, negative: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": identifier,
        "name": name,
        "kind": kind,
        "method": method,
        "target_speed_mph": mph,
        "distance_miles": miles,
        "update_interval_s": 1.0,
        "timing_variation_s": 0.0,
        "random_seed": 1,
        "negative_control": negative,
    }
    if transition_s is not None:
        result["transition_s"] = transition_s
    return result


def generate_profile(coordinates: list[dict], settings: dict[str, Any]) -> dict[str, Any]:
    route = to_latlon_list(coordinates)
    if len(route) < 2:
        raise ValueError("Route must contain at least two coordinates")
    route_total = route_distance_m(route)
    requested_distance_m = float(settings.get("distance_m", float(settings.get("distance_miles", 0.6)) * METERS_PER_MILE))
    if requested_distance_m <= 0:
        raise ValueError("Requested distance must be positive")
    if route_total + 0.01 < requested_distance_m:
        raise ValueError(f"Route is {route_total:.1f} m but profile requests {requested_distance_m:.1f} m")

    interval = float(settings.get("update_interval_s", 1.0))
    if not 1.0 <= interval <= 30.0:
        raise ValueError("Update interval must be between 1 and 30 seconds")
    variation = min(max(float(settings.get("timing_variation_s", 0.0)), 0.0), interval * 0.45)
    seed = int(settings.get("random_seed", 1))
    rng = random.Random(seed)
    kind = str(settings.get("kind", "constant"))
    if kind == "irregular_timing" and variation == 0.0:
        variation = interval * 0.45
    target_mph = float(settings.get("target_speed_mph", 20.0))
    target_mps = mph_to_mps(target_mph)
    if target_mps < 0:
        raise ValueError("Target speed cannot be negative")

    used_route = truncate_route(route, requested_distance_m)
    samples: list[dict[str, Any]] = []
    elapsed = 0.0
    distance = 0.0
    previous = used_route[0]
    samples.append(_sample(0, previous.lat, previous.lon, 0.0, 0.0, 0.0, 0.0, _phase(kind, 0.0, 0.0, requested_distance_m, settings)))

    max_samples = 10000
    while distance < requested_distance_m - 0.001 and len(samples) < max_samples:
        planned_interval = interval + (rng.uniform(-variation, variation) if variation else 0.0)
        speed_mps, phase = _speed_for(kind, elapsed, distance, requested_distance_m, target_mps, settings, rng)
        if kind == "stationary":
            if len(samples) >= int(settings.get("stationary_samples", 10)):
                break
            step = 0.0
        else:
            speed_mps = max(speed_mps, 0.0)
            step = speed_mps * planned_interval
            if step <= 0.001 and phase != "stopped":
                step = min(0.05, requested_distance_m - distance)
            if step > requested_distance_m - distance:
                step = requested_distance_m - distance
                planned_interval = step / speed_mps if speed_mps > 0 else planned_interval

        elapsed += planned_interval
        distance += step
        point = coordinate_at_distance(used_route, distance)
        segment = haversine_m(previous, point)
        samples.append(_sample(len(samples), point.lat, point.lon, elapsed, planned_interval, speed_mps, segment, phase, distance))
        previous = point

    if len(samples) >= max_samples:
        raise ValueError("Profile generation exceeded the safe sample limit")
    if kind != "stationary" and distance < requested_distance_m - 0.01:
        raise ValueError("Profile could not reach the requested distance")
    if samples:
        samples[-1]["phase"] = "completed"

    generated_distance = sum(float(sample["segment_distance_m"]) for sample in samples)
    difference = generated_distance - requested_distance_m
    planned_duration = samples[-1]["planned_elapsed_s"] if samples else 0.0
    return {
        "schema_version": "1.0",
        "name": str(settings.get("name") or f"{kind.replace('_', ' ').title()} profile"),
        "kind": kind,
        "method": settings.get("method", "timed_static"),
        "negative_control": bool(settings.get("negative_control", kind in {"instant_jumps", "impossible_speed", "repeated_points", "irregular_timing"})),
        "random_seed": seed,
        "requested_distance_m": requested_distance_m,
        "generated_distance_m": generated_distance,
        "distance_difference_m": difference,
        "distance_error_percent": (difference / requested_distance_m * 100.0) if requested_distance_m else 0.0,
        "planned_duration_s": planned_duration,
        "planned_average_apparent_speed_mps": generated_distance / planned_duration if planned_duration else 0.0,
        "target_apparent_speed_mph": target_mph,
        "target_apparent_speed_mps": target_mps,
        "update_interval_s": interval,
        "timing_variation_s": variation,
        "route": route_as_dicts(used_route),
        "samples": samples,
    }


def _sample(sequence: int, lat: float, lon: float, elapsed: float, interval: float, speed_mps: float, segment: float, phase: str, cumulative: float = 0.0) -> dict[str, Any]:
    return {
        "sequence": sequence,
        "latitude": lat,
        "longitude": lon,
        "planned_elapsed_s": round(elapsed, 6),
        "planned_interval_s": round(interval, 6),
        "target_apparent_speed_mps": round(speed_mps, 6),
        "target_apparent_speed_mph": round(mps_to_mph(speed_mps), 6),
        "segment_distance_m": round(segment, 6),
        "cumulative_distance_m": round(cumulative, 6),
        "phase": phase,
    }


def _phase(kind: str, elapsed: float, distance: float, total: float, settings: dict[str, Any]) -> str:
    if kind == "stationary":
        return "stationary"
    if kind == "acceleration" or (kind in {"city", "suburban", "highway"} and elapsed < float(settings.get("transition_s", 15))):
        return "accelerating"
    if kind == "deceleration":
        return "decelerating"
    return "cruising"


def _speed_for(kind: str, elapsed: float, distance: float, total: float, target: float, settings: dict[str, Any], rng: random.Random) -> tuple[float, str]:
    transition = max(1.0, float(settings.get("transition_s", 15.0)))
    remaining = total - distance
    if kind == "stationary":
        return 0.0, "stationary"
    if kind == "acceleration":
        return max(0.2, target * min(1.0, elapsed / transition)), "accelerating" if elapsed < transition else "cruising"
    if kind == "deceleration":
        stopping_distance = max(1.0, 0.5 * target * transition)
        if remaining > stopping_distance:
            return target, "cruising"
        return max(0.2, target * math.sqrt(max(0.0, remaining / stopping_distance))), "decelerating"
    if kind == "city":
        cycle = elapsed % 60.0
        if 35 <= cycle < 43:
            return 0.0, "stopped"
        if cycle < 10 or 43 <= cycle < 53:
            basis = cycle if cycle < 10 else cycle - 43
            return max(0.3, target * basis / 10.0), "accelerating"
        if remaining < max(30.0, target * 10):
            return max(0.3, target * math.sqrt(remaining / max(30.0, target * 10))), "decelerating"
        return target * rng.uniform(0.82, 1.05), "cruising"
    if kind == "suburban":
        cycle = elapsed % 100.0
        if 70 <= cycle < 75:
            return 0.0, "stopped"
        if cycle < 15 or 75 <= cycle < 90:
            basis = cycle if cycle < 15 else cycle - 75
            return max(0.3, target * basis / 15.0), "accelerating"
        return target * rng.uniform(0.85, 1.08), "cruising"
    if kind == "highway":
        if elapsed < 25:
            return max(0.5, target * elapsed / 25.0), "accelerating"
        if remaining < max(100.0, target * 20):
            return max(0.5, target * math.sqrt(remaining / max(100.0, target * 20))), "decelerating"
        return target * rng.uniform(0.96, 1.04), "cruising"
    if kind == "instant_jumps":
        return max(target, mph_to_mps(200)), "cruising"
    if kind == "impossible_speed":
        return max(target, mph_to_mps(500)), "cruising"
    if kind == "repeated_points":
        if int(elapsed) % 6 < 4:
            return 0.0, "stopped"
        return target * 3, "cruising"
    if kind == "irregular_timing":
        return target * rng.uniform(0.4, 2.5), "cruising"
    return target, _phase(kind, elapsed, distance, total, settings)
