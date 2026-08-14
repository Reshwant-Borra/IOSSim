from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel, Field

from .controller import EXPERIMENT_A, EXPERIMENT_B, WirelessTestingController
from .flags import flag_status, wireless_testing_enabled


class ExperimentCreateBody(BaseModel):
    test_type: Literal["remove_cable_after_pairing", "fresh_cable_free_session"]


class LocationBody(BaseModel):
    lat: float = Field(..., ge=-90, le=90)
    lon: float = Field(..., ge=-180, le=180)


class TunnelStartBody(BaseModel):
    protocol: Literal["default", "tcp", "quic"] = "default"


class ConfirmationBody(BaseModel):
    confirmation: Literal["yes", "no", "not_sure"]
    notes: str = Field("", max_length=1000)


def build_router(controller: WirelessTestingController) -> APIRouter:
    router = APIRouter(prefix="/api/experimental/wireless-testing", tags=["Wireless Testing Lab"])

    def gated() -> JSONResponse | None:
        if wireless_testing_enabled():
            return None
        return JSONResponse(
            status_code=403,
            content={
                "ok": False,
                "code": "wireless_testing_disabled",
                "message": (
                    "Wireless Testing Lab is disabled. Set both "
                    "IOS_SIM_ENABLE_EXPERIMENTAL=1 and IOS_SIM_ENABLE_WIRELESS_TESTING=1."
                ),
                "feature_flags": flag_status(),
            },
        )

    def response(result: dict, status_code: int = 409):
        if result.get("ok", True):
            return result
        return JSONResponse(status_code=status_code, content=result)

    @router.get("/status")
    def status():
        if blocked := gated():
            return blocked
        return {**controller.status(), "feature_flags": flag_status()}

    @router.get("/capabilities")
    def capabilities(force: bool = Query(False)):
        if blocked := gated():
            return blocked
        return {"ok": True, "capabilities": controller.capabilities(force=force)}

    @router.post("/experiments")
    def create(body: ExperimentCreateBody):
        if blocked := gated():
            return blocked
        return response(controller.create_experiment(body.test_type))

    @router.get("/experiments")
    def list_experiments():
        if blocked := gated():
            return blocked
        return {"ok": True, "experiments": controller.store.list(), "test_types": [EXPERIMENT_A, EXPERIMENT_B]}

    @router.get("/experiments/{experiment_id}")
    def get_experiment(experiment_id: str):
        if blocked := gated():
            return blocked
        try:
            return {"ok": True, "experiment": controller.store.get(experiment_id, include_events=True)}
        except (FileNotFoundError, ValueError):
            return response({"ok": False, "code": "not_found", "message": "Wireless experiment not found"}, 404)

    @router.delete("/experiments/{experiment_id}")
    def delete_experiment(experiment_id: str, confirm: bool = Query(False)):
        if blocked := gated():
            return blocked
        if not confirm:
            return response({"ok": False, "code": "confirmation_required", "message": "Confirm local deletion."}, 400)
        try:
            controller.store.delete(experiment_id)
            return {"ok": True, "message": "Wireless experiment deleted"}
        except (FileNotFoundError, ValueError):
            return response({"ok": False, "code": "not_found", "message": "Wireless experiment not found"}, 404)

    @router.post("/experiments/{experiment_id}/wired-baseline")
    def wired_baseline(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.wired_baseline(experiment_id))

    @router.post("/experiments/{experiment_id}/wired-baseline/set-location")
    def wired_set_location(experiment_id: str, body: LocationBody):
        if blocked := gated():
            return blocked
        return response(controller.stable_set_location(experiment_id, body.lat, body.lon))

    @router.post("/experiments/{experiment_id}/wired-baseline/reset-gps")
    def wired_reset_gps(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.stable_reset_gps(experiment_id))

    @router.post("/experiments/{experiment_id}/pairing-check")
    def pairing_check(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.pairing_check(experiment_id))

    @router.post("/experiments/{experiment_id}/prepare-unplug")
    def prepare_unplug(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.prepare_unplug(experiment_id))

    @router.post("/experiments/{experiment_id}/confirm-cable-removed")
    def confirm_cable_removed(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.confirm_cable_removed(experiment_id))

    @router.post("/experiments/{experiment_id}/detect-without-usb")
    def detect_without_usb(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.detect_without_usb(experiment_id))

    @router.post("/experiments/{experiment_id}/start-wifi-tunnel")
    def start_wifi_tunnel(experiment_id: str, body: TunnelStartBody | None = None):
        if blocked := gated():
            return blocked
        protocol = None if body is None or body.protocol == "default" else body.protocol
        return response(controller.start_wifi_tunnel(experiment_id, protocol=protocol))

    @router.post("/experiments/{experiment_id}/validate-rsd")
    def validate_rsd(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.validate_rsd(experiment_id))

    @router.post("/experiments/{experiment_id}/set-location")
    def set_location(experiment_id: str, body: LocationBody):
        if blocked := gated():
            return blocked
        return response(controller.wireless_set_location(experiment_id, body.lat, body.lon))

    @router.post("/experiments/{experiment_id}/location-confirmation")
    def location_confirmation(experiment_id: str, body: ConfirmationBody):
        if blocked := gated():
            return blocked
        return response(controller.record_location_confirmation(experiment_id, body.confirmation, body.notes))

    @router.post("/experiments/{experiment_id}/reset-gps")
    def reset_gps(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.wireless_reset_gps(experiment_id))

    @router.post("/experiments/{experiment_id}/reset-confirmation")
    def reset_confirmation(experiment_id: str, body: ConfirmationBody):
        if blocked := gated():
            return blocked
        return response(controller.record_reset_confirmation(experiment_id, body.confirmation, body.notes))

    @router.post("/experiments/{experiment_id}/finalize")
    def finalize(experiment_id: str):
        if blocked := gated():
            return blocked
        return response(controller.finalize(experiment_id))

    @router.get("/experiments/{experiment_id}/events")
    def events(experiment_id: str):
        if blocked := gated():
            return blocked
        try:
            return {"ok": True, "events": controller.store.events(experiment_id)}
        except ValueError:
            return response({"ok": False, "code": "not_found", "message": "Wireless experiment not found"}, 404)

    @router.get("/experiments/{experiment_id}/report")
    def report(experiment_id: str):
        if blocked := gated():
            return blocked
        try:
            return PlainTextResponse(controller.report_text(experiment_id), media_type="text/markdown")
        except (FileNotFoundError, ValueError):
            return response({"ok": False, "code": "not_found", "message": "Wireless experiment not found"}, 404)

    @router.get("/experiments/{experiment_id}/export/json")
    def export_json(experiment_id: str):
        if blocked := gated():
            return blocked
        try:
            return controller.store.export_json(experiment_id)
        except (FileNotFoundError, ValueError):
            return response({"ok": False, "code": "not_found", "message": "Wireless experiment not found"}, 404)

    @router.post("/experiments/{experiment_id}/stop")
    def stop_experiment(experiment_id: str):
        if blocked := gated():
            return blocked
        return controller.stop(experiment_id, clear_state=False)

    @router.post("/stop")
    def stop_all():
        if blocked := gated():
            return blocked
        return controller.stop(clear_state=True)

    @router.delete("/tunnel")
    def stop_tunnel():
        if blocked := gated():
            return blocked
        return controller.stop_wifi_tunnel()

    return router
