import { useEffect } from 'react'
import { useMap } from 'react-leaflet'
import { LatLon } from '../api/client'

export interface MapCameraTarget extends LatLon {
  zoom?: number
  nonce: number
}

export default function MapController({ target }: { target: MapCameraTarget | null }) {
  const map = useMap()

  useEffect(() => {
    if (!target) return
    const zoom = target.zoom ?? Math.max(map.getZoom(), 15)
    map.flyTo([target.lat, target.lon], zoom, { duration: 0.8 })
  }, [map, target])

  return null
}
