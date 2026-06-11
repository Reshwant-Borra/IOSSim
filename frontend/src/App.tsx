import React, { useCallback, useEffect, useState } from 'react'
import { MapContainer, TileLayer, Marker, Polyline, CircleMarker, useMapEvents } from 'react-leaflet'
import L from 'leaflet'
import { api, LatLon, DriveRouteResponse, DriveStatus, GeocodeResult } from './api/client'
import DevicePanel from './components/DevicePanel'
import FavoritesList from './components/FavoritesList'
import UnplugModal from './components/UnplugModal'

const experimentalEnabled = import.meta.env.VITE_ENABLE_EXPERIMENTAL_FEATURES === '1'
const driveModeEnabled = true

const speedPresets = {
  walking: 3,
  city: 25,
  highway: 60,
  custom: 25,
}

type SpeedPreset = keyof typeof speedPresets

delete (L.Icon.Default.prototype as any)._getIconUrl
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png',
  iconUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png',
  shadowUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png',
})

function MapClickHandler({ onPick }: { onPick: (ll: LatLon) => void }) {
  useMapEvents({ click: e => onPick({ lat: e.latlng.lat, lon: e.latlng.lng }) })
  return null
}

function mphToMps(mph: number): number {
  return Math.max(0.5, Math.min(35, mph * 0.44704))
}

function formatDistance(meters: number): string {
  if (meters >= 1609.344) return `${(meters / 1609.344).toFixed(2)} mi`
  return `${Math.round(meters)} m`
}

function formatDuration(seconds: number): string {
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.round((seconds % 3600) / 60)}m`
  if (seconds >= 60) return `${Math.round(seconds / 60)} min`
  return `${Math.round(seconds)} s`
}

export default function App() {
  const [deviceReady, setDeviceReady] = useState(false)
  const [picked, setPicked] = useState<LatLon | null>(null)
  const [status, setStatus] = useState('')
  const [error, setError] = useState('')
  const [showUnplug, setShowUnplug] = useState(false)
  const [routeMode, setRouteMode] = useState(false)
  const [routeWaypoints, setRouteWaypoints] = useState<LatLon[]>([])
  const [stayAtEnd, setStayAtEnd] = useState(true)
  const [driveStatus, setDriveStatus] = useState<DriveStatus | null>(null)
  const [startAddress, setStartAddress] = useState('')
  const [destinationAddress, setDestinationAddress] = useState('')
  const [useCurrentStart, setUseCurrentStart] = useState(true)
  const [roadRoute, setRoadRoute] = useState<DriveRouteResponse | null>(null)
  const [roadStart, setRoadStart] = useState<LatLon | null>(null)
  const [roadDestination, setRoadDestination] = useState<LatLon | null>(null)
  const [speedPreset, setSpeedPreset] = useState<SpeedPreset>('city')
  const [customMph, setCustomMph] = useState(25)

  const driveActive = driveStatus?.state === 'starting' || driveStatus?.state === 'driving' || driveStatus?.state === 'paused'
  const drivePaused = driveStatus?.state === 'paused'
  const selectedMph = speedPreset === 'custom' ? customMph : speedPresets[speedPreset]
  const selectedSpeedMps = mphToMps(selectedMph)

  const setMsg = (s: string, isErr = false) => {
    setError(isErr ? s : '')
    setStatus(isErr ? '' : s)
  }

  const resetDriveDraft = () => {
    setRouteWaypoints([])
    setRoadRoute(null)
    setRoadStart(null)
    setRoadDestination(null)
  }

  const handlePick = useCallback((ll: LatLon) => {
    if (driveActive) {
      setMsg('Stop Drive Mode before editing the route.', true)
      return
    }
    setPicked(ll)
    if (routeMode) {
      setRoadRoute(null)
      setRoadStart(null)
      setRoadDestination(null)
      setRouteWaypoints(prev => [...prev, ll])
    }
  }, [driveActive, routeMode])

  useEffect(() => {
    if (!driveModeEnabled) return
    const id = window.setInterval(async () => {
      try {
        const next = await api.driveStatus()
        if (next.state !== 'idle' || driveStatus?.state !== 'idle') setDriveStatus(next)
      } catch {
        // ignore polling errors (backend may be starting up)
      }
    }, 1500)
    return () => window.clearInterval(id)
  }, [driveStatus?.state])

  const handleSet = async () => {
    if (!picked) { setMsg('Click the map to pick a location.', true); return }
    try {
      setMsg('Setting location...')
      await api.setLocation(picked.lat, picked.lon)
      setMsg(`Location set: ${picked.lat.toFixed(5)}, ${picked.lon.toFixed(5)}`)
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handleClear = async () => {
    try {
      setMsg('Resetting to real GPS...')
      await api.clearLocation()
      setMsg('Location reset to real GPS.')
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handleLockUnplug = async () => {
    if (!picked) { setMsg('Set a location first.', true); return }
    try {
      await api.setLocation(picked.lat, picked.lon)
      setShowUnplug(true)
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handleFavSelect = (loc: LatLon) => {
    setPicked(loc)
  }

  const firstGeocodeResult = async (address: string, label: string): Promise<GeocodeResult> => {
    const result = await api.geocodeDriveAddress(address)
    if (!result.results.length) throw new Error(result.message || `No match for ${label}.`)
    return result.results[0]
  }

  const handleGenerateRoadRoute = async () => {
    if (driveActive) { setMsg('Stop Drive Mode before generating a new route.', true); return }
    if (!destinationAddress.trim()) { setMsg('Enter a destination address.', true); return }
    if (!useCurrentStart && !startAddress.trim()) { setMsg('Enter a start address.', true); return }

    try {
      setMsg('Generating road route...')
      const start = useCurrentStart
        ? (driveStatus?.current_location ?? picked)
        : await firstGeocodeResult(startAddress, 'start address')
      if (!start) {
        setMsg('Select a map point or enter a start address.', true)
        return
      }
      const destination = await firstGeocodeResult(destinationAddress, 'destination address')
      const route = await api.buildDriveRoute(start, destination)
      setRoadStart(start)
      setRoadDestination(destination)
      setRoadRoute(route)
      setRouteWaypoints([])
      setMsg(`Route ready: ${formatDistance(route.distance_m)}, ETA ${formatDuration(route.distance_m / selectedSpeedMps)} at ${selectedMph} mph.`)
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handleStartDrive = async () => {
    const coordinates = roadRoute?.coordinates ?? routeWaypoints
    if (coordinates.length < 2) { setMsg('Generate a route or add at least 2 map waypoints.', true); return }
    try {
      setMsg(`Starting drive at ${selectedMph} mph...`)
      const result = roadRoute
        ? await api.startRoadRoute(coordinates, selectedSpeedMps, 2.0, stayAtEnd)
        : await api.startDrive(coordinates, selectedSpeedMps, 2.0, stayAtEnd)
      setDriveStatus(result)
      setMsg('Drive Mode started.')
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handlePauseDrive = async () => {
    try {
      const result = await api.pauseDrive()
      setDriveStatus(result)
      setMsg('Drive paused.')
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handleResumeDrive = async () => {
    try {
      const result = await api.resumeDrive()
      setDriveStatus(result)
      setMsg('Drive resumed.')
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handleStopDrive = async () => {
    try {
      const result = await api.stopDrive(false)
      setDriveStatus(result)
      setMsg('Drive stopped.')
    } catch (e: any) { setMsg(e.message, true) }
  }

  const previewCoordinates = roadRoute?.coordinates ?? routeWaypoints
  const canStartDrive = previewCoordinates.length >= 2 && !driveActive

  return (
    <div style={root}>
      <div style={sidebar}>
        <div style={logo}>iOS Location Sim</div>

        <DevicePanel onReady={rdy => setDeviceReady(rdy)} />

        <FavoritesList onSelect={handleFavSelect} currentLoc={picked} />

        {picked && (
          <div style={coordBox}>
            <span style={{ color: '#8888aa', fontSize: 11 }}>SELECTED</span>
            <div style={{ fontFamily: 'monospace', fontSize: 13, marginTop: 4 }}>
              {picked.lat.toFixed(6)}, {picked.lon.toFixed(6)}
            </div>
          </div>
        )}

        <div style={actions}>
          <button style={primaryBtn} onClick={handleSet} disabled={!deviceReady || !picked}>
            Set Location
          </button>
          <button style={secondaryBtn} onClick={handleClear} disabled={!deviceReady}>
            Reset GPS
          </button>
          {experimentalEnabled && (
            <button style={lockBtn} onClick={handleLockUnplug} disabled={!deviceReady || !picked}>
              Lock & Unplug (Experimental)
            </button>
          )}
        </div>

        {driveModeEnabled && (
          <div style={routeBox}>
            <button
              style={{ ...secondaryBtn, background: routeMode ? '#2a2a60' : '#1a1a26' }}
              onClick={() => { setRouteMode(!routeMode); resetDriveDraft() }}
              disabled={driveActive}
            >
              {routeMode ? 'Drive Mode On' : 'Drive Mode'}
            </button>

            {routeMode && (
              <>
                <div style={warningBox}>
                  Nominatim and OSRM public endpoints are for light personal testing only.
                </div>

                <label style={checkRow}>
                  <input
                    type="checkbox"
                    checked={useCurrentStart}
                    disabled={driveActive}
                    onChange={e => setUseCurrentStart(e.target.checked)}
                  />
                  Use selected/current point as start
                </label>

                {!useCurrentStart && (
                  <label style={fieldLabel}>
                    Start address
                    <input
                      style={input}
                      value={startAddress}
                      disabled={driveActive}
                      onChange={e => setStartAddress(e.target.value)}
                      placeholder="123 Main St, City"
                    />
                  </label>
                )}

                <label style={fieldLabel}>
                  Destination address
                  <input
                    style={input}
                    value={destinationAddress}
                    disabled={driveActive}
                    onChange={e => setDestinationAddress(e.target.value)}
                    placeholder="Destination"
                  />
                </label>

                <button style={secondaryBtn} onClick={handleGenerateRoadRoute} disabled={driveActive}>
                  Generate Road Route
                </button>

                <label style={fieldLabel}>
                  Speed
                  <select
                    style={select}
                    value={speedPreset}
                    disabled={driveActive}
                    onChange={e => setSpeedPreset(e.target.value as SpeedPreset)}
                  >
                    <option value="walking">Walking - 3 mph</option>
                    <option value="city">City driving - 25 mph</option>
                    <option value="highway">Highway - 60 mph</option>
                    <option value="custom">Custom mph</option>
                  </select>
                </label>

                {speedPreset === 'custom' && (
                  <label style={fieldLabel}>
                    Custom mph
                    <input
                      style={input}
                      type="number"
                      min={1}
                      max={78}
                      step={1}
                      value={customMph}
                      disabled={driveActive}
                      onChange={e => setCustomMph(Number(e.target.value))}
                    />
                  </label>
                )}

                <label style={checkRow}>
                  <input
                    type="checkbox"
                    checked={stayAtEnd}
                    disabled={driveActive}
                    onChange={e => setStayAtEnd(e.target.checked)}
                  />
                  Stay at end
                </label>
              </>
            )}

            {routeMode && roadRoute && (
              <div style={routeSummary}>
                <div>Road route: {formatDistance(roadRoute.distance_m)}</div>
                <div>ETA at {selectedMph} mph: {formatDuration(roadRoute.distance_m / selectedSpeedMps)}</div>
                <div>{roadRoute.cached ? 'Cached' : 'Fresh'} OSRM route</div>
              </div>
            )}

            {routeMode && routeWaypoints.length >= 2 && !roadRoute && (
              <div style={routeSummary}>
                <div>Manual route: {routeWaypoints.length} waypoints</div>
                <div>Map clicks are straight-line segments.</div>
              </div>
            )}

            {routeMode && canStartDrive && (
              <button style={primaryBtn} onClick={handleStartDrive} disabled={!deviceReady}>
                {roadRoute ? 'Start Road Drive' : 'Start Manual Drive'}
              </button>
            )}

            {routeMode && driveActive && (
              <div style={driveControls}>
                <button style={secondaryBtn} onClick={drivePaused ? handleResumeDrive : handlePauseDrive}>
                  {drivePaused ? 'Resume' : 'Pause'}
                </button>
                <button style={secondaryBtn} onClick={handleStopDrive}>
                  Stop
                </button>
              </div>
            )}

            {routeMode && !driveActive && (
              <button style={secondaryBtn} onClick={resetDriveDraft} disabled={previewCoordinates.length === 0}>
                Clear Route
              </button>
            )}

            {routeMode && driveStatus && driveStatus.state !== 'idle' && (
              <div style={driveReadout}>
                <div>{driveStatus.state.toUpperCase()} - {Math.round(driveStatus.progress * 100)}%</div>
                <div>{Math.round(driveStatus.distance_remaining_m)} m left</div>
                <div>Speed {driveStatus.speed_mps?.toFixed(1) ?? selectedSpeedMps.toFixed(1)} m/s</div>
                {driveStatus.eta_s !== null && <div>ETA {formatDuration(driveStatus.eta_s)}</div>}
              </div>
            )}
          </div>
        )}

        {status && <div style={statusMsg}>{status}</div>}
        {error && <div style={errMsg}>{error}</div>}
      </div>

      <div style={mapWrap}>
        <MapContainer center={[37.7749, -122.4194]} zoom={13} style={{ width: '100%', height: '100%' }}>
          <TileLayer
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            attribution="OpenStreetMap contributors"
          />
          <MapClickHandler onPick={handlePick} />
          {picked && !routeMode && <Marker position={[picked.lat, picked.lon]} />}
          {routeMode && !roadRoute && routeWaypoints.map((wp, i) => (
            <Marker key={i} position={[wp.lat, wp.lon]} />
          ))}
          {routeMode && roadStart && <Marker position={[roadStart.lat, roadStart.lon]} />}
          {routeMode && roadDestination && <Marker position={[roadDestination.lat, roadDestination.lon]} />}
          {routeMode && previewCoordinates.length >= 2 && (
            <Polyline
              positions={previewCoordinates.map(wp => [wp.lat, wp.lon] as [number, number])}
              pathOptions={{ color: roadRoute ? '#2563eb' : '#0f766e', weight: 4 }}
            />
          )}
          {driveStatus?.current_location && (
            <CircleMarker
              center={[driveStatus.current_location.lat, driveStatus.current_location.lon]}
              radius={8}
              pathOptions={{ color: '#14b8a6', fillColor: '#14b8a6', fillOpacity: 0.85 }}
            />
          )}
        </MapContainer>
      </div>

      {showUnplug && (
        <UnplugModal
          onDone={() => { setShowUnplug(false); setMsg('Done. Location locked.') }}
          onCancel={() => setShowUnplug(false)}
        />
      )}
    </div>
  )
}

const root: React.CSSProperties = { display: 'flex', height: '100vh', overflow: 'hidden' }
const sidebar: React.CSSProperties = { width: 300, background: '#13131a', display: 'flex', flexDirection: 'column', overflowY: 'auto', flexShrink: 0 }
const logo: React.CSSProperties = { padding: '18px 16px 14px', fontWeight: 800, fontSize: 16, borderBottom: '1px solid #2a2a38' }
const mapWrap: React.CSSProperties = { flex: 1, position: 'relative' }
const coordBox: React.CSSProperties = { padding: '10px 16px', borderBottom: '1px solid #2a2a38' }
const actions: React.CSSProperties = { padding: 16, display: 'flex', flexDirection: 'column', gap: 8, borderBottom: '1px solid #2a2a38' }
const routeBox: React.CSSProperties = { padding: '12px 16px', display: 'flex', flexDirection: 'column', gap: 8, borderBottom: '1px solid #2a2a38' }
const fieldLabel: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 6, color: '#b8b8c8', fontSize: 12 }
const input: React.CSSProperties = { padding: '8px', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 6, color: '#e8e8f0', fontSize: 13 }
const select: React.CSSProperties = { padding: '8px', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 6, color: '#e8e8f0' }
const checkRow: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 8, color: '#d8d8e4', fontSize: 13 }
const warningBox: React.CSSProperties = { padding: '8px 10px', background: '#221b0f', border: '1px solid #5f4515', borderRadius: 6, color: '#facc15', fontSize: 12, lineHeight: 1.35 }
const routeSummary: React.CSSProperties = { padding: '8px 10px', background: '#101827', border: '1px solid #263652', borderRadius: 6, color: '#bfdbfe', fontSize: 12, display: 'flex', flexDirection: 'column', gap: 3 }
const driveControls: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }
const driveReadout: React.CSSProperties = { padding: '8px 10px', background: '#0c1f1d', border: '1px solid #164e46', borderRadius: 6, color: '#99f6e4', fontSize: 12, display: 'flex', flexDirection: 'column', gap: 3 }
const primaryBtn: React.CSSProperties = { padding: '9px 0', background: '#5b5bf6', border: 'none', borderRadius: 8, color: '#fff', cursor: 'pointer', fontWeight: 600, fontSize: 14 }
const secondaryBtn: React.CSSProperties = { padding: '9px 0', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 8, color: '#e8e8f0', cursor: 'pointer', fontSize: 13 }
const lockBtn: React.CSSProperties = { padding: '9px 0', background: '#1e1e3a', border: '1px solid #4040a0', borderRadius: 8, color: '#aaaaff', cursor: 'pointer', fontWeight: 600, fontSize: 13 }
const statusMsg: React.CSSProperties = { margin: 16, padding: '8px 12px', background: '#0f2010', borderRadius: 6, color: '#4ade80', fontSize: 12 }
const errMsg: React.CSSProperties = { margin: 16, padding: '8px 12px', background: '#1f0a0a', borderRadius: 6, color: '#f87171', fontSize: 12 }
