import React, { useState, useCallback } from 'react'
import { MapContainer, TileLayer, Marker, useMapEvents } from 'react-leaflet'
import L from 'leaflet'
import { api, LatLon, Favorite } from './api/client'
import DevicePanel from './components/DevicePanel'
import FavoritesList from './components/FavoritesList'
import UnplugModal from './components/UnplugModal'

const experimentalEnabled = import.meta.env.VITE_ENABLE_EXPERIMENTAL_FEATURES === '1'

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

  const setMsg = (s: string, isErr = false) => {
    setError(isErr ? s : '')
    setStatus(isErr ? '' : s)
  }

  const handlePick = useCallback((ll: LatLon) => {
    setPicked(ll)
    if (routeMode) setRouteWaypoints(prev => [...prev, ll])
  }, [routeMode])

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

  const handlePlayRoute = async () => {
    if (routeWaypoints.length < 2) { setMsg('Add at least 2 waypoints by clicking the map.', true); return }
    try {
      setMsg(`Playing route (${routeWaypoints.length} waypoints)â€¦`)
      await api.playRoute(routeWaypoints, 1.4)
      setMsg('Route complete.')
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
        {experimentalEnabled && (
        <div style={routeBox}>
          <button
            style={{ ...secondaryBtn, background: routeMode ? '#2a2a60' : '#1a1a26' }}
            onClick={() => { setRouteMode(!routeMode); setRouteWaypoints([]) }}
          >
            {routeMode ? `Route mode ON (${routeWaypoints.length} pts)` : 'Route Mode'}
          </button>
          {routeMode && routeWaypoints.length >= 2 && (
            <button style={primaryBtn} onClick={handlePlayRoute} disabled={!deviceReady}>
              â–¶ Play Route
            </button>
          )}
          {routeMode && (
            <button style={secondaryBtn} onClick={() => setRouteWaypoints([])}>
              Clear Waypoints
            </button>
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
const primaryBtn: React.CSSProperties = { padding: '9px 0', background: '#5b5bf6', border: 'none', borderRadius: 8, color: '#fff', cursor: 'pointer', fontWeight: 600, fontSize: 14 }
const secondaryBtn: React.CSSProperties = { padding: '9px 0', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 8, color: '#e8e8f0', cursor: 'pointer', fontSize: 13 }
const lockBtn: React.CSSProperties = { padding: '9px 0', background: '#1e1e3a', border: '1px solid #4040a0', borderRadius: 8, color: '#aaaaff', cursor: 'pointer', fontWeight: 600, fontSize: 13 }
const statusMsg: React.CSSProperties = { margin: 16, padding: '8px 12px', background: '#0f2010', borderRadius: 6, color: '#4ade80', fontSize: 12 }
const errMsg: React.CSSProperties = { margin: 16, padding: '8px 12px', background: '#1f0a0a', borderRadius: 6, color: '#f87171', fontSize: 12 }


