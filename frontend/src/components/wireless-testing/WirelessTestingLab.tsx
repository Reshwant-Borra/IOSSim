import React, { useCallback, useEffect, useMemo, useState } from 'react'
import {
  api,
  LatLon,
  WirelessCheckStatus,
  WirelessConnectionStatus,
  WirelessDiscovery,
  WirelessExperiment,
  WirelessManualConfirmation,
  WirelessOperationResponse,
  WirelessTestType,
  WirelessTestingStatus,
} from '../../api/client'
import {
  body,
  button,
  buttonRow,
  colors,
  content,
  field,
  grid2,
  grid3,
  header,
  headerTitle,
  input,
  metric,
  metricLabel,
  metricValue,
  notice,
  overlay,
  section,
  sectionTitle,
  stageButton,
  stagesNav,
  statusPill,
  table,
  tableWrap,
  td,
  th,
} from './styles'

type StageKey =
  | 'wired'
  | 'pairing'
  | 'unplug'
  | 'detect'
  | 'tunnel'
  | 'rsd'
  | 'set'
  | 'confirm'
  | 'reset'
  | 'verdict'

interface Props {
  selectedLocation: LatLon | null
  onClose: () => void
}

const EXPERIMENT_A: WirelessTestType = 'remove_cable_after_pairing'
const EXPERIMENT_B: WirelessTestType = 'fresh_cable_free_session'
const frontendExperimental = import.meta.env.VITE_ENABLE_EXPERIMENTAL_FEATURES === '1'
const frontendWireless = import.meta.env.VITE_ENABLE_WIRELESS_TESTING === '1'

const stages: Array<[StageKey, string]> = [
  ['wired', 'Wired Baseline'],
  ['pairing', 'Wireless Pairing Preparation'],
  ['unplug', 'Ready to Unplug'],
  ['detect', 'Detect Without USB'],
  ['tunnel', 'Persistent Tunnel Diagnostic'],
  ['rsd', 'Validate Fresh RSD'],
  ['set', 'Test Wireless Set Location'],
  ['confirm', 'Manual Device Confirmation'],
  ['reset', 'Test Wireless Reset GPS'],
  ['verdict', 'Final Verdict'],
]

export default function WirelessTestingLab({ selectedLocation, onClose }: Props) {
  const [activeStage, setActiveStage] = useState<StageKey>('wired')
  const [status, setStatus] = useState<WirelessTestingStatus | null>(null)
  const [experiment, setExperiment] = useState<WirelessExperiment | null>(null)
  const [experimentId, setExperimentId] = useState<string | null>(null)
  const [testType, setTestType] = useState<WirelessTestType>(EXPERIMENT_A)
  const [history, setHistory] = useState<WirelessExperiment[]>([])
  const [lastDiscovery, setLastDiscovery] = useState<WirelessDiscovery | null>(null)
  const [lastPairingStatus, setLastPairingStatus] = useState('UNKNOWN')
  const [lastRsd, setLastRsd] = useState<Record<string, unknown> | null>(null)
  const [report, setReport] = useState('')
  const [busy, setBusy] = useState('')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [useSelectedCoordinate, setUseSelectedCoordinate] = useState(true)
  const [manualLat, setManualLat] = useState('37.774900')
  const [manualLon, setManualLon] = useState('-122.419400')
  const [tunnelProtocol, setTunnelProtocol] = useState<'default' | 'tcp' | 'quic'>('default')
  const [locationConfirmation, setLocationConfirmation] = useState<WirelessManualConfirmation>('not_sure')
  const [resetConfirmation, setResetConfirmation] = useState<WirelessManualConfirmation>('not_sure')
  const [confirmationNotes, setConfirmationNotes] = useState('')

  const showError = (value: string) => { setError(value); setMessage('') }
  const showMessage = (value: string) => { setMessage(value); setError('') }

  const refresh = useCallback(async () => {
    try {
      const next = await api.wirelessTestingStatus()
      setStatus(next)
      setHistory(next.history ?? [])
      if (!experimentId && next.connection.experiment_id) {
        setExperimentId(next.connection.experiment_id)
        setTestType(next.connection.test_type ?? EXPERIMENT_A)
      }
      setError('')
    } catch (err: any) {
      showError(err.message)
    }
  }, [experimentId])

  useEffect(() => { refresh() }, [])

  const currentConnection = status?.connection
  const currentSummary = experiment?.summary ?? history.find(item => item.experiment_id === experimentId)?.summary ?? {}

  const selectedCoordinate = useMemo(() => {
    if (useSelectedCoordinate && selectedLocation) return selectedLocation
    return { lat: Number(manualLat), lon: Number(manualLon) }
  }, [manualLat, manualLon, selectedLocation, useSelectedCoordinate])

  const validCoordinate = Number.isFinite(selectedCoordinate.lat) && Number.isFinite(selectedCoordinate.lon) && selectedCoordinate.lat >= -90 && selectedCoordinate.lat <= 90 && selectedCoordinate.lon >= -180 && selectedCoordinate.lon <= 180

  const applyResult = (result: WirelessOperationResponse) => {
    if (result.experiment) setExperiment(result.experiment)
    if (result.status?.experiment_id) setExperimentId(result.status.experiment_id)
    if (result.status?.test_type) setTestType(result.status.test_type)
    if (result.discovery) setLastDiscovery(result.discovery)
    if (result.pairing_status) setLastPairingStatus(result.pairing_status)
    if (result.rsd_info) setLastRsd(result.rsd_info)
    if (result.report) setReport(result.report)
  }

  const run = async (label: string, operation: () => Promise<WirelessOperationResponse>, nextStage?: StageKey) => {
    setBusy(label)
    try {
      const result = await operation()
      applyResult(result)
      if (!result.ok) throw new Error(result.message || `${label} failed`)
      await refresh()
      if (nextStage) setActiveStage(nextStage)
      showMessage(result.message || `${label} complete.`)
    } catch (err: any) {
      if (err.details && typeof err.details === 'object') {
        applyResult(err.details as WirelessOperationResponse)
        await refresh().catch(() => undefined)
      }
      showError(err.message)
    } finally {
      setBusy('')
    }
  }

  const requireExperiment = (): string => {
    if (!experimentId) throw new Error('Create a wireless experiment first.')
    return experimentId
  }

  const createExperiment = async (type: WirelessTestType) => {
    setBusy('create')
    try {
      const result = await api.createWirelessExperiment(type)
      setExperiment(result.experiment)
      setExperimentId(result.experiment.experiment_id)
      setTestType(type)
      setReport('')
      setLastDiscovery(null)
      setLastRsd(null)
      setLastPairingStatus('UNKNOWN')
      await refresh()
      setActiveStage(type === EXPERIMENT_A ? 'wired' : 'detect')
      showMessage(type === EXPERIMENT_A ? 'Experiment A created. Run the wired baseline first.' : 'Experiment B created. Continue with cable-free discovery.')
    } catch (err: any) {
      showError(err.message)
    } finally {
      setBusy('')
    }
  }

  const coordinateOrThrow = () => {
    if (!validCoordinate) throw new Error('Choose a valid test coordinate.')
    return selectedCoordinate
  }

  const openReport = async () => {
    if (!experimentId) return
    try {
      const text = await api.wirelessTestingReport(experimentId)
      setReport(text)
      const next = window.open('', '_blank')
      if (next) {
        next.document.title = `${experimentId} wireless report`
        next.document.body.innerText = text
      }
    } catch (err: any) {
      showError(err.message)
    }
  }

  const stopExperiment = async () => {
    await run('Stop Wireless Test', async () => {
      if (experimentId) return api.stopWirelessExperiment(experimentId)
      return api.stopWirelessTesting()
    })
  }

  const stopTunnel = async () => {
    setBusy('Stop Wi-Fi Tunnel')
    try {
      await api.stopWirelessWifiTunnel()
      await refresh()
      showMessage('Wi-Fi tunnel stopped.')
    } catch (err: any) {
      showError(err.message)
    } finally {
      setBusy('')
    }
  }

  const stageStatus = (stage: StageKey): WirelessCheckStatus => {
    const summary = currentSummary
    const conn = currentConnection
    if (stage === 'wired') return summary.usb_connected_at_start === true ? 'PASS' : testType === EXPERIMENT_B ? 'UNKNOWN' : 'WARNING'
    if (stage === 'pairing') return lastPairingStatus === 'CONFIRMED BY IOSSim' ? 'PASS' : lastPairingStatus === 'LIKELY READY' ? 'WARNING' : 'UNKNOWN'
    if (stage === 'unplug') return summary.usb_absent_before_tunnel === true ? 'PASS' : conn?.usb_detected ? 'WARNING' : 'UNKNOWN'
    if (stage === 'detect') return summary.wireless_discovery === 'FOUND' || conn?.wireless_device_detected ? 'PASS' : summary.wireless_discovery === 'NOT_FOUND' ? 'FAIL' : 'UNKNOWN'
    if (stage === 'tunnel') return summary.wifi_tunnel === 'PASS' || conn?.wifi_tunnel_active ? 'PASS' : summary.wifi_tunnel === 'FAIL' ? 'FAIL' : 'UNKNOWN'
    if (stage === 'rsd') return summary.rsd === 'PASS' || conn?.rsd_ready ? 'PASS' : summary.rsd === 'FAIL' ? 'FAIL' : 'UNKNOWN'
    if (stage === 'set') return summary.set_location === 'PASS' ? 'PASS' : summary.set_location === 'FAIL' ? 'FAIL' : 'UNKNOWN'
    if (stage === 'confirm') return summary.manual_location_confirmation === 'yes' ? 'PASS' : summary.manual_location_confirmation === 'no' ? 'FAIL' : 'UNKNOWN'
    if (stage === 'reset') return summary.reset_gps === 'PASS' ? 'PASS' : summary.reset_gps === 'FAIL' ? 'FAIL' : 'UNKNOWN'
    return (experiment?.verdict && experiment.verdict !== 'INCONCLUSIVE') || currentConnection?.verdict ? 'PASS' : 'UNKNOWN'
  }

  const tabsList = stages

  return <div style={overlay} data-testid="wireless-testing-lab">
    <div style={header}>
      <div>
        <div style={headerTitle}>Advanced Wireless Diagnostics</div>
        <div style={{ color: colors.muted, fontSize: 12, marginTop: 4 }}>
          Normal wireless location uses the main device panel. This lab is diagnostic and includes older persistent tunnel experiments.
        </div>
      </div>
      <div style={buttonRow}>
        <button style={button()} onClick={refresh}>Refresh Status</button>
        <button style={button()} disabled={!!busy} onClick={stopTunnel}>Stop Wi-Fi Tunnel</button>
        <button style={button()} disabled={!!busy} onClick={stopExperiment}>Stop Wireless Test</button>
        <button style={button('danger')} onClick={onClose}>Close Lab</button>
      </div>
    </div>
    <div style={body}>
      <nav style={stagesNav} aria-label="Wireless Testing stages">
        <div style={{ ...notice('warning'), marginBottom: 8 }}>
          Experimental. Do not use this as evidence of success until a physical iPhone passes Set Location and Reset GPS with USB disconnected.
        </div>
        {tabsList.map(([value, label], index) => {
          const state = stageStatus(value)
          return <button key={value} style={stageButton(activeStage === value)} onClick={() => setActiveStage(value)}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
              <span>{index + 1}. {label}</span>
              <span style={{ color: statusColor(state), fontSize: 10, fontWeight: 760 }}>{state}</span>
            </div>
          </button>
        })}
      </nav>
      <main style={content}>
        {error && <div style={{ ...notice('danger'), marginBottom: 12 }} role="alert">{error}</div>}
        {message && <div style={{ ...notice('success'), marginBottom: 12 }}>{message}</div>}
        <EvidencePanel status={status} experimentId={experimentId} testType={testType} />
        {activeStage === 'wired' && <WiredStage
          busy={busy}
          testType={testType}
          experimentId={experimentId}
          selectedLocation={selectedLocation}
          selectedCoordinate={selectedCoordinate}
          useSelectedCoordinate={useSelectedCoordinate}
          manualLat={manualLat}
          manualLon={manualLon}
          validCoordinate={validCoordinate}
          onTestType={setTestType}
          onCreate={createExperiment}
          onUseSelected={setUseSelectedCoordinate}
          onManualLat={setManualLat}
          onManualLon={setManualLon}
          onBaseline={() => run('Run Wired Baseline', () => api.runWirelessWiredBaseline(requireExperiment()), 'pairing')}
          onWiredSet={() => run('Test Set Location', () => {
            const coord = coordinateOrThrow()
            return api.testWirelessWiredSetLocation(requireExperiment(), coord.lat, coord.lon)
          })}
          onWiredReset={() => run('Reset GPS', () => api.testWirelessWiredResetGps(requireExperiment()))}
        />}
        {activeStage === 'pairing' && <PairingStage
          status={status}
          busy={busy}
          pairingStatus={lastPairingStatus}
          onRun={() => run('Wireless Pairing Check', () => api.runWirelessPairingCheck(requireExperiment()), 'unplug')}
        />}
        {activeStage === 'unplug' && <UnplugStage
          status={status}
          busy={busy}
          onPrepare={() => run('Ready to Unplug', () => api.prepareWirelessUnplug(requireExperiment()))}
          onCableRemoved={() => run('Cable Removed', () => api.confirmWirelessCableRemoved(requireExperiment()), 'detect')}
        />}
        {activeStage === 'detect' && <DetectStage
          discovery={lastDiscovery}
          status={status}
          busy={busy}
          onDetect={() => run('Detect Without USB', () => api.detectWirelessWithoutUsb(requireExperiment()), 'tunnel')}
        />}
        {activeStage === 'tunnel' && <TunnelStage
          status={status}
          busy={busy}
          protocol={tunnelProtocol}
          onProtocol={setTunnelProtocol}
          onStart={() => run('Start Persistent Tunnel Diagnostic', () => api.startWirelessWifiTunnel(requireExperiment(), tunnelProtocol), 'rsd')}
        />}
        {activeStage === 'rsd' && <RsdStage
          rsd={lastRsd}
          busy={busy}
          onValidate={() => run('Validate RSD', () => api.validateWirelessRsd(requireExperiment()), 'set')}
        />}
        {activeStage === 'set' && <SetStage
          busy={busy}
          selectedLocation={selectedLocation}
          selectedCoordinate={selectedCoordinate}
          useSelectedCoordinate={useSelectedCoordinate}
          manualLat={manualLat}
          manualLon={manualLon}
          validCoordinate={validCoordinate}
          onUseSelected={setUseSelectedCoordinate}
          onManualLat={setManualLat}
          onManualLon={setManualLon}
          onSet={() => run('Wireless Set Location', () => {
            const coord = coordinateOrThrow()
            return api.testWirelessSetLocation(requireExperiment(), coord.lat, coord.lon)
          }, 'confirm')}
        />}
        {activeStage === 'confirm' && <ConfirmStage
          busy={busy}
          confirmation={locationConfirmation}
          notes={confirmationNotes}
          onConfirmation={setLocationConfirmation}
          onNotes={setConfirmationNotes}
          onRecord={() => run('Manual Location Confirmation', () => api.recordWirelessLocationConfirmation(requireExperiment(), locationConfirmation, confirmationNotes), 'reset')}
        />}
        {activeStage === 'reset' && <ResetStage
          busy={busy}
          resetConfirmation={resetConfirmation}
          notes={confirmationNotes}
          onResetConfirmation={setResetConfirmation}
          onNotes={setConfirmationNotes}
          onReset={() => run('Wireless Reset GPS', () => api.testWirelessResetGps(requireExperiment()), 'verdict')}
          onRecordReset={() => run('Manual Reset Confirmation', () => api.recordWirelessResetConfirmation(requireExperiment(), resetConfirmation, confirmationNotes), 'verdict')}
        />}
        {activeStage === 'verdict' && <VerdictStage
          experiment={experiment}
          history={history}
          report={report}
          busy={busy}
          experimentId={experimentId}
          onFinalize={() => run('Finalize Wireless Experiment', () => api.finalizeWirelessExperiment(requireExperiment()))}
          onOpenReport={openReport}
        />}
      </main>
    </div>
  </div>
}

function EvidencePanel({ status, experimentId, testType }: { status: WirelessTestingStatus | null; experimentId: string | null; testType: WirelessTestType }) {
  const conn = status?.connection
  const flags = status?.feature_flags
  return <section style={section}>
    <div style={sectionTitle}>Connection Evidence</div>
    <div style={grid3}>
      <Metric label="Experiment" value={experimentId ?? 'None'} />
      <Metric label="Test type" value={testType === EXPERIMENT_A ? 'Experiment A' : 'Experiment B'} />
      <Metric label="Frontend wireless gate" value={frontendExperimental && frontendWireless ? 'ENABLED' : 'DISABLED'} tone={frontendExperimental && frontendWireless ? 'success' : 'danger'} />
      <Metric label="Backend wireless gate" value={flags?.wireless_testing_enabled ? 'ENABLED' : 'UNKNOWN'} tone={flags?.wireless_testing_enabled ? 'success' : 'warning'} />
      <Metric label="Current transport" value={conn?.current_transport ?? 'UNKNOWN'} tone={transportTone(conn?.current_transport)} />
      <Metric label="USB detected" value={status?.usb?.usb_detected ? 'YES' : 'NO'} tone={status?.usb?.usb_detected ? 'warning' : 'success'} />
      <Metric label="Wireless candidate" value={conn?.wireless_device_detected ? 'YES' : 'NO'} tone={conn?.wireless_device_detected ? 'success' : 'warning'} />
      <Metric label="Wi-Fi tunnel" value={conn?.wifi_tunnel_active ? `ACTIVE ${conn.wifi_tunnel_pid ?? ''}` : 'INACTIVE'} tone={conn?.wifi_tunnel_active ? 'success' : 'warning'} />
      <Metric label="Tunnel transport" value={conn?.tunnel_transport ?? 'UNKNOWN'} tone={transportTone(conn?.tunnel_transport ?? undefined)} />
      <Metric label="Pairing bootstrap" value={conn?.pairing_bootstrap_status ?? 'UNKNOWN'} tone={statusTone(conn?.pairing_bootstrap_status)} />
      <Metric label="Wi-Fi enablement" value={conn?.wifi_connections_status ?? 'UNKNOWN'} tone={statusTone(conn?.wifi_connections_status)} />
      <Metric label="Tunnel protocol" value={conn?.selected_protocol ?? 'NONE'} />
      <Metric label="Tunnel failure" value={conn?.last_tunnel_failure_class ?? 'None'} tone={conn?.last_tunnel_failure_class ? 'danger' : 'success'} />
      <Metric label="Fresh RSD proof" value={conn?.fresh_rsd_proof_state ?? 'NOT_READY'} tone={conn?.fresh_rsd_proof_state === 'FRESH_WIFI_RSD_READY' ? 'success' : 'warning'} />
      <Metric label="RSD ready" value={conn?.rsd_ready ? 'YES' : 'NO'} tone={conn?.rsd_ready ? 'success' : 'warning'} />
      <Metric label="Location session" value={conn?.location_session_active ? 'ACTIVE' : 'INACTIVE'} tone={conn?.location_session_active ? 'success' : 'warning'} />
      <Metric label="Last contact" value={conn?.last_successful_contact ?? 'None'} />
      <Metric label="Last error" value={conn?.last_error ?? 'None'} tone={conn?.last_error ? 'danger' : 'success'} />
      <Metric label="Verdict" value={conn?.verdict ?? 'INCONCLUSIVE'} />
    </div>
  </section>
}

function WiredStage(props: {
  busy: string
  testType: WirelessTestType
  experimentId: string | null
  selectedLocation: LatLon | null
  selectedCoordinate: LatLon
  useSelectedCoordinate: boolean
  manualLat: string
  manualLon: string
  validCoordinate: boolean
  onTestType: (type: WirelessTestType) => void
  onCreate: (type: WirelessTestType) => Promise<void>
  onUseSelected: (value: boolean) => void
  onManualLat: (value: string) => void
  onManualLon: (value: string) => void
  onBaseline: () => void
  onWiredSet: () => void
  onWiredReset: () => void
}) {
  return <>
    <section style={section}>
      <div style={sectionTitle}>Experiment Selection</div>
      <div style={notice('info')}>
        Experiment A starts with USB connected, then removes the cable after IOSSim native wireless preparation. Experiment B starts fresh with USB already disconnected.
      </div>
      <div style={{ ...buttonRow, marginTop: 12 }}>
        <button style={button(props.testType === EXPERIMENT_A ? 'primary' : 'secondary')} disabled={!!props.busy} onClick={() => { props.onTestType(EXPERIMENT_A); props.onCreate(EXPERIMENT_A) }}>Create Experiment A</button>
        <button style={button(props.testType === EXPERIMENT_B ? 'primary' : 'secondary')} disabled={!!props.busy} onClick={() => { props.onTestType(EXPERIMENT_B); props.onCreate(EXPERIMENT_B) }}>Create Experiment B</button>
      </div>
    </section>
    <CoordinatePanel {...props} />
    <section style={section}>
      <div style={sectionTitle}>Wired Baseline</div>
      <div style={notice('warning')}>
        These controls use IOSSim's stable USB path. They do not prove wireless operation.
      </div>
      <div style={{ ...buttonRow, marginTop: 12 }}>
        <button style={button('primary')} disabled={!props.experimentId || !!props.busy} onClick={props.onBaseline}>Run Wired Baseline</button>
        <button style={button()} disabled={!props.experimentId || !!props.busy || !props.validCoordinate} onClick={props.onWiredSet}>Test Set Location</button>
        <button style={button()} disabled={!props.experimentId || !!props.busy} onClick={props.onWiredReset}>Reset GPS</button>
      </div>
    </section>
  </>
}

function PairingStage({ status, busy, pairingStatus, onRun }: { status: WirelessTestingStatus | null; busy: string; pairingStatus: string; onRun: () => void }) {
  const commands = status?.capabilities.commands ?? {}
  const conn = status?.connection
  return <>
    <section style={section}>
      <div style={sectionTitle}>IOSSim Native Pairing Preparation</div>
      <div style={notice('warning')}>
        Target iPhone is iOS 26.5.2. Initial USB trust/pairing is allowed and expected; IOSSim now attempts RemotePairing bootstrap and Wi-Fi enablement before discovery.
      </div>
      <ol style={{ margin: '12px 0 0 20px', lineHeight: 1.75, fontSize: 13 }}>
        {(status?.pairing_guidance ?? [
          'Connect the iPhone by cable, unlock it, and Trust the host if prompted.',
          "Use Xcode's installed device-management interface to enable network or wireless development.",
          'Keep the computer and iPhone on the same Wi-Fi/LAN, then return to IOSSim.',
        ]).map(item => <li key={item}>{item}</li>)}
      </ol>
    </section>
    <section style={section}>
      <div style={sectionTitle}>Pairing Status</div>
      <div style={{ marginBottom: 10 }}><span style={statusPill(statusColor(pairingStatusToCheck(pairingStatus)))}>{pairingStatus}</span></div>
      <div style={grid2}>
        <Readout label="Preparation result" value={conn?.pairing_preparation_status ?? 'UNKNOWN'} />
        <Readout label="RemotePairing bootstrap" value={conn?.pairing_bootstrap_status ?? 'UNKNOWN'} />
        <Readout label="Wi-Fi connections" value={conn?.wifi_connections_status ?? 'UNKNOWN'} />
        <Readout label="Wireless discovery" value={conn?.wireless_discovery_status ?? 'UNKNOWN'} />
        <Readout label="Xcode platform" value={status?.xcode?.platform ?? 'UNKNOWN'} />
        <Readout label="Xcode detected" value={status?.xcode?.installed ? 'YES' : 'NO'} />
        <Readout label="Xcode version" value={status?.xcode?.version ?? 'Unavailable'} />
        <Readout label="pymobiledevice3" value={String(status?.capabilities.pymobiledevice3_version ?? 'UNKNOWN')} />
        <Readout label="Wireless CLI support" value={status?.capabilities.required_wireless_commands_available ? 'AVAILABLE' : 'UNAVAILABLE'} />
      </div>
      <div style={{ ...buttonRow, marginTop: 12 }}>
        <button style={button('primary')} disabled={!!busy} onClick={onRun}>Run Wireless Pairing Check</button>
      </div>
    </section>
    <section style={section}>
      <div style={sectionTitle}>Confirmed pymobiledevice3 Command Categories</div>
      <div style={tableWrap}>
        <table style={table}>
          <thead><tr><th style={th}>Capability</th><th style={th}>Available</th><th style={th}>Command</th></tr></thead>
          <tbody>{Object.entries(commands).map(([name, command]) => <tr key={name}>
            <td style={td}>{name}</td>
            <td style={td}>{command.available ? 'YES' : 'NO'}</td>
            <td style={{ ...td, fontFamily: 'monospace', overflowWrap: 'anywhere' }}>{Array.isArray(command.command) ? command.command.join(' ') : ''}</td>
          </tr>)}</tbody>
        </table>
      </div>
    </section>
  </>
}

function UnplugStage({ status, busy, onPrepare, onCableRemoved }: { status: WirelessTestingStatus | null; busy: string; onPrepare: () => void; onCableRemoved: () => void }) {
  return <section style={section}>
    <div style={sectionTitle}>Ready to Unplug</div>
    <div style={notice('info')}>
      IOSSim records the current device identity, USB state, tunnel state, RSD state, and timestamp before removal. After physically removing the cable, use the second button to verify USB discovery no longer sees the device.
    </div>
    <div style={grid2}>
      <Readout label="USB discovery" value={status?.usb.usb_detected ? 'USB DEVICE PRESENT' : 'NO USB DEVICE'} />
      <Readout label="Stable tunnel" value={status?.stable_status.tunnel_active ? 'ACTIVE' : 'INACTIVE'} />
      <Readout label="Stable device" value={status?.stable_status.device?.name ?? 'Unavailable'} />
    </div>
    <div style={{ ...buttonRow, marginTop: 12 }}>
      <button style={button('primary')} disabled={!!busy} onClick={onPrepare}>Ready to Unplug</button>
      <button style={button()} disabled={!!busy} onClick={onCableRemoved}>Cable Removed - Continue Test</button>
    </div>
  </section>
}

function DetectStage({ discovery, status, busy, onDetect }: { discovery: WirelessDiscovery | null; status: WirelessTestingStatus | null; busy: string; onDetect: () => void }) {
  const methods = discovery?.methods ?? {}
  const candidates = discovery?.remote_pairing_candidates ?? []
  return <section style={section}>
    <div style={sectionTitle}>Detect Device Without USB</div>
    <div style={notice(status?.usb.usb_detected ? 'warning' : 'info')}>
      Cable-free proof requires USB discovery to be absent before Wi-Fi tunnel creation.
    </div>
    <div style={{ ...buttonRow, marginTop: 12, marginBottom: 12 }}>
      <button style={button('primary')} disabled={!!busy} onClick={onDetect}>Detect Without USB</button>
    </div>
    <DiscoveryTable discovery={discovery} methods={methods} currentUsb={status?.usb ?? null} />
    {candidates.length > 0 && <div style={{ marginTop: 12 }}>
      <div style={sectionTitle}>RemotePairing Candidates</div>
      <CandidateTable candidates={candidates} />
    </div>}
  </section>
}

function TunnelStage({ status, busy, protocol, onProtocol, onStart }: { status: WirelessTestingStatus | null; busy: string; protocol: 'default' | 'tcp' | 'quic'; onProtocol: (value: 'default' | 'tcp' | 'quic') => void; onStart: () => void }) {
  const conn = status?.connection
  const attempts = conn?.tunnel_attempts ?? []
  return <section style={section}>
    <div style={sectionTitle}>Fresh Wi-Fi RemoteXPC/RSD Tunnel</div>
    <div style={notice(status?.usb.usb_detected ? 'warning' : 'success')}>
      Persistent tunnels are diagnostic-only for the older wireless path. Default tries QUIC only; TCP is available only when explicitly selected because it can crash in the native SSL-PSK path.
    </div>
    <div style={{ ...grid2, marginTop: 12 }}>
      <label style={field}>Protocol
        <select style={input} value={protocol} onChange={e => onProtocol(e.target.value as 'default' | 'tcp' | 'quic')}>
          <option value="default">Default</option>
          <option value="tcp">TCP diagnostic</option>
          <option value="quic">QUIC</option>
        </select>
      </label>
      <Readout label="USB at tunnel start" value={status?.usb.usb_detected ? 'USB STILL PRESENT' : 'USB ABSENT'} />
      <Readout label="Selected candidate" value={conn?.selected_candidate ? `${String(conn.selected_candidate.candidate_host ?? 'unknown')}:${String(conn.selected_candidate.candidate_port ?? '')}` : 'None'} />
      <Readout label="Last failure class" value={conn?.last_tunnel_failure_class ?? 'None'} />
      <Readout label="Fresh RSD proof" value={conn?.fresh_rsd_proof_state ?? 'NOT_READY'} />
    </div>
    <div style={{ ...buttonRow, marginTop: 12 }}>
      <button style={button('primary')} disabled={!!busy} onClick={onStart}>Start Fresh Wi-Fi Tunnel</button>
    </div>
    {attempts.length > 0 && <div style={{ marginTop: 12 }}>
      <div style={sectionTitle}>Tunnel Attempts</div>
      <TunnelAttemptsTable attempts={attempts} />
    </div>}
  </section>
}

function RsdStage({ rsd, busy, onValidate }: { rsd: Record<string, unknown> | null; busy: string; onValidate: () => void }) {
  return <section style={section}>
    <div style={sectionTitle}>Validate Fresh RSD</div>
    <div style={notice('info')}>
      This validation uses remote rsd-info against the RSD endpoint emitted by the Wi-Fi tunnel. Cached USB RSD cannot qualify as fresh wireless proof.
    </div>
    <div style={{ ...buttonRow, marginTop: 12 }}>
      <button style={button('primary')} disabled={!!busy} onClick={onValidate}>Validate Fresh RSD</button>
    </div>
    {rsd && <pre style={preBlock}>{JSON.stringify(rsd, null, 2)}</pre>}
  </section>
}

function SetStage(props: {
  busy: string
  selectedLocation: LatLon | null
  selectedCoordinate: LatLon
  useSelectedCoordinate: boolean
  manualLat: string
  manualLon: string
  validCoordinate: boolean
  onUseSelected: (value: boolean) => void
  onManualLat: (value: string) => void
  onManualLon: (value: string) => void
  onSet: () => void
}) {
  return <>
    <CoordinatePanel
      selectedLocation={props.selectedLocation}
      selectedCoordinate={props.selectedCoordinate}
      useSelectedCoordinate={props.useSelectedCoordinate}
      manualLat={props.manualLat}
      manualLon={props.manualLon}
      validCoordinate={props.validCoordinate}
      onUseSelected={props.onUseSelected}
      onManualLat={props.onManualLat}
      onManualLon={props.onManualLon}
    />
    <section style={section}>
      <div style={sectionTitle}>Wireless Set Location</div>
      <div style={notice('warning')}>
        This button explicitly sends the selected coordinate through the fresh Wi-Fi RSD path. It does not use the stable USB tunnel.
      </div>
      <div style={{ ...buttonRow, marginTop: 12 }}>
        <button style={button('primary')} disabled={!!props.busy || !props.validCoordinate} onClick={props.onSet}>Test Wireless Set Location</button>
      </div>
    </section>
  </>
}

function ConfirmStage({ busy, confirmation, notes, onConfirmation, onNotes, onRecord }: { busy: string; confirmation: WirelessManualConfirmation; notes: string; onConfirmation: (value: WirelessManualConfirmation) => void; onNotes: (value: string) => void; onRecord: () => void }) {
  return <section style={section}>
    <div style={sectionTitle}>Manual Device Confirmation</div>
    <div style={notice('info')}>
      A successful subprocess return code is not enough evidence. Check the physical iPhone and record whether location visibly moved.
    </div>
    <ConfirmationInputs confirmation={confirmation} notes={notes} onConfirmation={onConfirmation} onNotes={onNotes} label="Did the iPhone actually move to the selected location?" />
    <div style={{ ...buttonRow, marginTop: 12 }}>
      <button style={button('primary')} disabled={!!busy} onClick={onRecord}>Record Location Confirmation</button>
    </div>
  </section>
}

function ResetStage({ busy, resetConfirmation, notes, onResetConfirmation, onNotes, onReset, onRecordReset }: { busy: string; resetConfirmation: WirelessManualConfirmation; notes: string; onResetConfirmation: (value: WirelessManualConfirmation) => void; onNotes: (value: string) => void; onReset: () => void; onRecordReset: () => void }) {
  return <section style={section}>
    <div style={sectionTitle}>Wireless Reset GPS</div>
    <div style={notice('warning')}>
      Reset GPS through the same Wi-Fi RSD path is required before the strongest verdict can be reported. If it fails, reconnect USB and use the stable Reset GPS workflow.
    </div>
    <div style={{ ...buttonRow, margin: '12px 0' }}>
      <button style={button('primary')} disabled={!!busy} onClick={onReset}>Test Wireless Reset GPS</button>
    </div>
    <ConfirmationInputs confirmation={resetConfirmation} notes={notes} onConfirmation={onResetConfirmation} onNotes={onNotes} label="Did the reset restore real GPS on the iPhone?" />
    <div style={{ ...buttonRow, marginTop: 12 }}>
      <button style={button()} disabled={!!busy} onClick={onRecordReset}>Record Reset Confirmation</button>
    </div>
  </section>
}

function VerdictStage({ experiment, history, report, busy, experimentId, onFinalize, onOpenReport }: { experiment: WirelessExperiment | null; history: WirelessExperiment[]; report: string; busy: string; experimentId: string | null; onFinalize: () => void; onOpenReport: () => void }) {
  const current = experiment ?? history.find(item => item.experiment_id === experimentId) ?? null
  return <>
    <section style={section}>
      <div style={sectionTitle}>Final Verdict</div>
      <div style={notice('info')}>
        Strong proof requires USB absent, paired device found wirelessly, fresh Wi-Fi tunnel, fresh RSD, wireless Set Location, positive manual location confirmation, and wireless Reset GPS.
      </div>
      <div style={{ ...grid2, marginTop: 12 }}>
        <Readout label="Verdict" value={current?.verdict ?? 'INCONCLUSIVE'} />
        <Readout label="Output directory" value={current?.output_directory ?? 'Unavailable'} />
      </div>
      <div style={{ ...buttonRow, marginTop: 12 }}>
        <button style={button('primary')} disabled={!experimentId || !!busy} onClick={onFinalize}>Generate Final Verdict</button>
        <button style={button()} disabled={!experimentId || !!busy} onClick={onOpenReport}>Open Report</button>
        <button style={button()} disabled={!experimentId} onClick={() => experimentId && window.open(api.wirelessTestingExportUrl(experimentId), '_blank')}>Export JSON</button>
      </div>
      {report && <pre style={preBlock}>{report}</pre>}
    </section>
    <HistoryTable history={history} />
  </>
}

function CoordinatePanel(props: {
  selectedLocation: LatLon | null
  selectedCoordinate: LatLon
  useSelectedCoordinate: boolean
  manualLat: string
  manualLon: string
  validCoordinate: boolean
  onUseSelected: (value: boolean) => void
  onManualLat: (value: string) => void
  onManualLon: (value: string) => void
}) {
  return <section style={section}>
    <div style={sectionTitle}>Test Coordinate</div>
    <div style={grid2}>
      <label style={{ display: 'flex', alignItems: 'center', gap: 8, color: colors.text, fontSize: 13 }}>
        <input type="checkbox" checked={props.useSelectedCoordinate} disabled={!props.selectedLocation} onChange={e => props.onUseSelected(e.target.checked)} />
        Use selected map coordinate
      </label>
      <Readout label="Current coordinate" value={props.validCoordinate ? `${props.selectedCoordinate.lat.toFixed(6)}, ${props.selectedCoordinate.lon.toFixed(6)}` : 'Invalid coordinate'} />
      <label style={field}>Latitude<input style={input} value={props.manualLat} disabled={props.useSelectedCoordinate && !!props.selectedLocation} onChange={e => props.onManualLat(e.target.value)} /></label>
      <label style={field}>Longitude<input style={input} value={props.manualLon} disabled={props.useSelectedCoordinate && !!props.selectedLocation} onChange={e => props.onManualLon(e.target.value)} /></label>
    </div>
  </section>
}

function DiscoveryTable({ discovery, methods, currentUsb }: { discovery: WirelessDiscovery | null; methods: WirelessDiscovery['methods']; currentUsb: WirelessTestingStatus['usb'] | null }) {
  if (!discovery) return <div style={notice('warning')}>No wireless discovery result has been recorded in this browser session.</div>
  const rows = Object.entries(methods).map(([name, method]) => {
    if (name !== 'usb' || !currentUsb) return [name, method] as const
    return [name, {
      ...method,
      ok: Boolean(currentUsb.command?.ok ?? true),
      found: Boolean(currentUsb.usb_detected),
      transport: currentUsb.transport,
      stdout_summary: String(currentUsb.command?.stdout ?? (currentUsb.usb_detected ? '[current USB device]' : '[]')),
      stderr_summary: String(currentUsb.command?.stderr ?? ''),
    }] as const
  })
  return <div style={tableWrap}>
    <table style={table}>
      <thead><tr><th style={th}>Method</th><th style={th}>Result</th><th style={th}>Transport</th><th style={th}>Output summary</th></tr></thead>
      <tbody>{rows.map(([name, method]) => <tr key={name}>
        <td style={td}>{methodLabel(name)}</td>
        <td style={td}>{method.found ? 'DEVICE FOUND' : method.ok ? 'NOT FOUND' : 'FAILED'}</td>
        <td style={td}>{method.transport}</td>
        <td style={{ ...td, overflowWrap: 'anywhere' }}>{method.stderr_summary || method.stdout_summary || ''}</td>
      </tr>)}</tbody>
    </table>
  </div>
}

function CandidateTable({ candidates }: { candidates: Array<Record<string, unknown>> }) {
  return <div style={tableWrap}>
    <table style={table}>
      <thead><tr><th style={th}>Source</th><th style={th}>Candidate</th><th style={th}>Route</th><th style={th}>Reason</th></tr></thead>
      <tbody>{candidates.map((candidate, index) => <tr key={index}>
        <td style={td}>{String(candidate.source ?? 'unknown')}</td>
        <td style={{ ...td, fontFamily: 'monospace', overflowWrap: 'anywhere' }}>{String(candidate.candidate_host ?? 'unknown')}:{String(candidate.candidate_port ?? '')}</td>
        <td style={td}>{String(candidate.routeable ?? 'unknown')}</td>
        <td style={td}>{String(candidate.selection_reason ?? '')}</td>
      </tr>)}</tbody>
    </table>
  </div>
}

function TunnelAttemptsTable({ attempts }: { attempts: Array<Record<string, unknown>> }) {
  return <div style={tableWrap}>
    <table style={table}>
      <thead><tr><th style={th}>Protocol</th><th style={th}>Outcome</th><th style={th}>Failure class</th><th style={th}>Detail</th></tr></thead>
      <tbody>{attempts.map((attempt, index) => <tr key={index}>
        <td style={td}>{String(attempt.protocol ?? 'unknown').toUpperCase()}</td>
        <td style={td}>{attempt.ok ? 'RSD EMITTED' : 'FAILED'}</td>
        <td style={td}>{String(attempt.failure_class ?? 'none')}</td>
        <td style={{ ...td, overflowWrap: 'anywhere' }}>{String(attempt.failure_message ?? attempt.process_state ?? '')}</td>
      </tr>)}</tbody>
    </table>
  </div>
}

function HistoryTable({ history }: { history: WirelessExperiment[] }) {
  return <section style={section}>
    <div style={sectionTitle}>Wireless Experiment History</div>
    <div style={tableWrap}>
      <table style={table}>
        <thead><tr><th style={th}>Date</th><th style={th}>Type</th><th style={th}>USB</th><th style={th}>Discovery</th><th style={th}>Tunnel</th><th style={th}>RSD</th><th style={th}>Set</th><th style={th}>Reset</th><th style={th}>Verdict</th></tr></thead>
        <tbody>{history.map(row => {
          const summary = row.summary ?? {}
          return <tr key={row.experiment_id}>
            <td style={td}>{row.created_at}</td>
            <td style={td}>{row.test_type === EXPERIMENT_A ? 'A' : 'B'}</td>
            <td style={td}>{String(summary.usb_state ?? 'UNKNOWN')}</td>
            <td style={td}>{String(summary.wireless_discovery ?? 'UNKNOWN')}</td>
            <td style={td}>{String(summary.wifi_tunnel ?? 'UNKNOWN')}</td>
            <td style={td}>{String(summary.rsd ?? 'UNKNOWN')}</td>
            <td style={td}>{String(summary.set_location ?? 'UNKNOWN')}</td>
            <td style={td}>{String(summary.reset_gps ?? 'UNKNOWN')}</td>
            <td style={td}>{row.verdict}</td>
          </tr>
        })}</tbody>
      </table>
    </div>
  </section>
}

function ConfirmationInputs({ label, confirmation, notes, onConfirmation, onNotes }: { label: string; confirmation: WirelessManualConfirmation; notes: string; onConfirmation: (value: WirelessManualConfirmation) => void; onNotes: (value: string) => void }) {
  return <div style={{ ...grid2, marginTop: 12 }}>
    <label style={field}>{label}
      <select style={input} value={confirmation} onChange={e => onConfirmation(e.target.value as WirelessManualConfirmation)}>
        <option value="yes">YES</option>
        <option value="no">NO</option>
        <option value="not_sure">NOT SURE</option>
      </select>
    </label>
    <label style={field}>Notes<textarea style={{ ...input, minHeight: 78 }} value={notes} onChange={e => onNotes(e.target.value)} /></label>
  </div>
}

function Metric({ label, value, tone }: { label: string; value: string; tone?: 'success' | 'warning' | 'danger' | 'info' }) {
  return <div style={metric}>
    <div style={metricLabel}>{label}</div>
    <div style={{ ...metricValue, color: tone ? toneColor(tone) : colors.text }}>{value}</div>
  </div>
}

function Readout({ label, value }: { label: string; value: string }) {
  return <div style={{ padding: 10, background: colors.panel, border: `1px solid ${colors.border}`, borderRadius: 6 }}>
    <div style={{ color: colors.muted, fontSize: 11 }}>{label}</div>
    <div style={{ marginTop: 4, fontSize: 13, overflowWrap: 'anywhere' }}>{value}</div>
  </div>
}

function statusColor(status: WirelessCheckStatus): string {
  if (status === 'PASS') return colors.success
  if (status === 'WARNING') return colors.warning
  if (status === 'FAIL') return colors.danger
  return colors.muted
}

function transportTone(value?: string | null): 'success' | 'warning' | 'danger' | 'info' {
  if (value === 'WIFI') return 'success'
  if (value === 'USB+WIFI') return 'warning'
  if (value === 'USB') return 'warning'
  return 'info'
}

function statusTone(value?: string | null): 'success' | 'warning' | 'danger' | 'info' {
  if (value === 'READY' || value === 'FOUND') return 'success'
  if (value === 'FAILED') return 'danger'
  if (value === 'PARTIAL' || value === 'UNSUPPORTED' || value === 'NOT_FOUND') return 'warning'
  return 'info'
}

function toneColor(tone: 'success' | 'warning' | 'danger' | 'info') {
  return tone === 'success' ? colors.success : tone === 'warning' ? colors.warning : tone === 'danger' ? colors.danger : colors.info
}

function pairingStatusToCheck(value: string): WirelessCheckStatus {
  if (value === 'CONFIRMED BY IOSSim') return 'PASS'
  if (value === 'LIKELY READY' || value === 'MANUAL CONFIRMATION REQUIRED') return 'WARNING'
  if (value === 'NOT READY') return 'FAIL'
  return 'UNKNOWN'
}

function methodLabel(value: string): string {
  if (value === 'usbmux_network') return 'usbmux network discovery'
  if (value === 'remote_browse') return 'RemoteXPC discovery'
  if (value === 'bonjour_remotepairing') return 'Bonjour remote pairing'
  if (value === 'bonjour_rsd') return 'Bonjour RSD'
  if (value === 'bonjour_mobdev2') return 'Bonjour mobdev2'
  if (value === 'usb') return 'USB discovery'
  return value
}

const preBlock: React.CSSProperties = {
  marginTop: 12,
  padding: 12,
  background: '#0b0e13',
  border: `1px solid ${colors.border}`,
  borderRadius: 6,
  color: colors.text,
  fontSize: 12,
  lineHeight: 1.5,
  whiteSpace: 'pre-wrap',
  overflowWrap: 'anywhere',
}
