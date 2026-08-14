import React, { useState } from 'react'
import { api, DriveTestingLabStatus } from '../../api/client'
import { button, buttonRow, colors, grid2, notice, section, sectionTitle, statusPill } from './styles'

interface Props {
  status: DriveTestingLabStatus | null
  frontendExperimental: boolean
  frontendDriveTesting: boolean
  onRefresh: () => Promise<void>
  onError: (message: string) => void
}

export default function DeviceCheckPanel({ status, frontendExperimental, frontendDriveTesting, onRefresh, onError }: Props) {
  const [busy, setBusy] = useState('')
  const run = async (name: string, operation: () => Promise<unknown>) => {
    setBusy(name)
    try { await operation(); await onRefresh() } catch (error: any) { onError(error.message) } finally { setBusy('') }
  }
  const copy = async (value: string) => {
    try { await navigator.clipboard.writeText(value) } catch { onError(`Copy failed. Command: ${value}`) }
  }
  const initialize = async () => {
    await api.mountDdi()
    if (status?.device?.needs_tunnel) await api.startTunnel()
  }

  const flags = [
    ['Backend experimental enabled', status?.feature_flags.backend_experimental_enabled],
    ['Backend drive testing enabled', status?.feature_flags.backend_drive_testing_enabled],
    ['Frontend experimental enabled', frontendExperimental],
    ['Frontend drive testing enabled', frontendDriveTesting],
  ] as const

  return (
    <>
      <section style={section}>
        <div style={sectionTitle}>Feature Flags</div>
        <div style={grid2}>
          {flags.map(([label, enabled]) => (
            <div key={label} style={{ display: 'flex', justifyContent: 'space-between', gap: 8, padding: '8px 10px', background: colors.panel, border: `1px solid ${colors.border}`, borderRadius: 6, fontSize: 12 }}>
              <span>{label}</span><span style={statusPill(enabled ? colors.success : colors.danger)}>{enabled ? 'ENABLED' : 'DISABLED'}</span>
            </div>
          ))}
        </div>
      </section>

      <section style={section}>
        <div style={sectionTitle}>Device Readiness</div>
        <div style={grid2}>
          <Readout label="Backend reachable" value={status?.backend_reachable ? 'Yes' : 'No'} />
          <Readout label="pymobiledevice3 available" value={status?.pmd3_available ? 'Yes' : 'No'} />
          <Readout label="Device connected" value={status?.device_connected ? 'Yes' : 'No'} />
          <Readout label="Device name" value={status?.device?.name ?? 'Unavailable'} />
          <Readout label="UDID" value={status?.device?.udid_abbreviated ?? 'Unavailable'} />
          <Readout label="iOS version" value={status?.device?.ios_version ?? 'Unavailable'} />
          <Readout label="Tunnel required" value={status?.device?.needs_tunnel ? 'Yes' : status?.device ? 'No' : 'Unavailable'} />
          <Readout label="Tunnel active" value={status?.tunnel_active ? 'Yes' : 'No'} />
          <Readout label="RSD address available" value={status?.rsd_address_available ? 'Yes' : 'No'} />
          <Readout label="Device trust" value={status?.device_trusted == null ? 'Not exposed' : status.device_trusted ? 'Trusted' : 'Not trusted'} />
          <Readout label="DDI state" value={status?.ddi_mounted == null ? 'Not exposed' : status.ddi_mounted ? 'Mounted' : 'Not mounted'} />
        </div>
        <div style={{ ...buttonRow, marginTop: 12 }}>
          <button style={button()} onClick={onRefresh}>Refresh Device</button>
          <button style={button('primary')} disabled={!!busy} onClick={() => run('initialize', initialize)}>{busy === 'initialize' ? 'Initializing...' : 'Initialize Device'}</button>
          <button style={button()} disabled={!!busy} onClick={() => run('ddi', api.mountDdi)}>Mount Developer Disk Image</button>
          <button style={button()} disabled={!!busy || !status?.device?.needs_tunnel} onClick={() => run('tunnel', api.startTunnel)}>Start Tunnel</button>
          <button style={button()} onClick={onRefresh}>Run Readiness Check</button>
          <button style={button()} onClick={() => copy('python -m pymobiledevice3 usbmux list')}>Copy Detection Command</button>
          <button style={button()} onClick={() => copy('python -m pymobiledevice3 amfi reveal-developer-mode')}>Copy Developer Mode Command</button>
        </div>
      </section>

      <section style={section}>
        <div style={sectionTitle}>Readiness Result</div>
        {!status && <div style={notice('danger')}>Backend status has not loaded.</div>}
        {status && (
          <>
            <div style={{ marginBottom: 8 }}><span style={statusPill(status.readiness.overall === 'PASS' ? colors.success : status.readiness.overall === 'WARNING' ? colors.warning : colors.danger)}>{status.readiness.overall}</span></div>
            {status.readiness.checks.map(check => (
              <div key={check.name} style={{ display: 'grid', gridTemplateColumns: '85px 220px minmax(0,1fr)', gap: 8, padding: '6px 0', borderBottom: `1px solid ${colors.border}`, fontSize: 12 }}>
                <span style={{ color: check.status === 'PASS' ? colors.success : check.status === 'WARNING' ? colors.warning : colors.danger, fontWeight: 700 }}>{check.status}</span>
                <span>{check.name}</span><span style={{ color: colors.muted }}>{check.detail}</span>
              </div>
            ))}
          </>
        )}
      </section>
    </>
  )
}

function Readout({ label, value }: { label: string; value: string }) {
  return <div style={{ padding: '8px 10px', background: colors.panel, border: `1px solid ${colors.border}`, borderRadius: 6 }}><div style={{ color: colors.muted, fontSize: 11 }}>{label}</div><div style={{ marginTop: 3, fontSize: 13, overflowWrap: 'anywhere' }}>{value}</div></div>
}
