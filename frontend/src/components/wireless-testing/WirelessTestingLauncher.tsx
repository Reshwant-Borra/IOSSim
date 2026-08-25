import React from 'react'

export default function WirelessTestingLauncher({ enabled, onOpen }: { enabled: boolean; onOpen: () => void }) {
  if (!enabled) return null
  return <div style={launcher}>
    <button style={labButton} onClick={onOpen}>
      <span>Advanced Diagnostics</span>
      <span style={badge}>Persistent Tunnel Diagnostics</span>
    </button>
  </div>
}

const launcher: React.CSSProperties = { padding: '12px 16px', borderBottom: '1px solid #2a2a38' }
const labButton: React.CSSProperties = {
  width: '100%',
  minHeight: 50,
  padding: '7px 10px',
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'flex-start',
  justifyContent: 'center',
  gap: 3,
  background: '#162823',
  border: '1px solid #3a6d62',
  borderRadius: 6,
  color: '#edf8f4',
  cursor: 'pointer',
  fontSize: 13,
  fontWeight: 650,
}
const badge: React.CSSProperties = { color: '#f2b84b', fontSize: 10, fontWeight: 760 }
