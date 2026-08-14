import React, { useCallback, useEffect, useMemo, useState } from 'react'
import {
  api,
  DriveRouteResponse,
  DriveStatus,
  DriveTestingExperimentStatus,
  DriveTestingHistoryRow,
  DriveTestingLabStatus,
  DriveTestingPreset,
  DriveTestingProfile,
  DriveTestingProfileSettings,
  DriveTestingQueueStatus,
  LatLon,
} from '../../api/client'
import DeviceCheckPanel from './DeviceCheckPanel'
import DriveTestingHelp from './DriveTestingHelp'
import ExperimentComparison from './ExperimentComparison'
import ExperimentControls from './ExperimentControls'
import ExperimentHistory from './ExperimentHistory'
import ExperimentQueue from './ExperimentQueue'
import LiveExperimentPanel from './LiveExperimentPanel'
import ObservationForm from './ObservationForm'
import ProfilePanel from './ProfilePanel'
import RouteSetupPanel from './RouteSetupPanel'
import { LabMapState, LabRouteState } from './types'
import { body, button, buttonRow, colors, content, header, headerTitle, notice, overlay, tabButton, tabs } from './styles'

type Tab = 'device' | 'route' | 'profile' | 'live' | 'queue' | 'results' | 'history' | 'compare' | 'help'

interface Props {
  selectedLocation: LatLon | null
  existingDriveRoute: DriveRouteResponse | null
  stableDriveStatus: DriveStatus | null
  onClose: () => void
  onMapState: (state: LabMapState | null) => void
}

const frontendExperimental = import.meta.env.VITE_ENABLE_EXPERIMENTAL_FEATURES === '1'
const frontendDriveTesting = import.meta.env.VITE_ENABLE_DRIVE_TESTING === '1'

const initialSettings: DriveTestingProfileSettings = {
  name: 'Constant 20 mph - 0.6 mile', kind: 'constant', method: 'timed_static', target_speed_mph: 20,
  distance_miles: 0.6, update_interval_s: 1, timing_variation_s: 0, random_seed: 1,
}

export default function DriveTestingLab({ selectedLocation, existingDriveRoute, stableDriveStatus, onClose, onMapState }: Props) {
  const [tab, setTab] = useState<Tab>('device')
  const [labStatus, setLabStatus] = useState<DriveTestingLabStatus | null>(null)
  const [presets, setPresets] = useState<DriveTestingPreset[]>([])
  const [route, setRoute] = useState<LabRouteState | null>(null)
  const [settings, setSettings] = useState<DriveTestingProfileSettings>(initialSettings)
  const [profile, setProfile] = useState<DriveTestingProfile | null>(null)
  const [experimentId, setExperimentId] = useState<string | null>(null)
  const [liveStatus, setLiveStatus] = useState<DriveTestingExperimentStatus | null>(null)
  const [history, setHistory] = useState<DriveTestingHistoryRow[]>([])
  const [queueStatus, setQueueStatus] = useState<DriveTestingQueueStatus | null>(null)
  const [comparisonSelection, setComparisonSelection] = useState<string[]>([])
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')

  const showError = (value: string) => { setError(value); setMessage('') }
  const showMessage = (value: string) => { setMessage(value); setError('') }
  const refreshStatus = useCallback(async () => {
    try { setLabStatus(await api.driveTestingStatus()); setError('') } catch (err: any) { showError(err.message) }
  }, [])
  const refreshHistory = useCallback(async () => {
    try { setHistory((await api.listDriveTestingExperiments()).experiments) } catch (err: any) { showError(err.message) }
  }, [])

  useEffect(() => {
    refreshStatus()
    refreshHistory()
    api.driveTestingProfiles().then(result => setPresets(result.profiles)).catch((err: any) => showError(err.message))
    return () => onMapState(null)
  }, [])

  useEffect(() => {
    if (!experimentId) return
    const timer = window.setInterval(async () => {
      try {
        const next = await api.driveTestingExperimentStatus(experimentId)
        setLiveStatus(next)
        if (['completed', 'cancelled', 'error'].includes(next.state)) refreshHistory()
      } catch (err: any) { showError(err.message) }
    }, 1000)
    return () => window.clearInterval(timer)
  }, [experimentId, refreshHistory])

  useEffect(() => {
    if (!['running', 'paused'].includes(queueStatus?.state ?? '')) return
    const timer = window.setInterval(() => api.driveTestingQueueStatus().then(setQueueStatus).catch(() => {}), 1000)
    return () => window.clearInterval(timer)
  }, [queueStatus?.state])

  useEffect(() => {
    onMapState(route ? {
      route: route.coordinates,
      samples: profile?.samples.map(sample => ({ lat: sample.latitude, lon: sample.longitude })) ?? [],
      currentSample: liveStatus?.current_sample ?? 0,
      currentCoordinate: liveStatus?.current_coordinate ?? null,
      start: route.start,
      destination: route.destination,
    } : null)
  }, [route, profile, liveStatus?.current_sample, liveStatus?.current_coordinate])

  const changeRoute = (next: LabRouteState | null) => { setRoute(next); setProfile(null); setExperimentId(null); setLiveStatus(null) }
  const changeSettings = (next: DriveTestingProfileSettings) => { setSettings(next); setProfile(null); setExperimentId(null); setLiveStatus(null) }
  const generateProfile = async () => {
    if (!route) { showError('Generate or reuse a valid road route first.'); return }
    try {
      const result = await api.generateDriveTestingProfile(route.coordinates, settings)
      setProfile(result.profile); setExperimentId(null); setLiveStatus(null)
      showMessage(`Generated ${result.profile.samples.length} deterministic samples.`)
    } catch (err: any) { showError(err.message) }
  }

  const ensureExperiment = async (): Promise<string> => {
    if (experimentId) return experimentId
    if (!route || !profile) throw new Error('Generate a valid route and profile first.')
    const result = await api.createDriveTestingExperiment(route.coordinates, settings, { name: route.name, provider: route.provider, cached: route.cached }, true, 1)
    const id = result.experiment.experiment_id
    setExperimentId(id)
    setLiveStatus(await api.driveTestingExperimentStatus(id))
    await refreshHistory()
    return id
  }
  const validate = async () => {
    try { const id = await ensureExperiment(); const result = await api.validateDriveTestingExperiment(id); showMessage(result.ok ? 'Validation passed. Test is ready.' : result.message); setLiveStatus(await api.driveTestingExperimentStatus(id)) } catch (err: any) { showError(err.message) }
  }
  const start = async () => {
    if (!window.confirm('Start this coordinate-playback experiment on an authorized device and test account? Results are observations, not guarantees.')) return
    try { const id = await ensureExperiment(); await api.validateDriveTestingExperiment(id); const next = await api.startDriveTestingExperiment(id, true); setLiveStatus(next); setTab('live'); showMessage('Experiment started.') } catch (err: any) { showError(err.message) }
  }
  const withExperiment = async (operation: (id: string) => Promise<DriveTestingExperimentStatus>, success: string) => {
    if (!experimentId) { showError('No experiment is selected.'); return }
    try { const next = await operation(experimentId); setLiveStatus(next); showMessage(success) } catch (err: any) { showError(err.message) }
  }
  const emergency = async () => {
    if (!window.confirm('Emergency stop will cancel further emissions and attempt Reset GPS. Continue?')) return
    await withExperiment(api.emergencyStopDriveTestingExperiment, 'Emergency stop completed. Check the reset result in live status.')
  }
  const quickTest = async () => {
    if (!route) { showError('Quick Test requires an existing valid road route.'); return }
    if (route.distance_m < 0.6 * 1609.344) { showError('Quick Test requires at least 0.6 mile of road route.'); return }
    try {
      const preview = await api.quickDriveTestingPreview(route.coordinates, true)
      if (!window.confirm(`Quick Test will use 20 mph, 0.6 mile, and one-second updates. Calculated duration: ${preview.calculated_duration_s.toFixed(1)} seconds. Start now?`)) return
      const next = await api.quickDriveTestingStart(route.coordinates, true)
      setExperimentId(next.experiment_id); setLiveStatus(next); setTab('live'); showMessage('Quick Test started.')
    } catch (err: any) { showError(err.message) }
  }
  const recordObservation = async (observation: any) => {
    if (!experimentId) return
    await api.recordDriveTestingObservation(experimentId, observation)
    await refreshHistory(); showMessage('Manual observation saved and report regenerated.')
  }
  const selectHistory = async (id: string) => {
    try { const result = await api.getDriveTestingExperiment(id); setExperimentId(id); setLiveStatus(result.live_status); setTab('live') } catch (err: any) { showError(err.message) }
  }

  const activeState = liveStatus?.state ?? 'idle'
  const tunnelReady = !labStatus?.device?.needs_tunnel || Boolean(labStatus?.tunnel_active)
  const stableActive = ['starting', 'driving', 'paused'].includes(labStatus?.stable_drive?.state ?? stableDriveStatus?.state ?? 'idle')
  const experimentActive = ['starting', 'running', 'paused', 'stopping'].includes(activeState)
  const canStart = Boolean(frontendExperimental && frontendDriveTesting && labStatus?.feature_flags.drive_testing_enabled && labStatus.backend_reachable && labStatus.device_connected && tunnelReady && route && profile && !stableActive && !experimentActive)
  const tabsList: [Tab, string][] = [['device', 'Device Check'], ['route', 'Route Setup'], ['profile', 'Profiles'], ['live', 'Live Test'], ['queue', 'Experiment Queue'], ['results', 'Results'], ['history', 'History'], ['compare', 'Comparison'], ['help', 'Help']]

  return <div style={overlay} data-testid="drive-testing-lab">
    <div style={header}>
      <div><div style={headerTitle}>Drive Testing Lab - Experimental</div><div style={{ color: colors.muted, fontSize: 12, marginTop: 4 }}>Runs controlled coordinate-playback experiments through IOSSim. Results are observations, not guarantees of third-party classification. Use only authorized devices and test accounts.</div></div>
      <div style={buttonRow}><button style={button()} onClick={() => setTab('help')}>Open Documentation</button><button style={button()} onClick={refreshStatus}>Refresh Status</button><button style={button('danger')} onClick={onClose}>Close Lab</button></div>
    </div>
    <div style={body}>
      <nav style={tabs} aria-label="Drive Testing Lab sections">{tabsList.map(([value, label]) => <button key={value} style={tabButton(tab === value)} onClick={() => setTab(value)}>{label}</button>)}</nav>
      <main style={content}>
        {error && <div style={{ ...notice('danger'), marginBottom: 12 }} role="alert">{error}</div>}
        {message && <div style={{ ...notice('success'), marginBottom: 12 }}>{message}</div>}
        {tab === 'device' && <DeviceCheckPanel status={labStatus} frontendExperimental={frontendExperimental} frontendDriveTesting={frontendDriveTesting} onRefresh={refreshStatus} onError={showError} />}
        {tab === 'route' && <RouteSetupPanel selectedLocation={selectedLocation} existingDriveRoute={existingDriveRoute} route={route} targetMph={settings.target_speed_mph} onRoute={changeRoute} onError={showError} />}
        {tab === 'profile' && <ProfilePanel presets={presets} settings={settings} profile={profile} onSettings={changeSettings} onGenerate={generateProfile} onError={showMessage} />}
        {tab === 'live' && <><ExperimentControls canStart={canStart} state={activeState} pauseSupported={liveStatus?.pause_supported ?? true} hasExperiment={Boolean(experimentId)} onValidate={validate} onStart={start} onPause={() => withExperiment(api.pauseDriveTestingExperiment, 'Experiment paused.')} onResume={() => withExperiment(api.resumeDriveTestingExperiment, 'Experiment resumed.')} onStop={() => withExperiment(id => api.stopDriveTestingExperiment(id, false), 'Experiment stopped and logs finalized.')} onEmergency={emergency} onRepeat={() => withExperiment(id => api.repeatDriveTestingExperiment(id, true), 'Repeated experiment started.')} onQuickTest={quickTest} onAddQueue={() => setTab('queue')} onRunQueue={() => setTab('queue')} /><LiveExperimentPanel status={liveStatus} /></>}
        {tab === 'queue' && <ExperimentQueue history={history} currentExperimentId={experimentId} status={queueStatus} onStatus={setQueueStatus} onError={showError} />}
        {tab === 'results' && <><ResultsActions experimentId={experimentId} onObservation={() => {}} onCompare={() => { if (experimentId) setComparisonSelection([experimentId]); setTab('compare') }} onHelp={() => setTab('help')} onError={showError} /><ObservationForm experimentId={experimentId} onSubmit={recordObservation} onError={showError} /></>}
        {tab === 'history' && <ExperimentHistory rows={history} onRefresh={refreshHistory} onSelect={selectHistory} onCompare={id => { setComparisonSelection(items => Array.from(new Set([...items, id]))); setTab('compare') }} onObservation={id => { setExperimentId(id); setTab('results') }} onError={showError} />}
        {tab === 'compare' && <ExperimentComparison history={history} initialSelection={comparisonSelection} onError={showError} />}
        {tab === 'help' && <DriveTestingHelp />}
      </main>
    </div>
  </div>
}

function ResultsActions({ experimentId, onCompare, onHelp, onError }: { experimentId: string | null; onObservation: () => void; onCompare: () => void; onHelp: () => void; onError: (message: string) => void }) {
  const report = async () => {
    if (!experimentId) return
    try { const text = await api.driveTestingReport(experimentId); const next = window.open('', '_blank'); if (next) { next.document.title = `${experimentId} report`; next.document.body.innerText = text } } catch (error: any) { onError(error.message) }
  }
  return <div style={{ marginBottom: 14 }}><div style={buttonRow}><button style={button('primary')} disabled={!experimentId}>Record Observation</button><button style={button()} disabled={!experimentId}>Save Results</button><button style={button()} disabled={!experimentId} onClick={report}>Generate Report</button><button style={button()} disabled={!experimentId} onClick={() => experimentId && window.open(api.driveTestingExportUrl(experimentId, 'json'), '_blank')}>Export JSON</button><button style={button()} disabled={!experimentId} onClick={() => experimentId && window.open(api.driveTestingExportUrl(experimentId, 'csv'), '_blank')}>Export CSV</button><button style={button()} disabled={!experimentId} onClick={onCompare}>Compare Runs</button><button style={button()} onClick={onHelp}>Open Output Folder Instructions</button></div></div>
}
