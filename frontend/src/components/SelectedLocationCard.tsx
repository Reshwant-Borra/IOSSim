import React from 'react'
import { LatLon } from '../api/client'

export interface SelectedLocationDetails {
  title?: string
  subtitle?: string
  source: 'search' | 'favorite' | 'manual'
}

interface Props {
  location: LatLon | null
  details: SelectedLocationDetails | null
}

export default function SelectedLocationCard({ location, details }: Props) {
  if (!location) return null
  const title = details?.title?.trim()
  const subtitle = details?.subtitle?.trim()

  return (
    <div style={card}>
      <span style={eyebrow}>SELECTED LOCATION</span>
      {title && <div style={titleStyle}>{title}</div>}
      {subtitle && subtitle !== title && <div style={subtitleStyle}>{subtitle}</div>}
      <div style={coords}>
        {location.lat.toFixed(6)}, {location.lon.toFixed(6)}
      </div>
    </div>
  )
}

const card: React.CSSProperties = { padding: '12px 16px', borderBottom: '1px solid #2a2a38', display: 'flex', flexDirection: 'column', gap: 5 }
const eyebrow: React.CSSProperties = { color: '#8888aa', fontSize: 11, fontWeight: 700, letterSpacing: '0.05em' }
const titleStyle: React.CSSProperties = { color: '#f4f4fb', fontSize: 14, fontWeight: 700, lineHeight: 1.25, overflowWrap: 'anywhere' }
const subtitleStyle: React.CSSProperties = { color: '#a7a7bd', fontSize: 12, lineHeight: 1.35, overflowWrap: 'anywhere' }
const coords: React.CSSProperties = { fontFamily: 'monospace', color: '#d8d8e4', fontSize: 13, marginTop: 2 }
