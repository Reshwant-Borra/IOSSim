const BASE = '/api'

export class ApiError extends Error {
  status: number
  code?: string
  details: unknown

  constructor(message: string, status: number, code?: string, details?: unknown) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.details = details
  }
}

export async function req<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    const err = await res.json().catch(() => ({ detail: res.statusText }))
    const detail = typeof err.detail === 'string' ? err.detail : err.detail?.message
    throw new ApiError(detail ?? err.message ?? res.statusText, res.status, err.code, err)
  }
  return res.json()
}

async function reqText(path: string): Promise<string> {
  const res = await fetch(`${BASE}${path}`)
  if (!res.ok) {
    const err = await res.json().catch(() => ({ detail: res.statusText }))
    throw new ApiError(err.detail ?? err.message ?? res.statusText, res.status, err.code, err)
  }
  return res.text()
}

export const api = {
  status: () => req<DeviceStatus>('GET', '/status'),
  mountDdi: () => req<OkMsg>('POST', '/setup/mount-ddi'),
  startTunnel: () => req<TunnelResult>('POST', '/setup/tunnel'),
  stopTunnel: () => req<OkMsg>('DELETE', '/setup/tunnel'),
  setLocation: (lat: number, lon: number) => req<OkMsg>('POST', '/location/set', { lat, lon }),
  clearLocation: () => req<OkMsg>('POST', '/location/clear'),
  playRoute: (waypoints: LatLon[], speed_mps: number) =>
    req<OkMsg>('POST', '/location/route', { waypoints, speed_mps }),
  startDrive: (waypoints: LatLon[], speed_mps: number, tick_s: number, stay_at_end: boolean) =>
    req<DriveStatus>('POST', '/location/drive/start', { waypoints, speed_mps, tick_s, stay_at_end }),
  geocodeDriveAddress: (address: string) =>
    req<GeocodeResponse>('POST', '/location/drive/geocode', { address }),
  buildDriveRoute: (start: LatLon, destination: LatLon) =>
    req<DriveRouteResponse>('POST', '/location/drive/route', { start, destination }),
  startRoadRoute: (coordinates: LatLon[], speed_mps: number, tick_s: number, stay_at_end: boolean) =>
    req<DriveStatus>('POST', '/location/drive/start-road-route', { coordinates, speed_mps, tick_s, stay_at_end }),
  pauseDrive: () => req<DriveStatus>('POST', '/location/drive/pause'),
  resumeDrive: () => req<DriveStatus>('POST', '/location/drive/resume'),
  stopDrive: (clear_location = false) =>
    req<DriveStatus>('POST', '/location/drive/stop', { clear_location }),
  driveStatus: () => req<DriveStatus>('GET', '/location/drive/status'),
  listFavorites: () => req<Favorite[]>('GET', '/favorites'),
  addFavorite: (name: string, lat: number, lon: number, note?: string) =>
    req<Favorite>('POST', '/favorites', { name, lat, lon, note }),
  deleteFavorite: (id: number) => req<OkMsg>('DELETE', `/favorites/${id}`),
  driveTestingStatus: () => req<DriveTestingLabStatus>('GET', '/experimental/drive-testing/status'),
  driveTestingProfiles: () => req<DriveTestingProfilesResponse>('GET', '/experimental/drive-testing/profiles'),
  generateDriveTestingProfile: (coordinates: LatLon[], settings: DriveTestingProfileSettings) =>
    req<{ ok: boolean; profile: DriveTestingProfile }>('POST', '/experimental/drive-testing/profiles/generate', { coordinates, settings }),
  validateDriveTestingRoute: (coordinates: LatLon[], minimum_distance_m: number) =>
    req<DriveTestingRouteValidation>('POST', '/experimental/drive-testing/routes/validate', { coordinates, minimum_distance_m }),
  createDriveTestingExperiment: (route: LatLon[], profile_settings: DriveTestingProfileSettings, route_config: Record<string, unknown>, reset_gps_at_end: boolean, repeats = 1) =>
    req<DriveTestingCreateResponse>('POST', '/experimental/drive-testing/experiments', { route, profile_settings, route_config, reset_gps_at_end, repeats }),
  listDriveTestingExperiments: () => req<DriveTestingHistoryResponse>('GET', '/experimental/drive-testing/experiments'),
  getDriveTestingExperiment: (id: string) => req<{ ok: boolean; experiment: DriveTestingExperiment; live_status: DriveTestingExperimentStatus }>('GET', `/experimental/drive-testing/experiments/${id}`),
  deleteDriveTestingExperiment: (id: string) => req<OkMsg>('DELETE', `/experimental/drive-testing/experiments/${id}?confirm=true`),
  validateDriveTestingExperiment: (id: string) => req<DriveTestingValidation>('POST', `/experimental/drive-testing/experiments/${id}/validate`),
  startDriveTestingExperiment: (id: string, confirm_authorized_use = true) => req<DriveTestingExperimentStatus>('POST', `/experimental/drive-testing/experiments/${id}/start`, { confirm_authorized_use }),
  pauseDriveTestingExperiment: (id: string) => req<DriveTestingExperimentStatus>('POST', `/experimental/drive-testing/experiments/${id}/pause`),
  resumeDriveTestingExperiment: (id: string) => req<DriveTestingExperimentStatus>('POST', `/experimental/drive-testing/experiments/${id}/resume`),
  stopDriveTestingExperiment: (id: string, reset_gps = false) => req<DriveTestingExperimentStatus>('POST', `/experimental/drive-testing/experiments/${id}/stop`, { reset_gps }),
  emergencyStopDriveTestingExperiment: (id: string) => req<DriveTestingExperimentStatus>('POST', `/experimental/drive-testing/experiments/${id}/emergency-stop`),
  repeatDriveTestingExperiment: (id: string, confirm_authorized_use = true) => req<DriveTestingExperimentStatus>('POST', `/experimental/drive-testing/experiments/${id}/repeat`, { confirm_authorized_use }),
  driveTestingExperimentStatus: (id: string) => req<DriveTestingExperimentStatus>('GET', `/experimental/drive-testing/experiments/${id}/status`),
  recordDriveTestingObservation: (id: string, observation: DriveTestingObservation) => req<{ ok: boolean; observation: DriveTestingObservation }>('POST', `/experimental/drive-testing/experiments/${id}/observation`, observation),
  driveTestingEvents: (id: string) => req<{ ok: boolean; events: Record<string, unknown>[] }>('GET', `/experimental/drive-testing/experiments/${id}/events`),
  driveTestingReport: (id: string) => reqText(`/experimental/drive-testing/experiments/${id}/report`),
  driveTestingExportUrl: (id: string, format: 'json' | 'csv') => `${BASE}/experimental/drive-testing/experiments/${id}/export/${format}`,
  compareDriveTestingExperiments: (experiment_ids: string[], preset?: string) => req<DriveTestingComparison>('POST', '/experimental/drive-testing/compare', { experiment_ids, preset }),
  configureDriveTestingQueue: (entries: DriveTestingQueueEntry[]) => req<DriveTestingQueueStatus>('POST', '/experimental/drive-testing/queue', { entries, stop_on_failure: true }),
  driveTestingQueueStatus: () => req<DriveTestingQueueStatus>('GET', '/experimental/drive-testing/queue/status'),
  startDriveTestingQueue: () => req<DriveTestingQueueStatus>('POST', '/experimental/drive-testing/queue/start', { confirm_authorized_use: true }),
  pauseDriveTestingQueue: () => req<DriveTestingQueueStatus>('POST', '/experimental/drive-testing/queue/pause'),
  resumeDriveTestingQueue: () => req<DriveTestingQueueStatus>('POST', '/experimental/drive-testing/queue/resume'),
  stopDriveTestingQueue: () => req<DriveTestingQueueStatus>('POST', '/experimental/drive-testing/queue/stop'),
  resetDriveTestingGps: () => req<OkMsg>('POST', '/experimental/drive-testing/reset'),
  quickDriveTestingPreview: (route: LatLon[], reset_gps_at_end: boolean) => req<DriveTestingQuickTestResponse>('POST', '/experimental/drive-testing/quick-test', { route, reset_gps_at_end, confirm_authorized_use: false }),
  quickDriveTestingStart: (route: LatLon[], reset_gps_at_end: boolean) => req<DriveTestingExperimentStatus>('POST', '/experimental/drive-testing/quick-test', { route, reset_gps_at_end, confirm_authorized_use: true }),
  wirelessTestingStatus: () => req<WirelessTestingStatus>('GET', '/experimental/wireless-testing/status'),
  wirelessTestingCapabilities: (force = false) => req<{ ok: boolean; capabilities: WirelessCapabilities }>('GET', `/experimental/wireless-testing/capabilities?force=${force ? 'true' : 'false'}`),
  createWirelessExperiment: (test_type: WirelessTestType) => req<WirelessExperimentResponse>('POST', '/experimental/wireless-testing/experiments', { test_type }),
  listWirelessExperiments: () => req<WirelessHistoryResponse>('GET', '/experimental/wireless-testing/experiments'),
  getWirelessExperiment: (id: string) => req<{ ok: boolean; experiment: WirelessExperiment }>('GET', `/experimental/wireless-testing/experiments/${id}`),
  deleteWirelessExperiment: (id: string) => req<OkMsg>('DELETE', `/experimental/wireless-testing/experiments/${id}?confirm=true`),
  runWirelessWiredBaseline: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/wired-baseline`),
  testWirelessWiredSetLocation: (id: string, lat: number, lon: number) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/wired-baseline/set-location`, { lat, lon }),
  testWirelessWiredResetGps: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/wired-baseline/reset-gps`),
  runWirelessPairingCheck: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/pairing-check`),
  prepareWirelessUnplug: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/prepare-unplug`),
  confirmWirelessCableRemoved: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/confirm-cable-removed`),
  detectWirelessWithoutUsb: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/detect-without-usb`),
  startWirelessWifiTunnel: (id: string, protocol: 'default' | 'tcp' | 'quic' = 'default') => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/start-wifi-tunnel`, { protocol }),
  validateWirelessRsd: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/validate-rsd`),
  testWirelessSetLocation: (id: string, lat: number, lon: number) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/set-location`, { lat, lon }),
  recordWirelessLocationConfirmation: (id: string, confirmation: WirelessManualConfirmation, notes = '') => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/location-confirmation`, { confirmation, notes }),
  testWirelessResetGps: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/reset-gps`),
  recordWirelessResetConfirmation: (id: string, confirmation: WirelessManualConfirmation, notes = '') => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/reset-confirmation`, { confirmation, notes }),
  finalizeWirelessExperiment: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/finalize`),
  stopWirelessExperiment: (id: string) => req<WirelessOperationResponse>('POST', `/experimental/wireless-testing/experiments/${id}/stop`),
  stopWirelessTesting: () => req<WirelessOperationResponse>('POST', '/experimental/wireless-testing/stop'),
  stopWirelessWifiTunnel: () => req<OkMsg>('DELETE', '/experimental/wireless-testing/tunnel'),
  wirelessTestingReport: (id: string) => reqText(`/experimental/wireless-testing/experiments/${id}/report`),
  wirelessTestingExportUrl: (id: string) => `${BASE}/experimental/wireless-testing/experiments/${id}/export/json`,
}

export interface LatLon { lat: number; lon: number }
export interface OkMsg { ok: boolean; message?: string }
export interface TunnelResult { ok: boolean; address?: string; port?: number; message?: string }
export interface Favorite { id: number; name: string; lat: number; lon: number; note: string }

export interface GeocodeResult {
  display_name: string
  lat: number
  lon: number
}

export interface GeocodeResponse {
  ok: boolean
  provider: string
  cached: boolean
  results: GeocodeResult[]
  message: string
}

export interface DriveRouteResponse {
  ok: boolean
  provider: string
  profile: string
  cached: boolean
  coordinates: LatLon[]
  distance_m: number
  osrm_duration_s: number
  message: string
}

export interface DriveStatus {
  ok: boolean
  session_id: string | null
  state: 'idle' | 'starting' | 'driving' | 'paused' | 'arrived' | 'stopped' | 'error'
  current_location: LatLon | null
  speed_mps: number | null
  elapsed_s: number
  eta_s: number | null
  progress: number
  total_distance_m: number
  distance_remaining_m: number
  stay_at_end: boolean
  message: string
}

export interface DeviceStatus {
  pmd3_available: boolean
  pmd3_cli_available?: boolean
  pmd3_python_api_available?: boolean
  pmd3_diagnostics?: {
    python_executable?: string
    package_version?: string | null
    cli_returncode?: number | null
    stderr_summary?: string
    message?: string
    available?: boolean
  } | null
  device_connected: boolean
  device: {
    udid: string
    name: string
    ios_version: string
    ios_major: number
    needs_tunnel: boolean
  } | null
  tunnel_active: boolean
  tunnel: { address: string; port: number } | null
}

export type WirelessTestType = 'remove_cable_after_pairing' | 'fresh_cable_free_session'
export type WirelessManualConfirmation = 'yes' | 'no' | 'not_sure'
export type WirelessCheckStatus = 'PASS' | 'WARNING' | 'FAIL' | 'UNKNOWN'

export interface WirelessFeatureFlags {
  backend_experimental_enabled: boolean
  backend_wireless_testing_enabled: boolean
  wireless_testing_enabled: boolean
}

export interface WirelessReadinessCheck {
  name: string
  status: WirelessCheckStatus
  detail: string
}

export interface WirelessCapabilities {
  pymobiledevice3_importable?: boolean
  pymobiledevice3_version?: string | null
  required_wireless_commands_available?: boolean
  commands?: Record<string, { available: boolean; command: string[]; stdout_summary?: string; stderr_summary?: string }>
  [key: string]: unknown
}

export interface WirelessUsbState {
  usb_detected: boolean
  transport: 'USB' | 'UNKNOWN' | string
  devices: Array<Record<string, unknown>>
  command?: Record<string, unknown>
}

export interface WirelessConnectionStatus {
  ok: boolean
  experiment_id: string | null
  test_type: WirelessTestType | null
  state: string
  current_stage: string
  current_transport: 'USB' | 'WIFI' | 'USB+WIFI' | 'UNKNOWN' | string
  usb_detected: boolean
  wireless_device_detected: boolean
  wireless_same_device: boolean | null
  wifi_tunnel_active: boolean
  wifi_tunnel_pid: number | null
  tunnel_transport: 'WIFI' | 'USB' | 'UNKNOWN' | string | null
  rsd_ready: boolean
  rsd_source: string | null
  location_session_active: boolean
  last_successful_contact: string | null
  last_error: string | null
  verdict: string
  message: string
  manual_location_confirmation?: WirelessManualConfirmation | null
  manual_reset_confirmation?: WirelessManualConfirmation | null
  pairing_bootstrap_status?: string | null
  wifi_connections_status?: string | null
  wireless_discovery_status?: string | null
  pairing_preparation_status?: string | null
  tunnel_strategy?: Record<string, unknown> | null
  tunnel_attempts?: Array<Record<string, unknown>>
  selected_protocol?: string | null
  selected_candidate?: Record<string, unknown> | null
  last_tunnel_failure_class?: string | null
  fresh_rsd_proof_state?: string | null
}

export interface WirelessDiscoveryMethod {
  ok: boolean
  found: boolean
  returncode?: number | null
  stdout_summary?: string
  stderr_summary?: string
  parsed?: unknown
  transport: 'USB' | 'WIFI' | 'UNKNOWN' | string
}

export interface WirelessDiscovery {
  wireless_device_detected: boolean
  same_device: boolean | null
  best_method: string | null
  methods: Record<string, WirelessDiscoveryMethod>
  remote_pairing_candidates?: Array<Record<string, unknown>>
}

export interface WirelessExperiment {
  experiment_id: string
  test_type: WirelessTestType
  created_at: string
  updated_at?: string
  state: string
  verdict: string
  session_started_usb_present?: boolean
  summary?: Record<string, unknown>
  output_directory?: string
  metadata?: Record<string, unknown>
  observations?: Array<Record<string, unknown>>
}

export interface WirelessTestingStatus {
  ok: boolean
  backend_reachable: boolean
  feature_flags?: WirelessFeatureFlags
  stable_status: Partial<DeviceStatus>
  usb: WirelessUsbState
  capabilities: WirelessCapabilities
  xcode: { platform: string; installed: boolean; version: string | null; instruction_variant: string; message: string }
  connection: WirelessConnectionStatus
  readiness: { overall: WirelessCheckStatus; checks: WirelessReadinessCheck[] }
  history: WirelessExperiment[]
  pairing_guidance: string[]
}

export interface WirelessExperimentResponse {
  ok: boolean
  experiment: WirelessExperiment
  status: WirelessConnectionStatus
}

export interface WirelessOperationResponse {
  ok: boolean
  code?: string
  message?: string
  status?: WirelessConnectionStatus
  experiment?: WirelessExperiment
  verdict?: string
  report?: string
  discovery?: WirelessDiscovery
  pairing_status?: string
  preparation_status?: string
  preparation_reasons?: string[]
  prerequisites?: Record<string, unknown>
  pairing_bootstrap?: Record<string, unknown>
  wifi_connections?: Record<string, unknown>
  usb_absent?: boolean
  usb?: WirelessUsbState
  wireless_rsd_proof_complete?: boolean
  tunnel?: Record<string, unknown>
  tunnel_strategy?: Record<string, unknown>
  tunnel_attempts?: Array<Record<string, unknown>>
  selected_protocol?: string | null
  selected_candidate?: Record<string, unknown> | null
  last_tunnel_failure_class?: string | null
  rsd_info?: Record<string, unknown> | null
  command?: Record<string, unknown>
  result?: Record<string, unknown>
  baseline?: Record<string, unknown>
  record?: Record<string, unknown>
  observation?: Record<string, unknown>
}

export interface WirelessHistoryResponse {
  ok: boolean
  experiments: WirelessExperiment[]
  test_types: WirelessTestType[]
}

export type DriveTestingMethod = 'timed_static' | 'legacy_gpx' | 'timestamped_gpx' | 'gpx_pacing' | 'stable_baseline'
export type DriveTestingState = 'idle' | 'validating' | 'ready' | 'starting' | 'running' | 'paused' | 'stopping' | 'completed' | 'cancelled' | 'error'

export interface DriveTestingProfileSettings {
  id?: string
  name?: string
  kind: string
  method: DriveTestingMethod
  target_speed_mph: number
  distance_miles: number
  update_interval_s: number
  timing_variation_s?: number
  random_seed: number
  transition_s?: number
  negative_control?: boolean
}

export interface DriveTestingSample {
  sequence: number
  latitude: number
  longitude: number
  planned_elapsed_s: number
  planned_interval_s: number
  target_apparent_speed_mps: number
  target_apparent_speed_mph: number
  segment_distance_m: number
  cumulative_distance_m: number
  phase: string
}

export interface DriveTestingProfile {
  schema_version: string
  name: string
  kind: string
  method: DriveTestingMethod
  negative_control: boolean
  random_seed: number
  requested_distance_m: number
  generated_distance_m: number
  distance_difference_m: number
  distance_error_percent: number
  planned_duration_s: number
  planned_average_apparent_speed_mps: number
  target_apparent_speed_mph: number
  target_apparent_speed_mps: number
  update_interval_s: number
  timing_variation_s: number
  route: LatLon[]
  samples: DriveTestingSample[]
}

export interface DriveTestingPreset extends DriveTestingProfileSettings { id: string; name: string }
export interface DriveTestingProfilesResponse { ok: boolean; profiles: DriveTestingPreset[]; test_matrix: Record<string, DriveTestingPreset[]> }

export interface ReadinessCheck { name: string; status: 'PASS' | 'WARNING' | 'FAIL'; detail: string }
export interface DriveTestingLabStatus {
  ok: boolean
  feature_flags: { backend_experimental_enabled: boolean; backend_drive_testing_enabled: boolean; drive_testing_enabled: boolean }
  backend_reachable: boolean
  pmd3_available: boolean
  pmd3_cli_available?: boolean
  pmd3_python_api_available?: boolean
  pmd3_diagnostics?: {
    python_executable?: string
    package_version?: string | null
    cli_returncode?: number | null
    stderr_summary?: string
    message?: string
    available?: boolean
  } | null
  device_connected: boolean
  device: { name: string; ios_version: string; ios_major: number; needs_tunnel: boolean; udid_abbreviated?: string } | null
  tunnel_active: boolean
  rsd_address_available: boolean
  device_trusted: boolean | null
  ddi_mounted: boolean | null
  stable_drive: DriveStatus
  experiment: DriveTestingExperimentStatus
  readiness: { overall: 'PASS' | 'WARNING' | 'FAIL'; checks: ReadinessCheck[] }
  technical_limits: string[]
}

export interface DriveTestingRouteValidation { ok: boolean; message: string; distance_m: number; coordinate_count: number; meets_minimum_distance: boolean }
export interface DriveTestingValidation { ok: boolean; state: DriveTestingState; checks: Record<string, boolean>; message: string }

export interface DriveTestingExperimentStatus {
  ok: boolean
  code?: string
  experiment_id: string | null
  run_id: string | null
  state: DriveTestingState
  profile_name: string | null
  method: DriveTestingMethod | null
  repeat_number: number
  total_repeats: number
  elapsed_s: number
  estimated_remaining_s: number | null
  current_phase: string | null
  current_coordinate: LatLon | null
  current_sample: number
  total_samples: number
  completed_distance_m: number
  remaining_distance_m: number
  host_planned_apparent_speed_mph: number
  host_calculated_emitted_apparent_speed_mph: number
  host_calculated_average_apparent_speed_mph: number
  target_update_interval_s: number
  actual_latest_update_interval_s: number | null
  latest_timing_drift_s: number | null
  latest_command_latency_s: number | null
  successful_location_writes: number
  failed_location_writes: number
  active_subprocess_pid: number | null
  device_connected: boolean
  tunnel_active: boolean
  pause_supported: boolean
  last_error: string | null
  message: string
  chart_points: DriveTestingChartPoint[]
}

export interface DriveTestingChartPoint { elapsed_s: number; planned_speed_mph: number; emitted_speed_mph: number; distance_m: number; timing_drift_s: number; latency_s: number }
export interface DriveTestingCreateResponse { ok: boolean; experiment: DriveTestingExperiment; profile: DriveTestingProfile }
export interface DriveTestingExperiment {
  experiment_id: string
  created_at: string
  state: DriveTestingState
  run_id: string | null
  repeat_number: number
  total_repeats: number
  profile_name: string
  method: DriveTestingMethod
  requested_distance_m: number
  output_directory?: string
  last_error?: string | null
  profile?: DriveTestingProfile
  observations?: DriveTestingObservation[]
  summary?: Record<string, number>
  qc?: { status: string }
}

export interface DriveTestingHistoryRow extends DriveTestingExperiment {
  emitted_distance_m: number | null
  calculated_average_apparent_speed_mph: number | null
  actual_duration_s: number | null
  write_failures: number
  observed_result: string | null
  qc_status: string | null
  notes: string
}
export interface DriveTestingHistoryResponse { ok: boolean; experiments: DriveTestingHistoryRow[] }

export interface DriveTestingObservation {
  result: string
  checked_at?: string
  delay_before_result_s?: number
  displayed_distance?: number
  displayed_duration_s?: number
  displayed_average_speed_mph?: number
  displayed_maximum_speed_mph?: number
  drive_detection_enabled?: boolean
  arity_sharing_enabled?: boolean
  location_permission_always?: boolean
  motion_fitness_enabled?: boolean
  background_app_refresh_enabled?: boolean
  low_power_mode_disabled?: boolean
  battery_above_10_percent?: boolean
  strong_cellular_signal?: boolean
  connectivity?: 'wifi' | 'cellular' | 'both' | 'unknown'
  phone_state?: 'stationary' | 'physically_moving' | 'unknown'
  screen_state?: 'locked' | 'unlocked' | 'unknown'
  application_state?: 'foreground' | 'background' | 'not_checked' | 'unknown'
  test_performed_by_passenger?: boolean
  notes?: string
  screenshot_filename?: string
  interpretation?: string
}

export interface DriveTestingQueueEntry { experiment_id: string; repeats: number; reset_gps_after: boolean; delay_after_s: number }
export interface DriveTestingQueueStatus { ok: boolean; state: string; current_index: number | null; current_experiment_id?: string; entries: DriveTestingQueueEntry[]; estimated_total_duration_s: number; last_error: string | null; requires_confirmation: boolean }
export interface DriveTestingComparison { ok: boolean; comparison: Record<string, unknown>[]; charts: { experiment_id: string; points: Record<string, unknown>[] }[]; outcome_counts: Record<string, number>; comparable_run_count: number; show_percentages: boolean; disclaimer: string }
export interface DriveTestingQuickTestResponse { ok: boolean; requires_confirmation: boolean; experiment?: DriveTestingExperiment; profile: DriveTestingProfile; calculated_duration_s: number }
