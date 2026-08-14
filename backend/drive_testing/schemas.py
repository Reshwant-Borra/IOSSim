from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .models import OBSERVATION_RESULTS


class Coordinate(BaseModel):
    lat: float = Field(..., ge=-90, le=90)
    lon: float = Field(..., ge=-180, le=180)


class ProfileGenerateBody(BaseModel):
    coordinates: list[Coordinate] = Field(..., min_length=2)
    settings: dict[str, Any]


class RouteValidateBody(BaseModel):
    coordinates: list[Coordinate] = Field(..., min_length=2)
    minimum_distance_m: float = Field(0.0, ge=0)


class ExperimentCreateBody(BaseModel):
    route: list[Coordinate] = Field(..., min_length=2)
    profile_settings: dict[str, Any]
    route_config: dict[str, Any] = Field(default_factory=dict)
    reset_gps_at_end: bool = True
    repeats: int = Field(1, ge=1, le=100)


class ExperimentStartBody(BaseModel):
    confirm_authorized_use: bool = False


class ExperimentStopBody(BaseModel):
    reset_gps: bool = False


class ObservationBody(BaseModel):
    model_config = ConfigDict(extra="allow")

    result: str
    checked_at: str | None = None
    delay_before_result_s: float | None = Field(None, ge=0)
    displayed_distance: float | None = Field(None, ge=0)
    displayed_duration_s: float | None = Field(None, ge=0)
    displayed_average_speed_mph: float | None = Field(None, ge=0)
    displayed_maximum_speed_mph: float | None = Field(None, ge=0)
    drive_detection_enabled: bool | None = None
    arity_sharing_enabled: bool | None = None
    location_permission_always: bool | None = None
    motion_fitness_enabled: bool | None = None
    background_app_refresh_enabled: bool | None = None
    low_power_mode_disabled: bool | None = None
    battery_above_10_percent: bool | None = None
    strong_cellular_signal: bool | None = None
    connectivity: Literal["wifi", "cellular", "both", "unknown"] | None = None
    phone_state: Literal["stationary", "physically_moving", "unknown"] | None = None
    screen_state: Literal["locked", "unlocked", "unknown"] | None = None
    application_state: Literal["foreground", "background", "not_checked", "unknown"] | None = None
    test_performed_by_passenger: bool | None = None
    notes: str = Field("", max_length=10000)
    screenshot_filename: str | None = Field(None, max_length=260)
    interpretation: str = Field("", max_length=10000)

    @field_validator("result")
    @classmethod
    def validate_result(cls, value: str) -> str:
        normalized = value.strip().lower().replace(" ", "_")
        if normalized not in OBSERVATION_RESULTS:
            raise ValueError(f"Result must be one of: {', '.join(sorted(OBSERVATION_RESULTS))}")
        return normalized

    @field_validator("screenshot_filename")
    @classmethod
    def filename_only(cls, value: str | None) -> str | None:
        if value and ("/" in value or "\\" in value or value in {".", ".."}):
            raise ValueError("Screenshot must be a filename, not a path")
        return value


class CompareBody(BaseModel):
    experiment_ids: list[str] = Field(..., min_length=2, max_length=50)
    preset: str | None = None


class QueueEntry(BaseModel):
    experiment_id: str
    repeats: int = Field(1, ge=1, le=100)
    reset_gps_after: bool = True
    delay_after_s: float = Field(0.0, ge=0, le=3600)


class QueueBody(BaseModel):
    entries: list[QueueEntry] = Field(..., min_length=1, max_length=100)
    stop_on_failure: bool = True


class QuickTestBody(BaseModel):
    route: list[Coordinate] = Field(..., min_length=2)
    confirm_authorized_use: bool = False
    reset_gps_at_end: bool = True
