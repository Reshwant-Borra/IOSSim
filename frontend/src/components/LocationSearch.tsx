import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { api, GeocodeResponse, GeocodeResult } from '../api/client'

const RECENTS_KEY = 'iossim.locationSearch.recents'
const MAX_RECENTS = 8

interface Props {
  onSelect: (result: GeocodeResult) => boolean | void
  search?: (query: string, signal?: AbortSignal) => Promise<GeocodeResponse>
  debounceMs?: number
}

export function parseCoordinateQuery(value: string): GeocodeResult | null {
  const match = value.trim().match(/^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$/)
  if (!match) return null
  const lat = Number(match[1])
  const lon = Number(match[2])
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null
  const display = `${lat.toFixed(6)}, ${lon.toFixed(6)}`
  return {
    display_name: display,
    lat,
    lon,
    primary_label: 'Coordinates',
    secondary_label: display,
    provider: 'coordinates',
  }
}

function loadRecents(): GeocodeResult[] {
  try {
    const raw = window.localStorage.getItem(RECENTS_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(isStoredResult).slice(0, MAX_RECENTS)
  } catch {
    return []
  }
}

function isStoredResult(value: unknown): value is GeocodeResult {
  if (!value || typeof value !== 'object') return false
  const item = value as Partial<GeocodeResult>
  return typeof item.display_name === 'string' && typeof item.lat === 'number' && typeof item.lon === 'number'
}

function saveRecent(result: GeocodeResult, existing: GeocodeResult[]): GeocodeResult[] {
  const stored: GeocodeResult = {
    display_name: result.display_name,
    lat: result.lat,
    lon: result.lon,
    primary_label: result.primary_label,
    secondary_label: result.secondary_label,
    provider: result.provider,
  }
  const key = `${stored.lat.toFixed(6)},${stored.lon.toFixed(6)}`
  const next = [stored, ...existing.filter(item => `${item.lat.toFixed(6)},${item.lon.toFixed(6)}` !== key)].slice(0, MAX_RECENTS)
  try {
    window.localStorage.setItem(RECENTS_KEY, JSON.stringify(next))
  } catch {
    // Search history is a convenience only; ignore storage failures.
  }
  return next
}

function labels(result: GeocodeResult): { primary: string; secondary: string } {
  if (result.primary_label || result.secondary_label) {
    return {
      primary: result.primary_label || result.display_name.split(',')[0] || result.display_name,
      secondary: result.secondary_label || result.display_name,
    }
  }
  const parts = result.display_name.split(',').map(part => part.trim()).filter(Boolean)
  return {
    primary: parts[0] || result.display_name,
    secondary: parts.slice(1, 5).join(', '),
  }
}

export default function LocationSearch({ onSelect, search = api.searchLocations, debounceMs = 500 }: Props) {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<GeocodeResult[]>([])
  const [open, setOpen] = useState(false)
  const [highlighted, setHighlighted] = useState(0)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [hasSearched, setHasSearched] = useState(false)
  const [recents, setRecents] = useState<GeocodeResult[]>(() => loadRecents())
  const requestId = useRef(0)
  const wrapperRef = useRef<HTMLDivElement | null>(null)
  const responseCache = useRef(new Map<string, GeocodeResponse>())

  const trimmed = query.trim()
  const coordinateResult = useMemo(() => parseCoordinateQuery(trimmed), [trimmed])
  const showingRecents = open && !trimmed && recents.length > 0
  const visibleResults = showingRecents ? recents : results
  const showNoResults = open && hasSearched && !loading && !error && trimmed.length >= 3 && visibleResults.length === 0

  const choose = useCallback((result: GeocodeResult) => {
    const accepted = onSelect(result)
    if (accepted === false) return
    setRecents(prev => saveRecent(result, prev))
    setQuery(result.primary_label || result.display_name)
    setResults([])
    setError('')
    setOpen(false)
    setHighlighted(0)
  }, [onSelect])

  const performSearch = useCallback(async (term: string, selectFirst = false, signal?: AbortSignal) => {
    const normalized = term.trim().toLowerCase()
    const coord = parseCoordinateQuery(term)
    if (coord) {
      setResults([coord])
      setHasSearched(true)
      setError('')
      setLoading(false)
      setOpen(true)
      if (selectFirst) choose(coord)
      return
    }
    if (normalized.length < 3) {
      setResults([])
      setHasSearched(false)
      setError('')
      setLoading(false)
      return
    }
    const id = ++requestId.current
    setLoading(true)
    setError('')
    setHasSearched(true)
    setOpen(true)
    try {
      const cached = responseCache.current.get(normalized)
      const response = cached ?? await search(term, signal)
      if (!cached) responseCache.current.set(normalized, response)
      if (id !== requestId.current || signal?.aborted) return
      setResults(response.results)
      setHighlighted(0)
      setError(response.ok ? '' : response.message || 'Location search unavailable.')
      if (selectFirst && response.results[0]) choose(response.results[0])
    } catch (e: any) {
      if (signal?.aborted || e?.name === 'AbortError') return
      if (id !== requestId.current) return
      setResults([])
      setError('Location search unavailable. Check your internet connection or select a point manually on the map.')
    } finally {
      if (id === requestId.current && !signal?.aborted) setLoading(false)
    }
  }, [choose, search])

  useEffect(() => {
    const controller = new AbortController()
    const id = window.setTimeout(() => {
      if (coordinateResult) {
        setResults([coordinateResult])
        setHasSearched(true)
        setError('')
        setLoading(false)
        setOpen(true)
        return
      }
      void performSearch(trimmed, false, controller.signal)
    }, debounceMs)
    return () => {
      window.clearTimeout(id)
      controller.abort()
    }
  }, [coordinateResult, debounceMs, performSearch, trimmed])

  useEffect(() => {
    function closeOnOutsideClick(event: MouseEvent) {
      if (!wrapperRef.current?.contains(event.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', closeOnOutsideClick)
    return () => document.removeEventListener('mousedown', closeOnOutsideClick)
  }, [])

  const clearSearch = () => {
    requestId.current += 1
    setQuery('')
    setResults([])
    setError('')
    setLoading(false)
    setHasSearched(false)
    setOpen(false)
    setHighlighted(0)
  }

  const clearRecents = () => {
    setRecents([])
    try {
      window.localStorage.removeItem(RECENTS_KEY)
    } catch {
      // ignore
    }
  }

  const submit = (event: React.FormEvent) => {
    event.preventDefault()
    if (visibleResults[highlighted]) {
      choose(visibleResults[highlighted])
      return
    }
    if (visibleResults[0]) {
      choose(visibleResults[0])
      return
    }
    void performSearch(trimmed, true)
  }

  const onKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setOpen(true)
      setHighlighted(prev => Math.min(prev + 1, Math.max(visibleResults.length - 1, 0)))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setHighlighted(prev => Math.max(prev - 1, 0))
    } else if (event.key === 'Escape') {
      event.preventDefault()
      setOpen(false)
    } else if (event.key === 'Enter') {
      event.preventDefault()
      if (visibleResults[highlighted]) {
        choose(visibleResults[highlighted])
      } else if (visibleResults[0]) {
        choose(visibleResults[0])
      } else {
        void performSearch(trimmed, true)
      }
    }
  }

  return (
    <>
      <style>{'@keyframes iossim-spin { to { transform: rotate(360deg); } }'}</style>
      <div style={wrapper} ref={wrapperRef}>
        <form style={searchBox} onSubmit={submit}>
          <span style={searchIcon} aria-hidden="true">⌕</span>
          <input
            aria-label="Search for a place or address"
            aria-controls="location-search-results"
            aria-expanded={open}
            role="combobox"
            style={input}
            value={query}
            onChange={event => { setQuery(event.target.value); setOpen(true) }}
            onFocus={() => setOpen(true)}
            onKeyDown={onKeyDown}
            placeholder="Search for a place or address"
            autoComplete="off"
          />
          {loading && <span style={spinner} aria-label="Searching" />}
          {query && (
            <button type="button" style={clearBtn} onClick={clearSearch} aria-label="Clear location search">
              ×
            </button>
          )}
        </form>

        {open && (visibleResults.length > 0 || loading || error || showNoResults || showingRecents) && (
          <div id="location-search-results" role="listbox" style={dropdown}>
            {showingRecents && (
              <div style={dropdownHeader}>
                <span>Recent</span>
                <button type="button" style={clearRecentsBtn} onClick={clearRecents}>Clear</button>
              </div>
            )}
            {visibleResults.map((result, index) => {
              const text = labels(result)
              return (
                <button
                  key={`${result.lat}:${result.lon}:${result.display_name}`}
                  type="button"
                  role="option"
                  aria-selected={index === highlighted}
                  style={{ ...resultBtn, ...(index === highlighted ? resultBtnActive : null) }}
                  onMouseEnter={() => setHighlighted(index)}
                  onMouseDown={event => event.preventDefault()}
                  onClick={() => choose(result)}
                >
                  <span style={resultPrimary}>{text.primary}</span>
                  {text.secondary && <span style={resultSecondary} title={result.display_name}>{text.secondary}</span>}
                </button>
              )
            })}
            {loading && <div style={stateRow}>Searching...</div>}
            {showNoResults && (
              <div style={stateRow}>
                <div>No locations found.</div>
                <div style={stateSub}>Try a city, place name, or full address.</div>
              </div>
            )}
            {error && <div style={{ ...stateRow, color: '#fecaca' }}>{error}</div>}
          </div>
        )}
      </div>
    </>
  )
}

const wrapper: React.CSSProperties = {
  position: 'absolute',
  top: 18,
  left: 18,
  width: 'min(440px, calc(100% - 36px))',
  zIndex: 1200,
}
const searchBox: React.CSSProperties = {
  height: 44,
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  padding: '0 10px 0 12px',
  background: '#13131a',
  border: '1px solid #303044',
  borderRadius: 8,
  boxShadow: '0 10px 28px rgba(0, 0, 0, 0.38)',
}
const searchIcon: React.CSSProperties = { color: '#a5b4fc', fontSize: 19, lineHeight: 1 }
const input: React.CSSProperties = {
  flex: 1,
  minWidth: 0,
  border: 'none',
  outline: 'none',
  background: 'transparent',
  color: '#f4f4fb',
  fontSize: 14,
}
const clearBtn: React.CSSProperties = {
  width: 28,
  height: 28,
  border: '1px solid #34344c',
  borderRadius: 6,
  background: '#1a1a26',
  color: '#c7c7d4',
  cursor: 'pointer',
  fontSize: 18,
  lineHeight: '20px',
}
const spinner: React.CSSProperties = {
  width: 14,
  height: 14,
  borderRadius: '50%',
  border: '2px solid #303044',
  borderTopColor: '#8b8bff',
  animation: 'iossim-spin 0.8s linear infinite',
}
const dropdown: React.CSSProperties = {
  marginTop: 6,
  maxHeight: 318,
  overflowY: 'auto',
  background: '#13131a',
  border: '1px solid #303044',
  borderRadius: 8,
  boxShadow: '0 16px 36px rgba(0, 0, 0, 0.44)',
}
const dropdownHeader: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
  padding: '8px 12px',
  color: '#8888aa',
  fontSize: 11,
  fontWeight: 700,
  textTransform: 'uppercase',
}
const clearRecentsBtn: React.CSSProperties = {
  border: 'none',
  background: 'transparent',
  color: '#a5b4fc',
  cursor: 'pointer',
  fontSize: 11,
}
const resultBtn: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 3,
  width: '100%',
  padding: '10px 12px',
  border: 'none',
  borderTop: '1px solid #252536',
  background: 'transparent',
  color: '#f4f4fb',
  cursor: 'pointer',
  textAlign: 'left',
}
const resultBtnActive: React.CSSProperties = { background: '#232347' }
const resultPrimary: React.CSSProperties = { fontSize: 13, fontWeight: 700, overflowWrap: 'anywhere' }
const resultSecondary: React.CSSProperties = {
  color: '#a7a7bd',
  fontSize: 12,
  lineHeight: 1.35,
  overflow: 'hidden',
  display: '-webkit-box',
  WebkitLineClamp: 2,
  WebkitBoxOrient: 'vertical',
}
const stateRow: React.CSSProperties = { padding: '12px', color: '#c7c7d4', fontSize: 13, lineHeight: 1.4, borderTop: '1px solid #252536' }
const stateSub: React.CSSProperties = { marginTop: 2, color: '#8888aa', fontSize: 12 }
