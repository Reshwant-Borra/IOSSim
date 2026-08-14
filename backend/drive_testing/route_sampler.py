from __future__ import annotations

from typing import Iterable

from drive_controller import LatLon, haversine_m, interpolate_route, route_distance_m


def to_latlon_list(coordinates: Iterable[dict | LatLon]) -> list[LatLon]:
    route: list[LatLon] = []
    for value in coordinates:
        if isinstance(value, LatLon):
            point = value
        else:
            point = LatLon(float(value["lat"]), float(value["lon"]))
        if not -90 <= point.lat <= 90 or not -180 <= point.lon <= 180:
            raise ValueError("Coordinates are outside valid latitude/longitude bounds")
        route.append(point)
    return route


def route_as_dicts(route: Iterable[LatLon]) -> list[dict[str, float]]:
    return [{"lat": point.lat, "lon": point.lon} for point in route]


def validate_route(coordinates: Iterable[dict | LatLon], minimum_distance_m: float = 0.0) -> dict:
    try:
        route = to_latlon_list(coordinates)
    except (KeyError, TypeError, ValueError) as exc:
        return {"ok": False, "message": str(exc), "distance_m": 0.0, "coordinate_count": 0}
    if len(route) < 2:
        return {"ok": False, "message": "Route must contain at least two coordinates", "distance_m": 0.0, "coordinate_count": len(route)}
    distance = route_distance_m(route)
    if distance <= 0:
        return {"ok": False, "message": "Route distance must be greater than zero", "distance_m": distance, "coordinate_count": len(route)}
    meets = distance + 0.01 >= minimum_distance_m
    return {
        "ok": meets,
        "message": "" if meets else f"Route is shorter than the requested {minimum_distance_m:.1f} meters",
        "distance_m": distance,
        "coordinate_count": len(route),
        "meets_minimum_distance": meets,
    }


def truncate_route(coordinates: Iterable[dict | LatLon], requested_distance_m: float) -> list[LatLon]:
    route = to_latlon_list(coordinates)
    if len(route) < 2:
        raise ValueError("Route must contain at least two coordinates")
    if requested_distance_m <= 0:
        raise ValueError("Requested distance must be positive")

    total = route_distance_m(route)
    if requested_distance_m >= total:
        return list(route)

    result = [route[0]]
    traversed = 0.0
    for start, end in zip(route, route[1:]):
        segment = haversine_m(start, end)
        if segment <= 0:
            continue
        if traversed + segment < requested_distance_m:
            result.append(end)
            traversed += segment
            continue
        remaining = requested_distance_m - traversed
        final = LatLon(
            start.lat + (end.lat - start.lat) * (remaining / segment),
            start.lon + (end.lon - start.lon) * (remaining / segment),
        )
        if haversine_m(result[-1], final) > 0.001:
            result.append(final)
        break
    return result


def coordinate_at_distance(coordinates: Iterable[dict | LatLon], distance_m: float) -> LatLon:
    route = to_latlon_list(coordinates)
    if not route:
        raise ValueError("Route is empty")
    return interpolate_route(route, max(0.0, distance_m))


def reverse_route(coordinates: Iterable[dict | LatLon]) -> list[dict[str, float]]:
    return route_as_dicts(reversed(to_latlon_list(coordinates)))
