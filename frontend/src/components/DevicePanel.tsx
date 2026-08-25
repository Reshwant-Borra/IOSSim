import React, { useEffect, useMemo, useState } from 'react'
import { api, ConnectionMode, DeviceStatus, WirelessLocationStatus, WirelessSavedDevice } from '../api/client'

interface Props {
  onReady: (ready: boolean) => void
  onConnectionChange: (mode: ConnectionMode, deviceUdid: string | null) => void
}

type Busy = 'setup' | 'verify' | 'connect' | 'wired' | 'remove' | null

export default function DevicePanel({ onReady, onConnectionChange }: Props) {
  const [status, setStatus] = useState<DeviceStatus | null>(null)
  const [wireless, setWireless] = useState<WirelessLocationStatus | null>(null)
  const [mode, setMode] = useState<ConnectionMode>('automatic')
  const [busy, setBusy] = useState<Busy>(null)
  const [setupUdid, setSetupUdid] = useState<string | null>(null)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')

  const selected = useMemo(() => {
    const devices = wireless?.devices ?? []
    return devices.find(device => device.selected) ?? devices.find(device => device.wireless_ready) ?? devices[0] ?? null
  }, [wireless])

  const wiredReady = !!status?.device_connected && (!status.device?.needs_tunnel || !!status.tunnel_active)
  const wirelessReady = !!selected?.wireless_ready || !!wireless?.session?.wireless_ready
  const ready = mode === 'usb' ? wiredReady : mode === 'wireless' ? wirelessReady : (wirelessReady || wiredReady)

  const refresh = async () => {
    try {
      const next = await api.status()
      setStatus(next)
      setWireless(next.wireless_location ?? null)
      const nextWireless = next.wireless_location
      const nextSelected = nextWireless?.devices.find(device => device.selected) ?? nextWireless?.devices.find(device => device.wireless_ready) ?? nextWireless?.devices[0] ?? null
      const nextMode = nextWireless?.connection_mode ?? mode
      setMode(nextMode)
      onReady(nextMode === 'usb' ? (!!next.device_connected && (!next.device?.needs_tunnel || !!next.tunnel_active)) : (!!nextSelected?.wireless_ready || !!nextWireless?.session?.wireless_ready || (!!next.device_connected && !next.device?.needs_tunnel && nextMode === 'automatic')))
      onConnectionChange(nextMode, nextSelected?.udid ?? nextWireless?.selected_udid ?? null)
      if (!error) setMessage(userMessage(nextWireless, nextSelected, next))
    } catch {
      setError('IOSSim backend is not reachable.')
      onReady(false)
    }
  }

  useEffect(() => {
    refresh()
    const timer = window.setInterval(refresh, 3000)
    return () => window.clearInterval(timer)
  }, [])

  useEffect(() => {
    onReady(ready)
    onConnectionChange(mode, selected?.udid ?? wireless?.selected_udid ?? null)
  }, [ready, mode, selected?.udid, wireless?.selected_udid])

  const run = async (nextBusy: Busy, action: () => Promise<any>, success?: string) => {
    setBusy(nextBusy)
    setError('')
    try {
      const result = await action()
      setMessage(success ?? result.message ?? '')
      if (result.device?.udid) setSetupUdid(result.device.udid)
      await refresh()
    } catch (e: any) {
      setError(e.message)
    } finally {
      setBusy(null)
    }
  }

  const changeMode = async (nextMode: ConnectionMode) => {
    setMode(nextMode)
    setError('')
    try {
      const result = await api.setWirelessConnectionMode(nextMode, selected?.udid ?? wireless?.selected_udid ?? null)
      setWireless(result)
      onConnectionChange(nextMode, result.selected_udid ?? selected?.udid ?? null)
    } catch (e: any) {
      setError(e.message)
    }
  }

  const setupDevice = () => run('setup', api.startWirelessSetup)
  const verifyUnplugged = () => {
    const udid = setupUdid ?? selected?.udid
    if (!udid) {
      setError('Start setup before verifying wireless access.')
      return
    }
    run('verify', () => api.verifyWirelessSetupUnplugged(udid), 'Your iPhone is ready.')
  }
  const connectSelected = () => {
    if (!selected?.udid) {
      setError('Add an iPhone before connecting wirelessly.')
      return
    }
    run('connect', () => api.connectWirelessLocation(selected.udid), 'Wireless Ready')
  }
  const removeSelected = () => {
    if (!selected?.udid) return
    run('remove', () => api.removeWirelessDevice(selected.udid), 'Saved iPhone removed.')
  }

  const initializeUsb = async () => {
    if (!status?.device_connected) {
      setError('Connect your iPhone with USB, unlock it, and Trust this Mac.')
      return
    }
    await run('wired', async () => {
      await api.mountDdi()
      if (status.device?.needs_tunnel) await api.startTunnel()
      return { ok: true, message: 'USB Ready' }
    })
  }

  return (
    <div style={panel}>
      <div style={headerRow}>
        <div style={title}>Devices</div>
        <span style={pill(ready ? '#22c55e' : '#ef4444')}>{ready ? readyLabel(mode, wirelessReady, wiredReady) : 'Setup Required'}</span>
      </div>

      <label style={field}>Connection
        <select style={select} value={mode} disabled={!!busy} onChange={e => changeMode(e.target.value as ConnectionMode)}>
          <option value="automatic">Automatic</option>
          <option value="wireless">Wireless</option>
          <option value="usb">USB</option>
        </select>
      </label>

      <div style={deviceList}>
        {(wireless?.devices ?? []).map(device => (
          <DeviceRow key={device.udid} device={device} />
        ))}
        {!(wireless?.devices ?? []).length && <div style={empty}>No saved iPhone yet.</div>}
      </div>

      {selected && (
        <div style={current}>
          <div style={{ fontWeight: 700 }}>{selected.name}</div>
          <div style={muted}>{selected.ios_version ? `iOS ${selected.ios_version}` : 'iPhone'} · {selected.status_label}</div>
          {wireless?.session?.simulation_enabled && (
            <div style={simLine}>Simulating {wireless.session.latitude?.toFixed(5)}, {wireless.session.longitude?.toFixed(5)}</div>
          )}
        </div>
      )}

      <div style={buttonGrid}>
        <button style={primaryBtn} disabled={!!busy} onClick={setupDevice}>
          {busy === 'setup' ? 'Preparing...' : 'Add iPhone'}
        </button>
        <button style={secondaryBtn} disabled={!!busy || !selected} onClick={connectSelected}>
          {busy === 'connect' ? 'Connecting...' : 'Connect Wireless'}
        </button>
      </div>

      {(setupUdid || selected?.setup_state === 'READY_TO_UNPLUG') && (
        <button style={secondaryBtn} disabled={!!busy} onClick={verifyUnplugged}>
          {busy === 'verify' ? 'Checking...' : "I've unplugged my iPhone"}
        </button>
      )}

      {mode === 'usb' && (
        <button style={secondaryBtn} disabled={!!busy} onClick={initializeUsb}>
          {busy === 'wired' ? 'Preparing USB...' : 'Prepare USB'}
        </button>
      )}

      {selected && (
        <button style={linkBtn} disabled={!!busy} onClick={removeSelected}>
          Remove saved iPhone
        </button>
      )}

      <div style={hint}>Wireless mode requires the Mac and iPhone to be reachable on the same local network.</div>
      {message && <div style={statusMsg}>{message}</div>}
      {error && <div style={errMsg}>{error}</div>}
    </div>
  )
}

function DeviceRow({ device }: { device: WirelessSavedDevice }) {
  const color = device.wireless_ready ? '#22c55e' : device.usb_visible ? '#60a5fa' : '#ef4444'
  return (
    <div style={row}>
      <span style={{ color, fontSize: 13 }}>●</span>
      <div style={{ minWidth: 0 }}>
        <div style={rowName}>{device.name}</div>
        <div style={muted}>{device.transport} · {device.status_label}</div>
      </div>
    </div>
  )
}

function userMessage(wireless: WirelessLocationStatus | null | undefined, selected: WirelessSavedDevice | null, status: DeviceStatus): string {
  if (wireless?.session?.simulation_enabled) return 'Simulating Location'
  if (selected?.wireless_ready) return 'Wireless Ready'
  if (selected && selected.wireless_setup_valid) return "Your iPhone isn't reachable over Wi-Fi."
  if (status.device_connected) return 'Click Add iPhone to enable wireless location.'
  return 'Connect your iPhone once to enable wireless mode.'
}

function readyLabel(mode: ConnectionMode, wirelessReady: boolean, wiredReady: boolean): string {
  if (mode === 'usb') return 'USB Ready'
  if (mode === 'wireless') return 'Wireless Ready'
  return wirelessReady ? 'Wireless Ready' : wiredReady ? 'USB Ready' : 'Ready'
}

const panel: React.CSSProperties = { padding: '16px', borderBottom: '1px solid #2a2a38', display: 'flex', flexDirection: 'column', gap: 10 }
const headerRow: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'center' }
const title: React.CSSProperties = { fontWeight: 700, fontSize: 13, letterSpacing: 0, textTransform: 'uppercase', color: '#a5adba' }
const field: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 6, color: '#b8b8c8', fontSize: 12 }
const select: React.CSSProperties = { padding: '8px', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 6, color: '#e8e8f0' }
const deviceList: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 8 }
const row: React.CSSProperties = { display: 'grid', gridTemplateColumns: '14px 1fr', gap: 8, alignItems: 'start', padding: '8px 0', borderBottom: '1px solid #242433' }
const rowName: React.CSSProperties = { color: '#f3f4f6', fontSize: 13, fontWeight: 650, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }
const muted: React.CSSProperties = { color: '#9ca3af', fontSize: 12, lineHeight: 1.35 }
const empty: React.CSSProperties = { color: '#9ca3af', fontSize: 13, padding: '8px 0' }
const current: React.CSSProperties = { padding: 10, background: '#111827', border: '1px solid #263244', borderRadius: 6, display: 'flex', flexDirection: 'column', gap: 3 }
const simLine: React.CSSProperties = { color: '#86efac', fontSize: 12, fontFamily: 'monospace' }
const buttonGrid: React.CSSProperties = { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }
const primaryBtn: React.CSSProperties = { padding: '8px 10px', background: '#5b5bf6', border: 'none', borderRadius: 6, color: '#fff', cursor: 'pointer', fontWeight: 650, fontSize: 13 }
const secondaryBtn: React.CSSProperties = { padding: '8px 10px', background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 6, color: '#e8e8f0', cursor: 'pointer', fontSize: 13 }
const linkBtn: React.CSSProperties = { padding: 0, background: 'transparent', border: 'none', color: '#a5b4fc', cursor: 'pointer', fontSize: 12, textAlign: 'left' }
const hint: React.CSSProperties = { color: '#9ca3af', fontSize: 12, lineHeight: 1.35 }
const statusMsg: React.CSSProperties = { padding: '8px 10px', background: '#0f2010', borderRadius: 6, color: '#4ade80', fontSize: 12 }
const errMsg: React.CSSProperties = { padding: '8px 10px', background: '#1f0a0a', borderRadius: 6, color: '#f87171', fontSize: 12, lineHeight: 1.4 }
const pill = (color: string): React.CSSProperties => ({ color, border: `1px solid ${color}`, borderRadius: 999, padding: '3px 7px', fontSize: 11, fontWeight: 700, whiteSpace: 'nowrap' })
