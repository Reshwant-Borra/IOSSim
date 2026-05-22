const BASE = '/api'

async function req<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    const err = await res.json().catch(() => ({ detail: res.statusText }))
    throw new Error(err.detail ?? err.message ?? res.statusText)
  }
  return res.json()
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
  pauseDrive: () => req<DriveStatus>('POST', '/location/drive/pause'),
  resumeDrive: () => req<DriveStatus>('POST', '/location/drive/resume'),
  stopDrive: (clear_location = false) =>
    req<DriveStatus>('POST', '/location/drive/stop', { clear_location }),
  driveStatus: () => req<DriveStatus>('GET', '/location/drive/status'),
  listFavorites: () => req<Favorite[]>('GET', '/favorites'),
  addFavorite: (name: string, lat: number, lon: number, note?: string) =>
    req<Favorite>('POST', '/favorites', { name, lat, lon, note }),
  deleteFavorite: (id: number) => req<OkMsg>('DELETE', `/favorites/${id}`),
}

export interface LatLon { lat: number; lon: number }
export interface OkMsg { ok: boolean; message?: string }
export interface TunnelResult { ok: boolean; address?: string; port?: number; message?: string }
export interface Favorite { id: number; name: string; lat: number; lon: number; note: string }

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
