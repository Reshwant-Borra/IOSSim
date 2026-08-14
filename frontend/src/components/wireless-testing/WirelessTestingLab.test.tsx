import React from 'react'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  api,
  WirelessDiscovery,
  WirelessExperiment,
  WirelessOperationResponse,
  WirelessTestingStatus,
} from '../../api/client'
import WirelessTestingLab from './WirelessTestingLab'
import WirelessTestingLauncher from './WirelessTestingLauncher'
import { isWirelessTestingFrontendEnabled } from './featureFlags'

const experiment: WirelessExperiment = {
  experiment_id: 'WIRELESS-20260728-ABC123',
  test_type: 'remove_cable_after_pairing',
  created_at: '2026-07-28T00:00:00Z',
  state: 'created',
  verdict: 'INCONCLUSIVE',
  summary: {},
}

const discovery: WirelessDiscovery = {
  wireless_device_detected: true,
  same_device: true,
  best_method: 'remote_browse',
  methods: {
    usb: { ok: true, found: false, transport: 'UNKNOWN', stdout_summary: '[]' },
    usbmux_network: { ok: true, found: true, transport: 'WIFI', stdout_summary: '[device]' },
    remote_browse: { ok: true, found: true, transport: 'WIFI', stdout_summary: '{wifi:[device]}' },
    bonjour_remotepairing: { ok: true, found: false, transport: 'UNKNOWN', stdout_summary: '[]' },
  },
}

const status: WirelessTestingStatus = {
  ok: true,
  backend_reachable: true,
  feature_flags: { backend_experimental_enabled: true, backend_wireless_testing_enabled: true, wireless_testing_enabled: true },
  stable_status: { pmd3_available: true, device_connected: true, device: { udid: '0000...401C', name: 'Test iPhone', ios_version: '26.5.2', ios_major: 26, needs_tunnel: true }, tunnel_active: true, tunnel: { address: 'redacted', port: 12345 } },
  usb: { usb_detected: true, transport: 'USB', devices: [{ name: 'Test iPhone', udid_abbreviated: '0000...401C' }] },
  capabilities: {
    pymobiledevice3_importable: true,
    pymobiledevice3_version: '10.7.4',
    required_wireless_commands_available: true,
    commands: {
      remote_browse: { available: true, command: ['python', '-m', 'pymobiledevice3', 'remote', 'browse', '--timeout', '2'] },
      remote_start_tunnel: { available: true, command: ['python', '-m', 'pymobiledevice3', 'remote', 'start-tunnel', '--connection-type', 'wifi', '--script-mode'] },
      lockdown_remotepairing: { available: true, command: ['python', '-m', 'pymobiledevice3', 'lockdown', 'remotepairing', '--pair'] },
      lockdown_wifi_connections: { available: true, command: ['python', '-m', 'pymobiledevice3', 'lockdown', 'wifi-connections', '--state', 'on'] },
    },
  },
  xcode: { platform: 'Darwin', installed: true, version: 'Xcode 18.0', instruction_variant: 'device_hub_or_devices_window', message: 'Use Xcode device management.' },
  connection: { ok: true, experiment_id: null, test_type: null, state: 'idle', current_stage: 'idle', current_transport: 'USB', usb_detected: true, wireless_device_detected: false, wireless_same_device: null, wifi_tunnel_active: false, wifi_tunnel_pid: null, tunnel_transport: null, rsd_ready: false, rsd_source: null, location_session_active: false, last_successful_contact: null, last_error: null, verdict: 'INCONCLUSIVE', message: '' },
  readiness: { overall: 'WARNING', checks: [{ name: 'IOSSim native pairing preparation', status: 'PASS', detail: 'Uses lockdown preparation.' }] },
  history: [],
  pairing_guidance: [
    'Connect the iPhone by cable, unlock it, and Trust the Mac if prompted.',
    "Run IOSSim's Wireless Pairing Check to perform RemotePairing bootstrap and enable Wi-Fi connections.",
    'Keep Mac and iPhone on the same Wi-Fi/LAN, then return to IOSSim.',
  ],
}

afterEach(() => { vi.restoreAllMocks() })

describe('Wireless Testing feature flags and launcher', () => {
  it('requires both frontend flags', () => {
    expect(isWirelessTestingFrontendEnabled({})).toBe(false)
    expect(isWirelessTestingFrontendEnabled({ VITE_ENABLE_EXPERIMENTAL_FEATURES: '1' })).toBe(false)
    expect(isWirelessTestingFrontendEnabled({ VITE_ENABLE_WIRELESS_TESTING: '1' })).toBe(false)
    expect(isWirelessTestingFrontendEnabled({ VITE_ENABLE_EXPERIMENTAL_FEATURES: '1', VITE_ENABLE_WIRELESS_TESTING: '1' })).toBe(true)
  })

  it('hides and shows the launcher', () => {
    const open = vi.fn()
    const { rerender } = render(<WirelessTestingLauncher enabled={false} onOpen={open} />)
    expect(screen.queryByText('Wireless Testing Lab')).not.toBeInTheDocument()
    rerender(<WirelessTestingLauncher enabled onOpen={open} />)
    fireEvent.click(screen.getByText('Wireless Testing Lab'))
    expect(open).toHaveBeenCalledOnce()
  })
})

describe('Wireless Testing Lab', () => {
  function mockStatus(next: WirelessTestingStatus = status) {
    vi.spyOn(api, 'wirelessTestingStatus').mockResolvedValue(next)
  }

  it('renders the integrated staged workflow and pairing preparation', async () => {
    mockStatus()
    render(<WirelessTestingLab selectedLocation={{ lat: 37.7, lon: -122.4 }} onClose={() => {}} />)
    expect(screen.getByTestId('wireless-testing-lab')).toBeInTheDocument()
    expect(screen.getByText('Wired Baseline')).toBeInTheDocument()
    fireEvent.click(screen.getByText(/Wireless Pairing Preparation/))
    await waitFor(() => expect(screen.getByText(/Target iPhone is iOS 26.5.2/)).toBeInTheDocument())
    expect(screen.getByText('remote start-tunnel --connection-type wifi --script-mode', { exact: false })).toBeInTheDocument()
  })

  it('creates Experiment A through the wireless endpoint', async () => {
    mockStatus()
    const create = vi.spyOn(api, 'createWirelessExperiment').mockResolvedValue({ ok: true, experiment, status: { ...status.connection, experiment_id: experiment.experiment_id, test_type: experiment.test_type } })
    render(<WirelessTestingLab selectedLocation={null} onClose={() => {}} />)
    fireEvent.click(screen.getByText('Create Experiment A'))
    await waitFor(() => expect(create).toHaveBeenCalledWith('remove_cable_after_pairing'))
    expect(screen.getByText(/Experiment A created/)).toBeInTheDocument()
  })

  it('records discovery methods separately', async () => {
    mockStatus({ ...status, connection: { ...status.connection, experiment_id: experiment.experiment_id, test_type: experiment.test_type } })
    const detect = vi.spyOn(api, 'detectWirelessWithoutUsb').mockResolvedValue({ ok: true, discovery, status: { ...status.connection, experiment_id: experiment.experiment_id, wireless_device_detected: true } } as WirelessOperationResponse)
    render(<WirelessTestingLab selectedLocation={null} onClose={() => {}} />)
    await waitFor(() => expect(screen.getByText(experiment.experiment_id)).toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: /4.*Detect Without USB/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Detect Without USB' }))
    await waitFor(() => expect(screen.getByText('RemoteXPC discovery')).toBeInTheDocument())
    expect(detect).toHaveBeenCalledWith(experiment.experiment_id)
  })

  it('renders current USB absence over stale discovery USB evidence', async () => {
    const staleDiscovery: WirelessDiscovery = {
      ...discovery,
      methods: {
        ...discovery.methods,
        usb: { ok: true, found: true, transport: 'USB', stdout_summary: '[stale usb device]' },
      },
    }
    const unplugged = {
      ...status,
      usb: { usb_detected: false, transport: 'UNKNOWN', devices: [], command: { ok: true, stdout: '[]', stderr: '' } },
      connection: { ...status.connection, experiment_id: experiment.experiment_id, test_type: experiment.test_type, usb_detected: false },
    }
    mockStatus(unplugged)
    const detect = vi.spyOn(api, 'detectWirelessWithoutUsb').mockResolvedValue({ ok: true, discovery: staleDiscovery, status: unplugged.connection } as WirelessOperationResponse)
    render(<WirelessTestingLab selectedLocation={null} onClose={() => {}} />)
    await waitFor(() => expect(screen.getByText(experiment.experiment_id)).toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: /4.*Detect Without USB/ }))
    await waitFor(() => expect(screen.getByText('Detect Device Without USB')).toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: 'Detect Without USB' }))
    await waitFor(() => expect(detect).toHaveBeenCalledWith(experiment.experiment_id))
    fireEvent.click(screen.getByRole('button', { name: /4.*Detect Without USB/ }))
    await waitFor(() => expect(screen.getByText('USB discovery')).toBeInTheDocument())
    const usbRow = screen.getByText('USB discovery').closest('tr')
    expect(usbRow).toHaveTextContent('NOT FOUND')
    expect(usbRow).toHaveTextContent('[]')
    expect(usbRow).not.toHaveTextContent('DEVICE FOUND')
  })
})
