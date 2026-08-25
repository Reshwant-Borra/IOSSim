from __future__ import annotations

from typing import Literal

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .controller import WirelessLocationController


class ModeBody(BaseModel):
    mode: Literal["automatic", "usb", "wireless"] = "automatic"
    device_udid: str | None = None


class DeviceBody(BaseModel):
    device_udid: str = Field(..., min_length=12)


class WirelessLocationBody(DeviceBody):
    lat: float = Field(..., ge=-90, le=90)
    lon: float = Field(..., ge=-180, le=180)


def response(payload: dict):
    if payload.get("ok", True):
        return payload
    return JSONResponse(status_code=400, content=payload)


def build_router(controller: WirelessLocationController) -> APIRouter:
    router = APIRouter(prefix="/api/wireless-location", tags=["Wireless Location"])

    @router.get("/devices")
    def list_devices():
        return controller.list_devices(refresh=True)

    @router.get("/status")
    def status():
        return controller.status(refresh=True)

    @router.get("/diagnostics")
    def diagnostics():
        return controller.diagnostics()

    @router.post("/connection-mode")
    def connection_mode(body: ModeBody):
        return response(controller.set_connection_mode(body.mode, body.device_udid))

    @router.post("/setup/start")
    def setup_start():
        return response(controller.begin_setup())

    @router.post("/setup/verify-unplugged")
    def setup_verify_unplugged(body: DeviceBody):
        return response(controller.verify_setup_unplugged(body.device_udid))

    @router.post("/connect")
    def connect(body: DeviceBody):
        return response(controller.connect_wireless(body.device_udid))

    @router.post("/disconnect")
    def disconnect(body: DeviceBody):
        return response(controller.disconnect_wireless(body.device_udid))

    @router.post("/set-location")
    def set_location(body: WirelessLocationBody):
        return response(controller.set_location(body.lat, body.lon, udid=body.device_udid))

    @router.post("/clear-location")
    def clear_location(body: DeviceBody):
        return response(controller.clear_location(udid=body.device_udid))

    @router.delete("/devices/{device_udid}")
    def remove_device(device_udid: str):
        return response(controller.remove_device(device_udid))

    return router
