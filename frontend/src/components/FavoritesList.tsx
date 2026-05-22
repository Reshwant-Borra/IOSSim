import React, { useEffect, useState } from 'react'
import { api, Favorite, LatLon } from '../api/client'

interface Props {
  onSelect: (loc: LatLon) => void
  currentLoc: LatLon | null
}

export default function FavoritesList({ onSelect, currentLoc }: Props) {
  const [favorites, setFavorites] = useState<Favorite[]>([])
  const [name, setName] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const load = () => api.listFavorites().then(setFavorites).catch(() => {})
  useEffect(() => { load() }, [])

  const save = async () => {
    if (!currentLoc) { setError('Set a location on the map first.'); return }
    if (!name.trim()) { setError('Enter a name.'); return }
    setSaving(true)
    try {
      await api.addFavorite(name.trim(), currentLoc.lat, currentLoc.lon)
      setName('')
      setError('')
      await load()
    } catch (e: any) {
      setError(e.message)
    } finally {
      setSaving(false)
    }
  }

  const del = async (id: number) => {
    await api.deleteFavorite(id).catch(() => {})
    await load()
  }

  return (
    <div style={panel}>
      <div style={title}>Favorites</div>

      <div style={addRow}>
        <input
          style={input}
          placeholder="Name this spot…"
          value={name}
          onChange={e => setName(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && save()}
        />
        <button style={addBtn} onClick={save} disabled={saving}>Save</button>
      </div>
      {error && <div style={errStyle}>{error}</div>}

      <div style={{ marginTop: 10 }}>
        {favorites.length === 0 && <div style={empty}>No favorites yet</div>}
        {favorites.map(f => (
          <div key={f.id} style={item}>
            <button style={itemBtn} onClick={() => onSelect({ lat: f.lat, lon: f.lon })}>
              <span style={itemName}>{f.name}</span>
              <span style={coords}>{f.lat.toFixed(4)}, {f.lon.toFixed(4)}</span>
            </button>
            <button style={delBtn} onClick={() => del(f.id)} title="Delete">✕</button>
          </div>
        ))}
      </div>
    </div>
  )
}

const panel: React.CSSProperties = { padding: '16px', borderBottom: '1px solid #2a2a38' }
const title: React.CSSProperties = { fontWeight: 700, marginBottom: 10, fontSize: 13, letterSpacing: '0.05em', textTransform: 'uppercase', color: '#8888aa' }
const addRow: React.CSSProperties = { display: 'flex', gap: 6 }
const input: React.CSSProperties = { flex: 1, background: '#1a1a26', border: '1px solid #2a2a40', borderRadius: 6, padding: '6px 10px', color: '#e8e8f0', fontSize: 13 }
const addBtn: React.CSSProperties = { background: '#2a2a40', border: 'none', borderRadius: 6, padding: '6px 12px', color: '#e8e8f0', cursor: 'pointer', fontSize: 13 }
const errStyle: React.CSSProperties = { color: '#f87171', fontSize: 12, marginTop: 6 }
const empty: React.CSSProperties = { color: '#555', fontSize: 12, textAlign: 'center', padding: '10px 0' }
const item: React.CSSProperties = { display: 'flex', alignItems: 'center', marginBottom: 4, borderRadius: 6, overflow: 'hidden' }
const itemBtn: React.CSSProperties = { flex: 1, background: '#1a1a26', border: '1px solid #2a2a38', borderRight: 'none', padding: '7px 10px', cursor: 'pointer', textAlign: 'left', borderRadius: '6px 0 0 6px' }
const itemName: React.CSSProperties = { display: 'block', color: '#e8e8f0', fontSize: 13, fontWeight: 500 }
const coords: React.CSSProperties = { display: 'block', color: '#666', fontSize: 11, marginTop: 2 }
const delBtn: React.CSSProperties = { background: '#1a1a26', border: '1px solid #2a2a38', padding: '7px 8px', cursor: 'pointer', color: '#666', borderRadius: '0 6px 6px 0', fontSize: 11 }
