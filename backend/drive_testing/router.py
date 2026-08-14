from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse, PlainTextResponse, Response

from .experiment_controller import DriveExperimentController
from .experiment_queue import ExperimentQueueController
from .experiment_store import abbreviate_udid
from .flags import drive_testing_enabled, flag_status
from .profile_generator import METERS_PER_MILE, generate_profile, profile_presets, test_matrix_templates
from .schemas import (
    CompareBody,
    ExperimentCreateBody,
    ExperimentStartBody,
    ExperimentStopBody,
    ObservationBody,
    ProfileGenerateBody,
    QueueBody,
    QuickTestBody,
    RouteValidateBody,
)
from .route_sampler import validate_route


def build_router(
    controller: DriveExperimentController,
    queue: ExperimentQueueController,
    device_status_provider,
    stable_drive_status_provider,
) -> APIRouter:
    router = APIRouter(prefix="/api/experimental/drive-testing", tags=["Drive Testing Lab"])

    def gated() -> JSONResponse | None:
        if drive_testing_enabled():
            return None
        return JSONResponse(
            status_code=403,
            content={
                "ok": False,
                "code": "drive_testing_disabled",
                "message": (
                    "Drive Testing Lab is disabled. Set both "
                    "IOS_SIM_ENABLE_EXPERIMENTAL=1 and IOS_SIM_ENABLE_DRIVE_TESTING=1."
                ),
                "feature_flags": flag_status(),
            },
        )

    def error(result: dict, status_code: int = 409) -> JSONResponse:
        return JSONResponse(status_code=status_code, content=result)

    @router.get("/status")
    def lab_status():
        if response := gated():
            return response
        try:
            device = device_status_provider()
            backend_reachable = True
        except Exception as exc:
            device = {"pmd3_available": False, "device_connected": False, "device": None, "tunnel_active": False}
            backend_reachable = False
            device["status_error"] = str(exc)
        device_info = dict(device.get("device") or {})
        full_udid = str(device_info.pop("udid", ""))
        if full_udid:
            device_info["udid_abbreviated"] = abbreviate_udid(full_udid)
        stable = stable_drive_status_provider()
        experiment = controller.status()
        readiness = _readiness(device, stable, experiment, backend_reachable)
        return {
            "ok": True,
            "feature_flags": flag_status(),
            "backend_reachable": backend_reachable,
            "pmd3_available": bool(device.get("pmd3_available")),
            "pmd3_cli_available": bool(device.get("pmd3_cli_available", device.get("pmd3_available"))),
            "pmd3_python_api_available": bool(device.get("pmd3_python_api_available")),
            "pmd3_diagnostics": device.get("pmd3_diagnostics"),
            "device_connected": bool(device.get("device_connected")),
            "device": device_info or None,
            "tunnel_active": bool(device.get("tunnel_active")),
            "rsd_address_available": bool((device.get("tunnel") or {}).get("address")),
            "device_trusted": None,
            "ddi_mounted": None,
            "stable_drive": stable,
            "experiment": experiment,
            "readiness": readiness,
            "technical_limits": [
                "IOSSim does not measure or inject CLLocation.speed or CLLocation.course.",
                "IOSSim does not control Core Motion or device motion sensors.",
                "Third-party classification must be observed and entered manually.",
            ],
        }

    @router.get("/profiles")
    def profiles():
        if response := gated():
            return response
        return {"ok": True, "profiles": profile_presets(), "test_matrix": test_matrix_templates()}

    @router.post("/profiles/generate")
    def generate(body: ProfileGenerateBody):
        if response := gated():
            return response
        try:
            profile = generate_profile([item.model_dump() for item in body.coordinates], dict(body.settings))
            return {"ok": True, "profile": profile}
        except ValueError as exc:
            return error({"ok": False, "code": "profile_invalid", "message": str(exc)}, 422)

    @router.post("/routes/validate")
    def route_validate(body: RouteValidateBody):
        if response := gated():
            return response
        result = validate_route([item.model_dump() for item in body.coordinates], body.minimum_distance_m)
        return result if result.get("ok") else error(result, 422)

    @router.post("/experiments")
    def create_experiment(body: ExperimentCreateBody):
        if response := gated():
            return response
        route = [item.model_dump() for item in body.route]
        try:
            profile = generate_profile(route, dict(body.profile_settings))
        except ValueError as exc:
            return error({"ok": False, "code": "profile_invalid", "message": str(exc)}, 422)
        config = {
            "route_config": body.route_config,
            "reset_gps_at_end": body.reset_gps_at_end,
            "repeats": body.repeats,
            "feature_flags_enabled": True,
        }
        manifest = controller.create(route, profile, config)
        return {"ok": True, "experiment": manifest, "profile": profile}

    @router.get("/experiments")
    def list_experiments():
        if response := gated():
            return response
        return {"ok": True, "experiments": controller.store.list()}

    @router.get("/experiments/{experiment_id}")
    def get_experiment(experiment_id: str):
        if response := gated():
            return response
        try:
            return {"ok": True, "experiment": controller.store.get(experiment_id), "live_status": controller.status(experiment_id)}
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)

    @router.delete("/experiments/{experiment_id}")
    def delete_experiment(experiment_id: str, confirm: bool = Query(False)):
        if response := gated():
            return response
        if not confirm:
            return error({"ok": False, "code": "confirmation_required", "message": "Confirm local deletion. This does not delete third-party driving history."}, 400)
        if controller.active_experiment_id() == experiment_id:
            return error({"ok": False, "code": "experiment_active", "message": "Stop the active experiment before deleting it"})
        try:
            controller.store.delete(experiment_id)
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)
        return {"ok": True, "message": "Local IOSSim experiment deleted. Third-party driving history was not changed."}

    @router.post("/experiments/{experiment_id}/validate")
    def validate_experiment(experiment_id: str):
        if response := gated():
            return response
        try:
            result = controller.validate(experiment_id)
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)
        return result if result.get("ok") else error(result, 422)

    @router.post("/experiments/{experiment_id}/start")
    def start_experiment(experiment_id: str, body: ExperimentStartBody):
        if response := gated():
            return response
        try:
            result = controller.start(experiment_id, body.confirm_authorized_use)
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)
        return result if result.get("ok") else error(result)

    @router.post("/experiments/{experiment_id}/pause")
    def pause_experiment(experiment_id: str):
        if response := gated():
            return response
        result = controller.pause(experiment_id)
        return result if result.get("ok") else error(result)

    @router.post("/experiments/{experiment_id}/resume")
    def resume_experiment(experiment_id: str):
        if response := gated():
            return response
        result = controller.resume(experiment_id)
        return result if result.get("ok") else error(result)

    @router.post("/experiments/{experiment_id}/stop")
    def stop_experiment(experiment_id: str, body: ExperimentStopBody | None = None):
        if response := gated():
            return response
        result = controller.stop(experiment_id, reset_gps=body.reset_gps if body else False)
        return result if result.get("ok") else error(result)

    @router.post("/experiments/{experiment_id}/emergency-stop")
    def emergency_stop(experiment_id: str):
        if response := gated():
            return response
        result = controller.emergency_stop(experiment_id)
        return result if result.get("ok") else error(result)

    @router.post("/experiments/{experiment_id}/repeat")
    def repeat_experiment(experiment_id: str, body: ExperimentStartBody):
        if response := gated():
            return response
        result = controller.repeat(experiment_id, body.confirm_authorized_use)
        return result if result.get("ok") else error(result)

    @router.get("/experiments/{experiment_id}/status")
    def experiment_status(experiment_id: str):
        if response := gated():
            return response
        if not controller.store.exists(experiment_id):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)
        return controller.status(experiment_id)

    @router.post("/experiments/{experiment_id}/observation")
    def observation(experiment_id: str, body: ObservationBody):
        if response := gated():
            return response
        try:
            payload = controller.record_observation(experiment_id, body.model_dump(exclude_none=True))
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)
        return {"ok": True, "observation": payload}

    @router.get("/experiments/{experiment_id}/events")
    def experiment_events(experiment_id: str):
        if response := gated():
            return response
        try:
            return {"ok": True, "events": controller.store.events(experiment_id)}
        except ValueError:
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)

    @router.get("/experiments/{experiment_id}/report")
    def experiment_report(experiment_id: str):
        if response := gated():
            return response
        path = controller.store.path_for(experiment_id) / "report.md"
        if not path.exists():
            return error({"ok": False, "code": "report_unavailable", "message": "Report is generated after a run is finalized"}, 404)
        return PlainTextResponse(path.read_text(encoding="utf-8"), media_type="text/markdown")

    @router.get("/experiments/{experiment_id}/export/json")
    def export_json(experiment_id: str):
        if response := gated():
            return response
        try:
            return controller.store.export_json(experiment_id)
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)

    @router.get("/experiments/{experiment_id}/export/csv")
    def export_csv(experiment_id: str):
        if response := gated():
            return response
        try:
            content = controller.store.export_csv(experiment_id)
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "Experiment not found"}, 404)
        return Response(content, media_type="text/csv", headers={"Content-Disposition": f'attachment; filename="{experiment_id}.csv"'})

    @router.post("/compare")
    def compare(body: CompareBody):
        if response := gated():
            return response
        try:
            records = [controller.store.get(identifier, include_events=True) for identifier in body.experiment_ids]
        except (FileNotFoundError, ValueError):
            return error({"ok": False, "code": "not_found", "message": "One or more experiments were not found"}, 404)
        outcome_counts: dict[str, int] = {}
        comparison = []
        charts = []
        for record in records:
            observation = (record.get("observations") or [{}])[-1]
            result = observation.get("result", "application_not_checked")
            outcome_counts[result] = outcome_counts.get(result, 0) + 1
            comparison.append({
                "experiment_id": record.get("experiment_id"),
                "configuration": {"profile": record.get("profile_name"), "method": record.get("method"), "requested_distance_m": record.get("requested_distance_m")},
                "host_metrics": record.get("summary"),
                "manual_conditions": {key: value for key, value in observation.items() if key not in {"result", "notes", "interpretation"}},
                "observed_outcome": result,
                "qc": record.get("qc"),
            })
            charts.append({"experiment_id": record.get("experiment_id"), "points": [event for event in record.get("events", []) if event.get("event_type") == "location_write"]})
        return {
            "ok": True,
            "preset": body.preset,
            "comparison": comparison,
            "charts": charts,
            "outcome_counts": outcome_counts,
            "comparable_run_count": len(records),
            "show_percentages": len(records) >= 3,
            "disclaimer": "Exploratory observations only. Not a validated success probability.",
        }

    @router.post("/queue")
    def configure_queue(body: QueueBody):
        if response := gated():
            return response
        result = queue.configure([entry.model_dump() for entry in body.entries], body.stop_on_failure)
        return result if result.get("ok") else error(result, 422)

    @router.get("/queue/status")
    def queue_status():
        if response := gated():
            return response
        return queue.status()

    @router.post("/queue/start")
    def queue_start(body: ExperimentStartBody):
        if response := gated():
            return response
        result = queue.start(body.confirm_authorized_use)
        return result if result.get("ok") else error(result)

    @router.post("/queue/pause")
    def queue_pause():
        if response := gated():
            return response
        result = queue.pause()
        return result if result.get("ok") else error(result)

    @router.post("/queue/resume")
    def queue_resume():
        if response := gated():
            return response
        result = queue.resume()
        return result if result.get("ok") else error(result)

    @router.post("/queue/stop")
    def queue_stop():
        if response := gated():
            return response
        return queue.stop()

    @router.post("/reset")
    def reset():
        if response := gated():
            return response
        result = controller.reset()
        return result if result.get("ok") else error(result, 500)

    @router.post("/quick-test")
    def quick_test(body: QuickTestBody):
        if response := gated():
            return response
        route = [item.model_dump() for item in body.route]
        check = validate_route(route, 0.6 * METERS_PER_MILE)
        if not check.get("ok"):
            return error({"ok": False, "code": "quick_test_route_too_short", "message": "Quick Test requires a valid road route of at least 0.6 mile", "route": check}, 422)
        settings = {"name": "Quick Test - 20 mph, 0.6 mile", "kind": "constant", "method": "timed_static", "target_speed_mph": 20, "distance_miles": 0.6, "update_interval_s": 1.0, "random_seed": 1}
        profile = generate_profile(route, settings)
        if not body.confirm_authorized_use:
            return {"ok": True, "requires_confirmation": True, "profile": profile, "calculated_duration_s": profile["planned_duration_s"]}
        manifest = controller.create(route, profile, {"route_config": {"quick_test": True}, "reset_gps_at_end": body.reset_gps_at_end, "repeats": 1, "feature_flags_enabled": True})
        result = controller.start(manifest["experiment_id"], confirm_authorized_use=True)
        return result if result.get("ok") else error(result)

    return router


def _readiness(device: dict[str, Any], stable: dict[str, Any], experiment: dict[str, Any], backend_reachable: bool) -> dict[str, Any]:
    diagnostics = device.get("pmd3_diagnostics") or {}
    pmd3_detail = ""
    if not device.get("pmd3_available"):
        diagnostic_parts = []
        if diagnostics.get("python_executable"):
            diagnostic_parts.append(f"Python: {diagnostics.get('python_executable')}")
        if diagnostics.get("cli_returncode") is not None:
            diagnostic_parts.append(f"CLI return code: {diagnostics.get('cli_returncode')}")
        if diagnostics.get("package_version"):
            diagnostic_parts.append(f"package version: {diagnostics.get('package_version')}")
        if diagnostics.get("stderr_summary"):
            diagnostic_parts.append(f"stderr: {diagnostics.get('stderr_summary')}")
        if diagnostics.get("message"):
            diagnostic_parts.append(str(diagnostics.get("message")))
        pmd3_detail = "; ".join(diagnostic_parts)
    checks = [
        {"name": "Backend reachable", "status": "PASS" if backend_reachable else "FAIL", "detail": ""},
        {"name": "pymobiledevice3 available", "status": "PASS" if device.get("pmd3_available") else "FAIL", "detail": pmd3_detail},
        {"name": "Device connected", "status": "PASS" if device.get("device_connected") else "FAIL", "detail": ""},
        {"name": "Device trusted", "status": "WARNING", "detail": "Trust state is not exposed by the current backend"},
        {"name": "Developer Disk Image", "status": "WARNING", "detail": "Mounted state is not exposed by the current backend"},
    ]
    needs_tunnel = bool((device.get("device") or {}).get("needs_tunnel"))
    checks.append({"name": "Tunnel active when required", "status": "PASS" if not needs_tunnel or device.get("tunnel_active") else "FAIL", "detail": ""})
    checks.append({"name": "Stable Drive Mode inactive", "status": "PASS" if stable.get("state") not in {"starting", "driving", "paused"} else "FAIL", "detail": ""})
    checks.append({"name": "Drive Testing experiment inactive", "status": "PASS" if experiment.get("state") not in {"starting", "running", "paused", "stopping"} else "FAIL", "detail": ""})
    statuses = {item["status"] for item in checks}
    overall = "FAIL" if "FAIL" in statuses else "WARNING" if "WARNING" in statuses else "PASS"
    return {"overall": overall, "checks": checks}
