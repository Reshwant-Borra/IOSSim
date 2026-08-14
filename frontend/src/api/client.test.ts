import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, req } from './client'

afterEach(() => { vi.unstubAllGlobals() })

describe('structured API errors', () => {
  it('preserves status, code, message, and details', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 403, statusText: 'Forbidden', json: async () => ({ ok: false, code: 'drive_testing_disabled', message: 'Both flags are required.' }) }))
    await expect(req('GET', '/experimental/drive-testing/status')).rejects.toMatchObject({ status: 403, code: 'drive_testing_disabled', message: 'Both flags are required.' } satisfies Partial<ApiError>)
  })
})
