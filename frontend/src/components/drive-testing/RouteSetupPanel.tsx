import React, { useState } from 'react'
import { api, DriveRouteResponse, LatLon } from '../../api/client'
import { LabRouteState } from './types'
import { button, buttonRow, field, grid2, grid3, input, notice, section, sectionTitle } from './styles'

interface Props {
  selectedLocation: LatLon | null
  existingDriveRoute: DriveRouteResponse | null
  route: LabRouteState | null
  targetMph: number
  onRoute: (route: LabRouteState | null) => void
  onError: (message: string) => void
}

export default function RouteSetupPanel({ selectedLocation, existingDriveRoute, route, targetMph, onRoute, onError }: Props) {
  const [useCurrentStart, setUseCurrentStart] = useState(true)
  const [startAddress, setStartAddress] = useState('')
  const [destinationAddress, setDestinationAddress] = useState('')
  const [routeName, setRouteName] = useState('')
  const [minimumMiles, setMinimumMiles] = useState(0.6)
  const [roundTrip, setRoundTrip] = useState(false)
  const [busy, setBusy] = useState(false)
  const [start, setStart] = useState<LatLon | null>(null)
  const [destination, setDestination] = useState<LatLon | null>(null)

  const geocode = async (address: string, label: string) => {
    if (!address.trim()) throw new Error(`Enter a ${label} address.`)
    const result = await api.geocodeDriveAddress(address.trim())
    if (!result.results.length) throw new Error(result.message || `No ${label} match.`)
    return result.results[0]
  }
  const geocodeStart = async () => {
    try { setStart(useCurrentStart ? selectedLocation : await geocode(startAddress, 'start')) } catch (error: any) { onError(error.message) }
  }
  const geocodeDestination = async () => {
    try { setDestination(await geocode(destinationAddress, 'destination')) } catch (error: any) { onError(error.message) }
  }
  const generate = async () => {
    setBusy(true)
    try {
      const nextStart = useCurrentStart ? selectedLocation : (start ?? await geocode(startAddress, 'start'))
      if (!nextStart) throw new Error('Select a current map location or geocode a start address.')
      const nextDestination = destination ?? await geocode(destinationAddress, 'destination')
      const result = await api.buildDriveRoute(nextStart, nextDestination)
      let coordinates = result.coordinates
      let distance = result.distance_m
      let duration = result.osrm_duration_s
      if (roundTrip) {
        coordinates = [...coordinates, ...coordinates.slice(0, -1).reverse()]
        distance *= 2
        duration *= 2
      }
      setStart(nextStart); setDestination(nextDestination)
      onRoute({ coordinates, start: nextStart, destination: nextDestination, provider: result.provider, cached: result.cached, distance_m: distance, osrm_duration_s: duration, name: routeName.trim() || 'Road route' })
    } catch (error: any) { onError(error.message) } finally { setBusy(false) }
  }
  const useExisting = () => {
    if (!existingDriveRoute) { onError('No existing Drive Mode road route is available.'); return }
    onRoute({ coordinates: existingDriveRoute.coordinates, start: existingDriveRoute.coordinates[0], destination: existingDriveRoute.coordinates[existingDriveRoute.coordinates.length - 1], provider: existingDriveRoute.provider, cached: existingDriveRoute.cached, distance_m: existingDriveRoute.distance_m, osrm_duration_s: existingDriveRoute.osrm_duration_s, name: routeName.trim() || 'Existing Drive Mode route' })
  }
  const reverse = () => {
    if (!route) return
    onRoute({ ...route, coordinates: [...route.coordinates].reverse(), start: route.destination, destination: route.start })
  }
  const distanceMiles = (route?.distance_m ?? 0) / 1609.344
  const meets = distanceMiles + 0.0001 >= minimumMiles
  const approxDuration = targetMph > 0 ? distanceMiles / targetMph * 3600 : 0

  return (
    <>
      <section style={section}>
        <div style={sectionTitle}>Road Route Setup</div>
        <div style={grid2}>
          <label style={field}>Starting address<input style={input} disabled={useCurrentStart} value={startAddress} onChange={e => { setStartAddress(e.target.value); setStart(null) }} placeholder="Start address" /></label>
          <label style={field}>Destination address<input style={input} value={destinationAddress} onChange={e => { setDestinationAddress(e.target.value); setDestination(null) }} placeholder="Destination address" /></label>
          <label style={field}>Optional route name<input style={input} value={routeName} onChange={e => setRouteName(e.target.value)} placeholder="Experiment route" /></label>
          <label style={field}>Minimum desired test distance<select style={input} value={minimumMiles} onChange={e => setMinimumMiles(Number(e.target.value))}><option value={0.4}>0.4 mile</option><option value={0.5}>0.5 mile</option><option value={0.6}>0.6 mile</option><option value={1}>1.0 mile</option><option value={2}>2.0 miles</option></select></label>
        </div>
        <div style={{ ...buttonRow, marginTop: 10 }}>
          <label><input type="checkbox" checked={useCurrentStart} onChange={e => { setUseCurrentStart(e.target.checked); setStart(null) }} /> Use current selected location as start</label>
          <label><input type="checkbox" checked={roundTrip} onChange={e => setRoundTrip(e.target.checked)} /> Round trip / return to start</label>
        </div>
        <div style={{ ...buttonRow, marginTop: 12 }}>
          <button style={button()} onClick={geocodeStart}>Geocode Start</button>
          <button style={button()} onClick={geocodeDestination}>Geocode Destination</button>
          <button style={button('primary')} disabled={busy} onClick={generate}>{busy ? 'Generating...' : 'Generate Road Route'}</button>
          <button style={button()} disabled={!route} onClick={() => route && onRoute({ ...route })}>Preview Route</button>
          <button style={button()} disabled={!route} onClick={reverse}>Reverse Route</button>
          <button style={button()} disabled={!route} onClick={() => onRoute(null)}>Clear Route</button>
          <button style={button()} disabled={!existingDriveRoute} onClick={useExisting}>Use Existing Drive Mode Route</button>
          <button style={button()} disabled={!existingDriveRoute} onClick={useExisting}>Use Manually Selected Route</button>
        </div>
      </section>
      <section style={section}>
        <div style={sectionTitle}>Route Summary</div>
        {!route && <div style={notice('warning')}>Generate or reuse a road route before generating a profile.</div>}
        {route && <div style={grid3}>
          <Summary label="Start coordinates" value={`${route.start?.lat.toFixed(5)}, ${route.start?.lon.toFixed(5)}`} />
          <Summary label="Destination coordinates" value={`${route.destination?.lat.toFixed(5)}, ${route.destination?.lon.toFixed(5)}`} />
          <Summary label="Route provider" value={route.provider.toUpperCase()} />
          <Summary label="Cache" value={route.cached ? 'Cached' : 'Fresh'} />
          <Summary label="Route distance" value={`${distanceMiles.toFixed(3)} mi`} />
          <Summary label="OSRM duration" value={`${Math.round(route.osrm_duration_s / 60)} min`} />
          <Summary label="Coordinate count" value={String(route.coordinates.length)} />
          <Summary label="Approx. selected profile duration" value={`${Math.round(approxDuration)} s`} />
          <Summary label="Distance threshold" value={meets ? 'Meets threshold' : 'Too short'} />
        </div>}
      </section>
    </>
  )
}

function Summary({ label, value }: { label: string; value: string }) {
  return <div style={{ padding: 9, background: '#171a20', border: '1px solid #303640', borderRadius: 6 }}><div style={{ color: '#9aa3af', fontSize: 11 }}>{label}</div><div style={{ fontSize: 13, marginTop: 4, overflowWrap: 'anywhere' }}>{value}</div></div>
}
