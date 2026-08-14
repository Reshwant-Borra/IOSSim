import type React from 'react'

export const colors = {
  bg: '#101217',
  panel: '#171a20',
  panel2: '#1d2329',
  border: '#303640',
  text: '#eef1f5',
  muted: '#9aa3af',
  accent: '#2f8b83',
  accent2: '#5da9e9',
  warning: '#f2b84b',
  danger: '#ef6461',
  success: '#45c486',
  info: '#70a5ff',
}

export const overlay: React.CSSProperties = {
  position: 'absolute',
  inset: '0 auto 0 0',
  width: 'min(980px, 82%)',
  minWidth: 700,
  zIndex: 820,
  background: 'rgba(10,12,16,0.98)',
  borderRight: `1px solid ${colors.border}`,
  boxShadow: '16px 0 36px rgba(0,0,0,.36)',
  display: 'flex',
  flexDirection: 'column',
  color: colors.text,
  overflow: 'hidden',
}

export const header: React.CSSProperties = {
  minHeight: 76,
  padding: '14px 18px',
  borderBottom: `1px solid ${colors.border}`,
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 16,
  background: colors.bg,
}

export const headerTitle: React.CSSProperties = { fontSize: 18, fontWeight: 760, letterSpacing: 0 }
export const body: React.CSSProperties = { display: 'grid', gridTemplateColumns: '220px minmax(0, 1fr)', flex: 1, minHeight: 0 }
export const stagesNav: React.CSSProperties = { borderRight: `1px solid ${colors.border}`, padding: 10, display: 'flex', flexDirection: 'column', gap: 5, overflowY: 'auto', background: '#12151a' }
export const content: React.CSSProperties = { overflowY: 'auto', minWidth: 0, padding: 16 }
export const section: React.CSSProperties = { marginBottom: 16, paddingBottom: 16, borderBottom: `1px solid ${colors.border}` }
export const sectionTitle: React.CSSProperties = { fontSize: 14, fontWeight: 720, marginBottom: 10, letterSpacing: 0 }
export const grid2: React.CSSProperties = { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(230px, 1fr))', gap: 10 }
export const grid3: React.CSSProperties = { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 10 }
export const field: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 5, fontSize: 12, color: colors.muted, minWidth: 0 }
export const input: React.CSSProperties = { width: '100%', minHeight: 36, padding: '7px 9px', background: colors.panel, border: `1px solid ${colors.border}`, borderRadius: 6, color: colors.text, fontSize: 13 }
export const buttonRow: React.CSSProperties = { display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'center' }
export const tableWrap: React.CSSProperties = { overflowX: 'auto', border: `1px solid ${colors.border}`, borderRadius: 6 }
export const table: React.CSSProperties = { width: '100%', borderCollapse: 'collapse', fontSize: 12 }
export const th: React.CSSProperties = { padding: '8px 9px', textAlign: 'left', color: colors.muted, borderBottom: `1px solid ${colors.border}`, background: colors.panel, whiteSpace: 'nowrap' }
export const td: React.CSSProperties = { padding: '8px 9px', borderBottom: `1px solid ${colors.border}`, verticalAlign: 'top' }

export const button = (tone: 'primary' | 'secondary' | 'danger' = 'secondary'): React.CSSProperties => ({
  minHeight: 36,
  padding: '7px 11px',
  borderRadius: 6,
  border: tone === 'secondary' ? `1px solid ${colors.border}` : '1px solid transparent',
  background: tone === 'primary' ? colors.accent : tone === 'danger' ? '#6d292b' : colors.panel2,
  color: colors.text,
  cursor: 'pointer',
  fontSize: 13,
  fontWeight: tone === 'primary' ? 680 : 520,
  whiteSpace: 'normal',
})

export const stageButton = (active: boolean): React.CSSProperties => ({
  width: '100%',
  minHeight: 42,
  padding: '8px 9px',
  border: active ? `1px solid ${colors.accent}` : '1px solid transparent',
  background: active ? '#173432' : 'transparent',
  color: active ? '#d8fff7' : colors.muted,
  borderRadius: 6,
  cursor: 'pointer',
  textAlign: 'left',
  fontSize: 12,
  fontWeight: active ? 680 : 520,
})

export const statusPill = (tone: string): React.CSSProperties => ({
  display: 'inline-flex',
  alignItems: 'center',
  minHeight: 24,
  padding: '3px 8px',
  borderRadius: 5,
  border: `1px solid ${tone}`,
  color: tone,
  fontSize: 11,
  fontWeight: 760,
})

export const notice = (tone: 'info' | 'warning' | 'danger' | 'success' = 'info'): React.CSSProperties => ({
  padding: '9px 11px',
  borderRadius: 6,
  border: `1px solid ${tone === 'warning' ? '#6a5223' : tone === 'danger' ? '#6e3233' : tone === 'success' ? '#245e48' : '#304b76'}`,
  background: tone === 'warning' ? '#241f13' : tone === 'danger' ? '#251617' : tone === 'success' ? '#12241d' : '#151e2e',
  color: tone === 'warning' ? '#f2c96f' : tone === 'danger' ? '#ff9a98' : tone === 'success' ? '#83dfb8' : '#a9c8ff',
  fontSize: 12,
  lineHeight: 1.45,
})

export const metric: React.CSSProperties = { minHeight: 62, padding: 10, border: `1px solid ${colors.border}`, background: colors.panel, borderRadius: 6 }
export const metricLabel: React.CSSProperties = { color: colors.muted, fontSize: 11, marginBottom: 5 }
export const metricValue: React.CSSProperties = { color: colors.text, fontSize: 15, fontWeight: 700, overflowWrap: 'anywhere' }
