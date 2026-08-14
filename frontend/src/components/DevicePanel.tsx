import React, { useEffect, useState } from 'react'
import { api, DeviceStatus } from '../api/client'

interface Props {
  onReady: (needsTunnel: boolean) => void
}

type Step = 'idle' | 'mounting' | 'tunneling' | 'ready' | 'error'

export default function DevicePanel({ onReady }: Props) {
  const [status, setStatus] = useState<DeviceStatus | null>(null)
  const [step, setStep] = useState<Step>('idle')
  const [message, setMessage] = useState('')

  const refresh = async () => {
    try {
      const s = await api.status()
      setStatus(s)
      if (s.device_connected && s.tunnel_active) {
        setStep('ready')
        onReady(true)
      } else if (s.device_connected && !s.device?.needs_tunnel) {
        setStep('ready')
        onReady(false)
      }
    } catch {
      setMessage('Backend not reachable — is uvicorn running?')
    }
  }

  useEffect(() => { refresh(); const t = setInterval(refresh, 3000); return () => clearInterval(t) }, [])

  const setup = async () => {
    if (!status?.device_connected) { setMessage('Connect your iPhone via USB first.'); return }
    try {
      setStep('mounting')
      setMessage('Mounting Developer Disk Image…')
      await api.mountDdi()

      if (status.device?.needs_tunnel) {
        setStep('tunneling')
        setMessage('Starting tunnel (needs admin privileges)…')
        await api.startTunnel()
      }

      setStep('ready')
      setMessage('')
      onReady(!!status.device?.needs_tunnel)
    } catch (e: any) {
      setStep('error')
      setMessage(e.message)
    }
  }

  const dot = (ok: boolean) => (
    <span style={{ color: ok ? '#4ade80' : '#f87171', marginRight: 6 }}>●</span>
  )

  return (
    <div style={panel}>
      <div style={title}>Device</div>

      <div style={row}>{dot(!!status?.pmd3_available)} pymobiledevice3</div>
      <div style={row}>{dot(!!status?.device_connected)}
        {status?.device ? `${status.device.name} — iOS ${status.device.ios_version}` : 'No device'}
      </div>
      {status?.device?.needs_tunnel && (
        <div style={row}>{dot(!!status?.tunnel_active)} Tunnel (iOS 17+)</div>
      )}

      {step !== 'ready' && (
        <button style={btn} onClick={setup} disabled={step === 'mounting' || step === 'tunneling'}>
          {step === 'mounting' ? 'Mounting DDI…' : step === 'tunneling' ? 'Starting tunnel…' : 'Initialize'}
        </button>
      )}
      {step === 'ready' && <div style={{ color: '#4ade80', marginTop: 8, fontSize: 13 }}>Ready</div>}
      {message && <div style={errMsg}>{message}</div>}
    </div>
  )
}

const panel: React.CSSProperties = { padding: '16px', borderBottom: '1px solid #2a2a38' }
const title: React.CSSProperties = { fontWeight: 700, marginBottom: 10, fontSize: 13, letterSpacing: '0.05em', textTransform: 'uppercase', color: '#8888aa' }
const row: React.CSSProperties = { fontSize: 13, marginBottom: 6, display: 'flex', alignItems: 'center' }
const btn: React.CSSProperties = { marginTop: 10, padding: '7px 14px', background: '#5b5bf6', border: 'none', borderRadius: 6, color: '#fff', cursor: 'pointer', fontSize: 13, fontWeight: 600, width: '100%' }
const errMsg: React.CSSProperties = { marginTop: 8, fontSize: 12, color: '#f87171', lineHeight: 1.4 }
