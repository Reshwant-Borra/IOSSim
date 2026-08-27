import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, api, req } from './client'

afterEach(() => { vi.unstubAllGlobals() })

describe('structured API errors', () => {
  it('preserves status, code, message, and details', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 403, statusText: 'Forbidden', json: async () => ({ ok: false, code: 'drive_testing_disabled', message: 'Both flags are required.' }) }))
    await expect(req('GET', '/experimental/drive-testing/status')).rejects.toMatchObject({ status: 403, code: 'drive_testing_disabled', message: 'Both flags are required.' } satisfies Partial<ApiError>)
  })

  it('preserves nested detail codes from FastAPI-style errors', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 502, statusText: 'Bad Gateway', json: async () => ({ detail: { code: 'GEOCODING_PROVIDER_UNAVAILABLE', message: 'Location search provider is temporarily unavailable.' } }) }))
    await expect(req('POST', '/location/search', { query: 'Tampa' })).rejects.toMatchObject({ status: 502, code: 'GEOCODING_PROVIDER_UNAVAILABLE', message: 'Location search provider is temporarily unavailable.' } satisfies Partial<ApiError>)
  })
})

describe('location search API', () => {
  it('posts to the general location search endpoint', async () => {
    const fetch = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ ok: true, provider: 'nominatim', cached: false, results: [], message: '' }) })
    vi.stubGlobal('fetch', fetch)
    const signal = new AbortController().signal

    await api.searchLocations('Times Square', signal)

    expect(fetch).toHaveBeenCalledWith('/api/location/search', expect.objectContaining({
      method: 'POST',
      body: JSON.stringify({ query: 'Times Square', limit: 5 }),
      signal,
    }))
  })
})
