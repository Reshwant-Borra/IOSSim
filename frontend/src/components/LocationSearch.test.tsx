import React from 'react'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import LocationSearch, { parseCoordinateQuery } from './LocationSearch'
import { GeocodeResponse } from '../api/client'

const tampa = {
  display_name: 'Tampa International Airport, Tampa, Hillsborough County, Florida, United States',
  lat: 27.97547,
  lon: -82.53325,
  primary_label: 'Tampa International Airport',
  secondary_label: 'Tampa, Florida, United States',
}

const times = {
  display_name: 'Times Square, Manhattan, New York, United States',
  lat: 40.758,
  lon: -73.9855,
  primary_label: 'Times Square',
  secondary_label: 'Manhattan, New York, United States',
}

function ok(results = [tampa]): GeocodeResponse {
  return { ok: true, provider: 'nominatim', cached: false, results, message: '' }
}

beforeEach(() => {
  window.localStorage.clear()
})

afterEach(() => {
  vi.restoreAllMocks()
  window.localStorage.clear()
})

async function flushDebounce(ms = 500) {
  await act(async () => {
    await new Promise(resolve => window.setTimeout(resolve, ms + 10))
  })
}

describe('LocationSearch', () => {
  it('renders, accepts typing, and clears without erasing selection externally', () => {
    const onSelect = vi.fn()
    render(<LocationSearch onSelect={onSelect} search={vi.fn()} debounceMs={20} />)
    const input = screen.getByLabelText('Search for a place or address')
    fireEvent.change(input, { target: { value: 'Tampa' } })
    expect(input).toHaveValue('Tampa')
    fireEvent.click(screen.getByLabelText('Clear location search'))
    expect(input).toHaveValue('')
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('does not search short queries and debounces valid queries', async () => {
    const search = vi.fn().mockResolvedValue(ok())
    render(<LocationSearch onSelect={vi.fn()} search={search} debounceMs={20} />)
    fireEvent.change(screen.getByLabelText('Search for a place or address'), { target: { value: 'Ta' } })
    await flushDebounce(20)
    expect(search).not.toHaveBeenCalled()

    fireEvent.change(screen.getByLabelText('Search for a place or address'), { target: { value: 'Tam' } })
    await act(async () => { await new Promise(resolve => window.setTimeout(resolve, 5)) })
    expect(search).not.toHaveBeenCalled()
    await flushDebounce(20)
    await waitFor(() => expect(search).toHaveBeenCalledWith('Tam', expect.any(AbortSignal)))
  })

  it('shows loading and renders results', async () => {
    let resolve!: (value: GeocodeResponse) => void
    const search = vi.fn().mockReturnValue(new Promise<GeocodeResponse>(res => { resolve = res }))
    render(<LocationSearch onSelect={vi.fn()} search={search} debounceMs={20} />)
    fireEvent.change(screen.getByLabelText('Search for a place or address'), { target: { value: 'Tampa' } })
    await flushDebounce(20)
    expect(screen.getByText('Searching...')).toBeInTheDocument()
    await act(async () => resolve(ok()))
    expect(await screen.findByText('Tampa International Airport')).toBeInTheDocument()
    expect(screen.getByText('Tampa, Florida, United States')).toBeInTheDocument()
  })

  it('ignores stale search responses', async () => {
    let resolveA!: (value: GeocodeResponse) => void
    let resolveB!: (value: GeocodeResponse) => void
    const search = vi
      .fn()
      .mockReturnValueOnce(new Promise<GeocodeResponse>(res => { resolveA = res }))
      .mockReturnValueOnce(new Promise<GeocodeResponse>(res => { resolveB = res }))
    render(<LocationSearch onSelect={vi.fn()} search={search} debounceMs={20} />)
    const input = screen.getByLabelText('Search for a place or address')

    fireEvent.change(input, { target: { value: 'Tam' } })
    await flushDebounce(20)
    fireEvent.change(input, { target: { value: 'Tampa' } })
    await flushDebounce(20)
    await act(async () => resolveB(ok([tampa])))
    await act(async () => resolveA(ok([times])))

    expect(screen.getByText('Tampa International Airport')).toBeInTheDocument()
    expect(screen.queryByText('Times Square')).not.toBeInTheDocument()
  })

  it('clicks, enters, and arrow-navigates results', async () => {
    const onSelect = vi.fn()
    const search = vi.fn().mockResolvedValue(ok([tampa, times]))
    render(<LocationSearch onSelect={onSelect} search={search} debounceMs={20} />)
    const input = screen.getByLabelText('Search for a place or address')
    fireEvent.change(input, { target: { value: 'Tampa' } })
    await flushDebounce(20)
    expect(await screen.findByText('Tampa International Airport')).toBeInTheDocument()
    fireEvent.click(screen.getByText('Tampa International Airport'))
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ lat: tampa.lat, lon: tampa.lon }))

    fireEvent.change(input, { target: { value: 'Times' } })
    await flushDebounce(20)
    await screen.findByText('Times Square')
    fireEvent.keyDown(input, { key: 'ArrowDown' })
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(onSelect).toHaveBeenLastCalledWith(expect.objectContaining({ primary_label: 'Times Square' }))
  })

  it('Escape closes the dropdown', async () => {
    const search = vi.fn().mockResolvedValue(ok())
    render(<LocationSearch onSelect={vi.fn()} search={search} debounceMs={20} />)
    const input = screen.getByLabelText('Search for a place or address')
    fireEvent.change(input, { target: { value: 'Tampa' } })
    await flushDebounce(20)
    expect(await screen.findByText('Tampa International Airport')).toBeInTheDocument()
    fireEvent.keyDown(input, { key: 'Escape' })
    expect(screen.queryByText('Tampa International Airport')).not.toBeInTheDocument()
  })

  it('shows no-result and provider-error states', async () => {
    const { rerender } = render(<LocationSearch onSelect={vi.fn()} search={vi.fn().mockResolvedValue(ok([]))} debounceMs={20} />)
    fireEvent.change(screen.getByLabelText('Search for a place or address'), { target: { value: 'zzzz' } })
    await flushDebounce(20)
    expect(await screen.findByText('No locations found.')).toBeInTheDocument()

    rerender(<LocationSearch onSelect={vi.fn()} search={vi.fn().mockRejectedValue(new Error('offline'))} debounceMs={20} />)
    fireEvent.change(screen.getByLabelText('Search for a place or address'), { target: { value: 'Orlando' } })
    await flushDebounce(20)
    expect(await screen.findByText(/Location search unavailable/)).toBeInTheDocument()
  })

  it('parses coordinate pairs locally', async () => {
    const onSelect = vi.fn()
    const search = vi.fn()
    render(<LocationSearch onSelect={onSelect} search={search} debounceMs={20} />)
    fireEvent.change(screen.getByLabelText('Search for a place or address'), { target: { value: '28.538336, -81.379234' } })
    await flushDebounce(20)
    expect(screen.getByText('Coordinates')).toBeInTheDocument()
    fireEvent.click(screen.getByText('Coordinates'))
    expect(search).not.toHaveBeenCalled()
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ lat: 28.538336, lon: -81.379234 }))
    expect(parseCoordinateQuery('100, 20')).toBeNull()
  })
})
