import React, { useState, useCallback } from 'react'
import { MapContainer, TileLayer, Marker, Polyline, CircleMarker, useMapEvents } from 'react-leaflet'
import { useEffect } from 'react'
import L from 'leaflet'
import { api, LatLon, DriveStatus } from './api/client'
import DevicePanel from './components/DevicePanel'
import FavoritesList from './components/FavoritesList'
import UnplugModal from './components/UnplugModal'

const experimentalEnabled = import.meta.env.VITE_ENABLE_EXPERIMENTAL_FEATURES === '1'
const driveModeEnabled = import.meta.env.VITE_ENABLE_DRIVE_MODE !== '0'

// Fix default marker icon in Vite builds
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

export default function App() {
  const [deviceReady, setDeviceReady] = useState(false)
  const [picked, setPicked] = useState<LatLon | null>(null)
  const [status, setStatus] = useState('')
  const [error, setError] = useState('')
  const [showUnplug, setShowUnplug] = useState(false)
  const [routeMode, setRouteMode] = useState(false)
  const [routeWaypoints, setRouteWaypoints] = useState<LatLon[]>([])
  const [driveSpeed, setDriveSpeed] = useState(8.3)
  const [stayAtEnd, setStayAtEnd] = useState(true)
  const [driveStatus, setDriveStatus] = useState<DriveStatus | null>(null)

  const driveActive = driveStatus?.state === 'starting' || driveStatus?.state === 'driving' || driveStatus?.state === 'paused'
  const drivePaused = driveStatus?.state === 'paused'

  const setMsg = (s: string, isErr = false) => {
    setError(isErr ? s : '')
    setStatus(isErr ? '' : s)
  }

  const handlePick = useCallback((ll: LatLon) => {
    if (driveActive) {
      setMsg('Stop Drive Mode before editing waypoints.', true)
      return
    }
    setPicked(ll)
    if (routeMode) setRouteWaypoints(prev => [...prev, ll])
  }, [driveActive, routeMode])

  useEffect(() => {
    if (!driveModeEnabled) return
    const id = window.setInterval(async () => {
      try {
        const next = await api.driveStatus()
        if (next.state !== 'idle' || driveStatus?.state !== 'idle') setDriveStatus(next)
      } catch {
        // Backend experimental flag may be off while frontend flag is on.
      }
    }, 1500)
    return () => window.clearInterval(id)
  }, [driveStatus?.state])

  const handleSet = async () => {
    if (!picked) { setMsg('Click the map to pick a location.', true); return }
    try {
      setMsg('Setting locationâ€¦')
      await api.setLocation(picked.lat, picked.lon)
      setMsg(`Location set: ${picked.lat.toFixed(5)}, ${picked.lon.toFixed(5)}`)
    } catch (e: any) { setMsg(e.message, true) }
  }

  const handleClear = async () => {
    try {
      setMsg('Resetting to real GPSâ€¦')
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

  const handleStartDrive = async () => {
    if (routeWaypoints.length < 2) { setMsg('Add at least 2 waypoints by clicking the map.', true); return }
    try {
      setMsg(`Starting drive (${routeWaypoints.length} waypoints)â€¦`)
      const result = await api.startDrive(routeWaypoints, driveSpeed, 2.0, stayAtEnd)
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

  return (
    <div style={root}>
      {/* Sidebar */}
      <div style={sidebar}>
        <div style={logo}>ðŸ“ iOS Location Sim</div>

        <DevicePanel onReady={rdy => setDeviceReady(rdy)} />

        <FavoritesList onSelect={handleFavSelect} currentLoc={picked} />

        {/* Coord display */}
        {picked && (
          <div style={coordBox}>
            <span style={{ color: '#8888aa', fontSize: 11 }}>SELECTED</span>
            <div style={{ fontFamily: 'monospace', fontSize: 13, marginTop: 4 }}>
              {picked.lat.toFixed(6)}, {picked.lon.toFixed(6)}
            </div>
          </div>
        )}

        {/* Actions */}
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

        {/* Route mode */}
        {driveModeEnabled && (
        <div style={routeBox}>
          <button
            style={{ ...secondaryBtn, background: routeMode ? '#2a2a60' : '#1a1a26' }}
            onClick={() => { setRouteMode(!routeMode); setRouteWaypoints([]) }}
            disabled={driveActive}
          >
            {routeMode ? `Drive waypoints (${routeWaypoints.length})` : 'Drive Mode'}
          </button>
          {routeMode && (
            <>
              <label style={fieldLabel}>
                Speed
                <select
                  style={select}
                  value={driveSpeed}
                  disabled={driveActive}
                  onChange={e => setDriveSpeed(Number(e.target.value))}
                >
                  <option value={1.4}>Walking</option>
                  <option value={3.5}>Jogging</option>
                  <option value={5.5}>Cycling</option>
                  <option value={8.3}>City driving</option>
                  <option value={27.8}>Highway</option>
                </select>
              </label>
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
          {routeMode && routeWaypoints.length >= 2 && !driveActive && (
            <button style={primaryBtn} onClick={handleStartDrive} disabled={!deviceReady}>
              Start Drive
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
            <button style={secondaryBtn} onClick={() => setRouteWaypoints([])} disabled={routeWaypoints.length === 0}>
              Clear Waypoints
            </button>
          )}
          {routeMode && driveStatus && driveStatus.state !== 'idle' && (
            <div style={driveReadout}>
              <div>{driveStatus.state.toUpperCase()} - {Math.round(driveStatus.progress * 100)}%</div>
              <div>{Math.round(driveStatus.distance_remaining_m)} m left</div>
              {driveStatus.eta_s !== null && <div>ETA {Math.round(driveStatus.eta_s)} s</div>}
            </div>
          )}
        </div>
        )}

        {status && <div style={statusMsg}>{status}</div>}
        {error && <div style={errMsg}>{error}</div>}
      </div>

      {/* Map */}
      <div style={mapWrap}>
        <MapContainer center={[37.7749, -122.4194]} zoom={13} style={{ width: '100%', height: '100%' }}>
          <TileLayer
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            attribution='Â© OpenStreetMap contributors'
          />
          <MapClickHandler onPick={handlePick} />
          {picked && !routeMode && <Marker position={[picked.lat, picked.lon]} />}
          {routeMode && routeWaypoints.map((wp, i) => (
            <Marker key={i} position={[wp.lat, wp.lon]} />
          ))}
          {routeMode && routeWaypoints.length >= 2 && (
            <Polyline positions={routeWaypoints.map(wp => [wp.lat, wp.lon] as [number, number])} pathOptions={{ color: '#0f766e', weight: 4 }} />
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
          onDone={() => { setShowUnplug(false); setMsg('Done! Location locked.') }}
          onCancel={() => setShowUnplug(false)}
        />
      )}
    </div>
  )
}

const root: React.CSSProperties = { display: 'flex', height: '100vh', overflow: 'hidden' }
const sidebar: React.CSSProperties = { width: 280, background: '#13131a', display: 'flex', flexDirection: 'column', overflowY: 'auto', flexShrink: 0 }
const logo: React.CSSProperties = { padding: '18px 16px 14px', fontWeight: 800, fontSize: 16, borderBottom: '1px solid #2a2a38' }
const mapWrap: React.CSSProperties = { flex: 1, position: 'relative' }
const coordBox: React.CSSProperties = { padding: '10px 16px', borderBottom: '1px solid #2a2a38' }
const actions: React.CSSProperties = { padding: 16, display: 'flex', flexDirection: 'column', gap: 8, borderBottom: '1px solid #2a2a38' }
const routeBox: React.CSSProperties = { padding: '12px 16px', display: 'flex', flexDirection: 'column', gap: 8, borderBottom: '1px solid #2a2a38' }
const fieldLabel: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 6, color: '#b8b8c8', fontSize: 12 }
const select: React.CSSProperties = { padding: '8px', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 6, color: '#e8e8f0' }
const checkRow: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 8, color: '#d8d8e4', fontSize: 13 }
const driveControls: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }
const driveReadout: React.CSSProperties = { padding: '8px 10px', background: '#0c1f1d', border: '1px solid #164e46', borderRadius: 6, color: '#99f6e4', fontSize: 12, display: 'flex', flexDirection: 'column', gap: 3 }
const primaryBtn: React.CSSProperties = { padding: '9px 0', background: '#5b5bf6', border: 'none', borderRadius: 8, color: '#fff', cursor: 'pointer', fontWeight: 600, fontSize: 14 }
const secondaryBtn: React.CSSProperties = { padding: '9px 0', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 8, color: '#e8e8f0', cursor: 'pointer', fontSize: 13 }
const lockBtn: React.CSSProperties = { padding: '9px 0', background: '#1e1e3a', border: '1px solid #4040a0', borderRadius: 8, color: '#aaaaff', cursor: 'pointer', fontWeight: 600, fontSize: 13 }
const statusMsg: React.CSSProperties = { margin: 16, padding: '8px 12px', background: '#0f2010', borderRadius: 6, color: '#4ade80', fontSize: 12 }
const errMsg: React.CSSProperties = { margin: 16, padding: '8px 12px', background: '#1f0a0a', borderRadius: 6, color: '#f87171', fontSize: 12 }


