import React from 'react'

export default function DriveTestingLauncher({ enabled, onOpen }: { enabled: boolean; onOpen: () => void }) {
  if (!enabled) return null
  return <div style={labLauncher}>
    <button style={driveTestingBtn} onClick={onOpen}>
      <span>Drive Testing Lab</span>
      <span style={{ color: '#f2b84b', fontSize: 10, fontWeight: 750 }}>EXPERIMENTAL</span>
    </button>
  </div>
}

const labLauncher: React.CSSProperties = { padding: '12px 16px', borderBottom: '1px solid #2a2a38' }
const driveTestingBtn: React.CSSProperties = { width: '100%', minHeight: 48, padding: '7px 10px', display: 'flex', flexDirection: 'column', alignItems: 'flex-start', justifyContent: 'center', gap: 3, background: '#20251f', border: '1px solid #59644d', borderRadius: 6, color: '#edf3e8', cursor: 'pointer', fontSize: 13, fontWeight: 650 }
