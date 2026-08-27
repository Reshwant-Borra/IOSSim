import React from 'react'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App'
import { api } from './api/client'

const leafletMock = vi.hoisted(() => ({
  mapEvents: {} as Record<string, (event: any) => void>,
  flyTo: vi.fn(),
}))

vi.mock('leaflet', () => ({
  default: {
    Icon: {
      Default: {
        prototype: {},
        mergeOptions: vi.fn(),
      },
    },
  },
}))

vi.mock('react-leaflet', () => ({
  MapContainer: ({ children }: { children: React.ReactNode }) => <div data-testid="map">{children}</div>,
  TileLayer: () => null,
  Marker: ({ position }: { position: [number, number] }) => <div data-testid="marker">{position.join(',')}</div>,
  Polyline: () => null,
  CircleMarker: () => null,
  useMapEvents: (events: Record<string, (event: any) => void>) => {
    leafletMock.mapEvents = events
    return null
  },
  useMap: () => ({
    flyTo: leafletMock.flyTo,
    getZoom: () => 13,
  }),
}))

vi.mock('./components/DevicePanel', () => ({
  default: ({ onReady, onConnectionChange }: { onReady: (ready: boolean) => void; onConnectionChange: (mode: string, udid: string) => void }) => {
    React.useEffect(() => {
      onReady(true)
      onConnectionChange('wireless', 'TEST-UDID')
    }, [])
    return <div>Wireless Ready</div>
  },
}))

vi.mock('./components/FavoritesList', () => ({
  default: ({ onSelect }: { onSelect: (loc: { lat: number; lon: number }, favorite?: { name: string }) => void }) => (
    <button onClick={() => onSelect({ lat: 40.758, lon: -73.9855 }, { name: 'Times Favorite' })}>Pick Favorite</button>
  ),
}))

vi.mock('./components/drive-testing/DriveTestingLauncher', () => ({ default: () => null }))
vi.mock('./components/wireless-testing/WirelessTestingLauncher', () => ({ default: () => null }))
vi.mock('./components/drive-testing/DriveTestingLab', () => ({ default: () => null }))
vi.mock('./components/wireless-testing/WirelessTestingLab', () => ({ default: () => null }))
vi.mock('./components/UnplugModal', () => ({ default: () => null }))

beforeEach(() => {
  leafletMock.flyTo.mockClear()
  leafletMock.mapEvents = {}
  vi.spyOn(api, 'driveStatus').mockResolvedValue({
    ok: true,
    session_id: null,
    state: 'idle',
    current_location: null,
    speed_mps: null,
    elapsed_s: 0,
    eta_s: null,
    progress: 0,
    total_distance_m: 0,
    distance_remaining_m: 0,
    stay_at_end: true,
    message: '',
  })
  vi.spyOn(api, 'searchLocations').mockResolvedValue({
    ok: true,
    provider: 'nominatim',
    cached: false,
    results: [{
      display_name: 'Tampa International Airport, Tampa, Florida, United States',
      lat: 27.97547,
      lon: -82.53325,
      primary_label: 'Tampa International Airport',
      secondary_label: 'Tampa, Florida, United States',
      type: 'aerodrome',
    }],
    message: '',
  })
  vi.spyOn(api, 'setLocation').mockResolvedValue({ ok: true, message: 'set' })
})

afterEach(() => {
  vi.restoreAllMocks()
})

async function searchAndSelect() {
  render(<App />)
  const input = screen.getByLabelText('Search for a place or address')
  fireEvent.change(input, { target: { value: 'Tampa International Airport' } })
  await act(async () => { await new Promise(resolve => window.setTimeout(resolve, 540)) })
  fireEvent.click(await screen.findByText('Tampa International Airport'))
}

describe('App location search integration', () => {
  it('search result updates picked, selected panel, marker, fly-to, and Set Location transport inputs', async () => {
    await searchAndSelect()

    expect(screen.getByText('SELECTED LOCATION')).toBeInTheDocument()
    expect(screen.getByText('Tampa, Florida, United States')).toBeInTheDocument()
    expect(screen.getByTestId('marker')).toHaveTextContent('27.97547,-82.53325')
    await waitFor(() => expect(leafletMock.flyTo).toHaveBeenCalledWith([27.97547, -82.53325], 15, expect.any(Object)))

    fireEvent.click(screen.getByText('Set Location'))
    await waitFor(() => expect(api.setLocation).toHaveBeenCalledWith(27.97547, -82.53325, 'wireless', 'TEST-UDID'))
  })

  it('favorite selection updates picked and recenters the map', async () => {
    render(<App />)
    fireEvent.click(screen.getByText('Pick Favorite'))
    expect(screen.getByText('Times Favorite')).toBeInTheDocument()
    expect(screen.getByTestId('marker')).toHaveTextContent('40.758,-73.9855')
    await waitFor(() => expect(leafletMock.flyTo).toHaveBeenCalledWith([40.758, -73.9855], 15, expect.any(Object)))
  })

  it('manual map click still updates picked and clears stale search labels', async () => {
    await searchAndSelect()
    act(() => {
      leafletMock.mapEvents.click({ latlng: { lat: 28.1, lng: -82.2 } })
    })
    expect(screen.queryByText('Tampa International Airport')).not.toBeInTheDocument()
    expect(screen.getByText('28.100000, -82.200000')).toBeInTheDocument()
    fireEvent.click(screen.getByText('Set Location'))
    await waitFor(() => expect(api.setLocation).toHaveBeenLastCalledWith(28.1, -82.2, 'wireless', 'TEST-UDID'))
  })

  it('blocks search selection while Drive Mode is active', async () => {
    vi.mocked(api.driveStatus).mockResolvedValue({
      ok: true,
      session_id: 'drive',
      state: 'driving',
      current_location: null,
      speed_mps: null,
      elapsed_s: 0,
      eta_s: null,
      progress: 0,
      total_distance_m: 0,
      distance_remaining_m: 0,
      stay_at_end: true,
      message: '',
    })
    render(<App />)
    await act(async () => { await new Promise(resolve => window.setTimeout(resolve, 1600)) })
    const input = screen.getByLabelText('Search for a place or address')
    fireEvent.change(input, { target: { value: 'Tampa International Airport' } })
    await act(async () => { await new Promise(resolve => window.setTimeout(resolve, 540)) })
    fireEvent.click(await screen.findByText('Tampa International Airport'))
    expect(await screen.findByText('Stop Drive Mode before selecting a new location.')).toBeInTheDocument()
    expect(screen.queryByTestId('marker')).not.toBeInTheDocument()
  })
})
