import React from 'react'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, DeviceStatus, WirelessLocationStatus } from '../api/client'
import DevicePanel from './DevicePanel'

const readyDevice = {
  udid: '00008150-00022D581E12401C',
  name: 'Rishi iPhone',
  product_type: 'iPhone18,1',
  ios_version: '26.6',
  wireless_setup_valid: true,
  setup_state: 'WIRELESS_READY',
  last_transport_state: 'WIRELESS',
  wireless_ready: true,
  usb_visible: false,
  network_visible: true,
  transport: 'Wireless',
  status_label: 'Wireless Ready',
  selected: true,
}

const offlineDevice = {
  ...readyDevice,
  wireless_ready: false,
  network_visible: false,
  transport: 'Offline',
  status_label: 'Phone Offline',
  last_transport_state: 'OFFLINE',
}

function wirelessStatus(devices = [readyDevice], message = 'Wireless Ready'): WirelessLocationStatus {
  return {
    ok: true,
    devices,
    selected_udid: devices[0]?.udid ?? null,
    connection_mode: 'automatic',
    message,
    session: {
      device_udid: devices[0]?.udid ?? null,
      device_name: devices[0]?.name ?? null,
      connection: 'none',
      wireless_ready: false,
      session_state: 'DISCONNECTED',
      simulation_enabled: false,
      latitude: null,
      longitude: null,
      last_set_at: null,
      last_clear_at: null,
      last_error: null,
    },
  }
}

function status(wireless = wirelessStatus()): DeviceStatus {
  return {
    pmd3_available: true,
    device_connected: false,
    device: null,
    tunnel_active: false,
    tunnel: null,
    wireless_location: wireless,
  }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('DevicePanel wireless setup', () => {
  it('shows wireless-ready saved devices and marks the app ready', async () => {
    const onReady = vi.fn()
    const onConnectionChange = vi.fn()
    vi.spyOn(api, 'status').mockResolvedValue(status())

    render(<DevicePanel onReady={onReady} onConnectionChange={onConnectionChange} />)

    expect((await screen.findAllByText('Rishi iPhone')).length).toBeGreaterThan(0)
    expect(screen.getAllByText('Wireless Ready')[0]).toBeInTheDocument()
    await waitFor(() => expect(onReady).toHaveBeenLastCalledWith(true))
    expect(onConnectionChange).toHaveBeenLastCalledWith('automatic', readyDevice.udid)
  })

  it('distinguishes an offline saved iPhone from first-time setup', async () => {
    vi.spyOn(api, 'status').mockResolvedValue(status(wirelessStatus([offlineDevice], "Your iPhone isn't reachable over Wi-Fi.")))

    render(<DevicePanel onReady={vi.fn()} onConnectionChange={vi.fn()} />)

    expect((await screen.findAllByText(/Phone Offline/)).length).toBeGreaterThan(0)
    expect(screen.getByText("Your iPhone isn't reachable over Wi-Fi.")).toBeInTheDocument()
  })

  it('runs Add iPhone setup and shows ready-to-unplug progress', async () => {
    vi.spyOn(api, 'status').mockResolvedValue(status(wirelessStatus([], 'Connect your iPhone once to enable wireless mode.')))
    vi.spyOn(api, 'startWirelessSetup').mockResolvedValue({
      ok: true,
      device: { ...readyDevice, wireless_ready: false, setup_state: 'READY_TO_UNPLUG', status_label: 'USB Setup Required', transport: 'USB' },
      setup_state: 'READY_TO_UNPLUG',
      steps: [{ label: 'Unplug your iPhone', status: 'current' }],
      message: 'You can unplug your iPhone now.',
    })

    render(<DevicePanel onReady={vi.fn()} onConnectionChange={vi.fn()} />)
    fireEvent.click(await screen.findByText('Add iPhone'))

    expect(await screen.findByText('You can unplug your iPhone now.')).toBeInTheDocument()
    expect(api.startWirelessSetup).toHaveBeenCalledOnce()
  })

  it('verifies unplugged setup and reports wireless ready', async () => {
    vi.spyOn(api, 'status').mockResolvedValue(status(wirelessStatus([{ ...readyDevice, setup_state: 'READY_TO_UNPLUG', wireless_ready: false }], 'Unplug your iPhone')))
    vi.spyOn(api, 'verifyWirelessSetupUnplugged').mockResolvedValue({
      ok: true,
      device: readyDevice,
      setup_state: 'WIRELESS_READY',
      message: 'Your iPhone is ready.',
    })

    render(<DevicePanel onReady={vi.fn()} onConnectionChange={vi.fn()} />)
    fireEvent.click(await screen.findByText("I've unplugged my iPhone"))

    expect(await screen.findByText('Your iPhone is ready.')).toBeInTheDocument()
    expect(api.verifyWirelessSetupUnplugged).toHaveBeenCalledWith(readyDevice.udid)
  })
})
