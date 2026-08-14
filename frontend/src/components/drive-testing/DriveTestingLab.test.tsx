import React from 'react'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, DriveTestingLabStatus, DriveTestingProfileSettings } from '../../api/client'
import DeviceCheckPanel from './DeviceCheckPanel'
import DriveTestingLab from './DriveTestingLab'
import DriveTestingLauncher from './DriveTestingLauncher'
import ExperimentControls from './ExperimentControls'
import ObservationForm from './ObservationForm'
import ProfilePanel from './ProfilePanel'
import { isDriveTestingFrontendEnabled } from './featureFlags'

const idleExperiment: any = { ok: true, experiment_id: null, run_id: null, state: 'idle', profile_name: null, method: null, repeat_number: 0, total_repeats: 0, elapsed_s: 0, estimated_remaining_s: null, current_phase: null, current_coordinate: null, current_sample: 0, total_samples: 0, completed_distance_m: 0, remaining_distance_m: 0, host_planned_apparent_speed_mph: 0, host_calculated_emitted_apparent_speed_mph: 0, host_calculated_average_apparent_speed_mph: 0, target_update_interval_s: 0, actual_latest_update_interval_s: null, latest_timing_drift_s: null, latest_command_latency_s: null, successful_location_writes: 0, failed_location_writes: 0, active_subprocess_pid: null, device_connected: true, tunnel_active: true, pause_supported: true, last_error: null, message: '', chart_points: [] }
const labStatus: DriveTestingLabStatus = { ok: true, feature_flags: { backend_experimental_enabled: true, backend_drive_testing_enabled: true, drive_testing_enabled: true }, backend_reachable: true, pmd3_available: true, device_connected: true, device: { name: 'Test iPhone', ios_version: '17.4', ios_major: 17, needs_tunnel: true, udid_abbreviated: 'ABCD...1234' }, tunnel_active: true, rsd_address_available: true, device_trusted: null, ddi_mounted: null, stable_drive: { state: 'idle' } as any, experiment: idleExperiment, readiness: { overall: 'WARNING', checks: [{ name: 'Device trusted', status: 'WARNING', detail: 'Not exposed' }] }, technical_limits: [] }

afterEach(() => { vi.restoreAllMocks() })

describe('Drive Testing feature flags and launcher', () => {
  it('requires both frontend flags', () => {
    expect(isDriveTestingFrontendEnabled({})).toBe(false)
    expect(isDriveTestingFrontendEnabled({ VITE_ENABLE_EXPERIMENTAL_FEATURES: '1' })).toBe(false)
    expect(isDriveTestingFrontendEnabled({ VITE_ENABLE_DRIVE_TESTING: '1' })).toBe(false)
    expect(isDriveTestingFrontendEnabled({ VITE_ENABLE_EXPERIMENTAL_FEATURES: '1', VITE_ENABLE_DRIVE_TESTING: '1' })).toBe(true)
  })

  it('hides and shows the launcher and opens it', () => {
    const open = vi.fn()
    const { rerender } = render(<DriveTestingLauncher enabled={false} onOpen={open} />)
    expect(screen.queryByText('Drive Testing Lab')).not.toBeInTheDocument()
    rerender(<DriveTestingLauncher enabled onOpen={open} />)
    fireEvent.click(screen.getByText('Drive Testing Lab'))
    expect(open).toHaveBeenCalledOnce()
  })

  it('opens the integrated lab and closes through its own button', async () => {
    vi.spyOn(api, 'driveTestingStatus').mockResolvedValue(labStatus)
    vi.spyOn(api, 'listDriveTestingExperiments').mockResolvedValue({ ok: true, experiments: [] })
    vi.spyOn(api, 'driveTestingProfiles').mockResolvedValue({ ok: true, profiles: [], test_matrix: {} })
    const close = vi.fn()
    render(<DriveTestingLab selectedLocation={null} existingDriveRoute={null} stableDriveStatus={null} onClose={close} onMapState={() => {}} />)
    expect(screen.getByTestId('drive-testing-lab')).toBeInTheDocument()
    fireEvent.click(screen.getByText('Close Lab'))
    expect(close).toHaveBeenCalledOnce()
    await waitFor(() => expect(api.driveTestingStatus).toHaveBeenCalled())
  })
})

describe('Drive Testing panels', () => {
  it('renders device readiness without inventing trust or DDI state', () => {
    render(<DeviceCheckPanel status={labStatus} frontendExperimental frontendDriveTesting onRefresh={async () => {}} onError={() => {}} />)
    expect(screen.getByText('Test iPhone')).toBeInTheDocument()
    expect(screen.getAllByText('Not exposed').length).toBeGreaterThanOrEqual(2)
    expect(screen.getAllByText('WARNING').length).toBeGreaterThanOrEqual(1)
  })

  it('loads a profile preset and exposes method selection', () => {
    const settings: DriveTestingProfileSettings = { name: 'default', kind: 'constant', method: 'timed_static', target_speed_mph: 20, distance_miles: .6, update_interval_s: 1, random_seed: 1 }
    const changed = vi.fn()
    render(<ProfilePanel presets={[{ id: 'SPEED-14', name: 'Constant 14 mph', kind: 'constant', method: 'timed_static', target_speed_mph: 14, distance_miles: .6, update_interval_s: 1, random_seed: 1 }]} settings={settings} profile={null} onSettings={changed} onGenerate={async () => {}} onError={() => {}} />)
    fireEvent.change(screen.getByLabelText('Preset'), { target: { value: 'SPEED-14' } })
    expect(changed).toHaveBeenCalledWith(expect.objectContaining({ target_speed_mph: 14 }))
    expect(screen.getByText('Timestamped GPX experiment')).toBeInTheDocument()
  })

  it('enforces start, pause, resume, stop, and emergency control states', () => {
    const callbacks = { onValidate: vi.fn(), onStart: vi.fn(), onPause: vi.fn(), onResume: vi.fn(), onStop: vi.fn(), onEmergency: vi.fn(), onRepeat: vi.fn(), onQuickTest: vi.fn(), onAddQueue: vi.fn(), onRunQueue: vi.fn() }
    const { rerender } = render(<ExperimentControls canStart={false} state="idle" pauseSupported hasExperiment={false} {...callbacks} />)
    expect(screen.getByText('Start Test')).toBeDisabled()
    rerender(<ExperimentControls canStart={false} state="running" pauseSupported hasExperiment {...callbacks} />)
    expect(screen.getByText('Pause Test')).toBeEnabled()
    expect(screen.getByText('Stop Test')).toBeEnabled()
    fireEvent.click(screen.getByText('Emergency Stop and Reset GPS'))
    expect(callbacks.onEmergency).toHaveBeenCalledOnce()
    rerender(<ExperimentControls canStart={false} state="paused" pauseSupported hasExperiment {...callbacks} />)
    expect(screen.getByText('Resume Test')).toBeEnabled()
  })

  it('submits the manual observation form', async () => {
    const submit = vi.fn().mockResolvedValue(undefined)
    render(<ObservationForm experimentId="EXP-1" onSubmit={submit} onError={() => {}} />)
    fireEvent.change(screen.getByLabelText('Observed result'), { target: { value: 'trip_observed' } })
    fireEvent.change(screen.getByLabelText('Notes'), { target: { value: 'Checked manually' } })
    fireEvent.click(screen.getByText('Record Observation'))
    await waitFor(() => expect(submit).toHaveBeenCalledWith(expect.objectContaining({ result: 'trip_observed', notes: 'Checked manually' })))
  })
})
