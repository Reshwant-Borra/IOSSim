import React from 'react'

interface Props {
  onDone: () => void
  onCancel: () => void
}

/**
 * Walk the user through the GhostMe "lock-and-unplug" trick:
 * set location → disable Developer Mode → unplug USB → location persists ~12h.
 */
export default function UnplugModal({ onDone, onCancel }: Props) {
  const steps = [
    { icon: '📍', text: 'Your location has been set on the iPhone.' },
    { icon: '📱', text: 'On your iPhone: Settings → Privacy & Security → Developer Mode' },
    { icon: '🔴', text: 'Toggle Developer Mode OFF and confirm the restart prompt.' },
    { icon: '🔌', text: 'Wait for the phone to restart, then unplug the USB cable.' },
    { icon: '⏳', text: 'Your spoofed location will persist for ~12 hours (until next reboot).' },
  ]

  return (
    <div style={overlay}>
      <div style={modal}>
        <div style={heading}>Lock & Unplug</div>
        <p style={sub}>Follow these steps to keep the location after unplugging:</p>

        <ol style={list}>
          {steps.map((s, i) => (
            <li key={i} style={stepItem}>
              <span style={icon}>{s.icon}</span>
              <span>{s.text}</span>
            </li>
          ))}
        </ol>

        <div style={note}>
          <strong>Note:</strong> Location clears on reboot. Re-connect USB and repeat to refresh.
          You must re-enable Developer Mode before using this tool again.
        </div>

        <div style={btnRow}>
          <button style={cancelBtn} onClick={onCancel}>Cancel</button>
          <button style={doneBtn} onClick={onDone}>Done — I've done the steps</button>
        </div>
      </div>
    </div>
  )
}

const overlay: React.CSSProperties = { position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.75)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000 }
const modal: React.CSSProperties = { background: '#16161f', border: '1px solid #2a2a40', borderRadius: 12, padding: 28, maxWidth: 460, width: '90%' }
const heading: React.CSSProperties = { fontSize: 18, fontWeight: 700, marginBottom: 8 }
const sub: React.CSSProperties = { color: '#8888aa', fontSize: 13, marginBottom: 20 }
const list: React.CSSProperties = { listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 14 }
const stepItem: React.CSSProperties = { display: 'flex', gap: 12, alignItems: 'flex-start', fontSize: 14, lineHeight: 1.5 }
const icon: React.CSSProperties = { fontSize: 18, flexShrink: 0 }
const note: React.CSSProperties = { background: '#1e1e2e', borderRadius: 8, padding: '12px 14px', fontSize: 12, color: '#aaa', marginTop: 20, lineHeight: 1.6 }
const btnRow: React.CSSProperties = { display: 'flex', gap: 10, marginTop: 20 }
const cancelBtn: React.CSSProperties = { flex: 1, padding: '9px 0', background: '#2a2a40', border: 'none', borderRadius: 8, color: '#e8e8f0', cursor: 'pointer', fontSize: 14 }
const doneBtn: React.CSSProperties = { flex: 2, padding: '9px 0', background: '#5b5bf6', border: 'none', borderRadius: 8, color: '#fff', cursor: 'pointer', fontSize: 14, fontWeight: 600 }
