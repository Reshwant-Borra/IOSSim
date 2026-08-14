import React, { useMemo, useState } from 'react'
import { api, DriveTestingHistoryRow, DriveTestingQueueEntry, DriveTestingQueueStatus } from '../../api/client'
import { button, buttonRow, colors, field, input, notice, section, sectionTitle, table, tableWrap, td, th } from './styles'

interface Props {
  history: DriveTestingHistoryRow[]
  currentExperimentId: string | null
  status: DriveTestingQueueStatus | null
  onStatus: (status: DriveTestingQueueStatus) => void
  onError: (message: string) => void
}

export default function ExperimentQueue({ history, currentExperimentId, status, onStatus, onError }: Props) {
  const [entries, setEntries] = useState<DriveTestingQueueEntry[]>([])
  const add = (id: string | null) => {
    if (!id) { onError('Create or select an experiment before adding it to the queue.'); return }
    setEntries(items => [...items, { experiment_id: id, repeats: 1, reset_gps_after: true, delay_after_s: 15 }])
  }
  const update = (index: number, changes: Partial<DriveTestingQueueEntry>) => setEntries(items => items.map((item, i) => i === index ? { ...item, ...changes } : item))
  const move = (index: number, delta: number) => setEntries(items => { const next = [...items]; const target = index + delta; if (target < 0 || target >= next.length) return items; [next[index], next[target]] = [next[target], next[index]]; return next })
  const configure = async () => {
    try { onStatus(await api.configureDriveTestingQueue(entries)) } catch (error: any) { onError(error.message) }
  }
  const action = async (operation: () => Promise<DriveTestingQueueStatus>) => {
    try { onStatus(await operation()) } catch (error: any) { onError(error.message) }
  }
  const loadPreset = (kind: 'speed' | 'distance' | 'method') => {
    const patterns = kind === 'speed' ? ['14 mph', '15 mph', '16 mph', '20 mph', '25 mph'] : kind === 'distance' ? ['0.4', '0.5', '0.6', '1.0'] : ['stable', 'timed', 'legacy', 'timestamped', 'city', 'highway', 'negative']
    const matched = patterns.map(pattern => history.find(item => `${item.profile_name} ${item.method}`.toLowerCase().includes(pattern))).filter(Boolean) as DriveTestingHistoryRow[]
    if (!matched.length) { onError(`Create experiments matching the ${kind} queue profiles first.`); return }
    setEntries(matched.map(item => ({ experiment_id: item.experiment_id, repeats: 1, reset_gps_after: true, delay_after_s: 15 })))
  }
  const estimate = useMemo(() => entries.reduce((total, entry) => { const record = history.find(item => item.experiment_id === entry.experiment_id); return total + ((record?.actual_duration_s ?? 0) + entry.delay_after_s) * entry.repeats }, 0), [entries, history])

  return <>
    <section style={section}><div style={sectionTitle}>Experiment Queue</div>
      <div style={notice('warning')}>Default failure behavior: stop the queue and require user confirmation. Physical driving experiments are never started automatically.</div>
      <div style={{ ...buttonRow, marginTop: 10 }}><button style={button()} onClick={() => add(currentExperimentId)}>Add Current Experiment</button><button style={button()} onClick={() => loadPreset('speed')}>Speed Threshold Queue</button><button style={button()} onClick={() => loadPreset('distance')}>Distance Threshold Queue</button><button style={button()} onClick={() => loadPreset('method')}>Method Comparison Queue</button></div>
    </section>
    <section style={section}>
      {entries.length === 0 ? <div style={notice('info')}>Queue is empty.</div> : <div style={tableWrap}><table style={table}><thead><tr><th style={th}>Order</th><th style={th}>Experiment</th><th style={th}>Repeats</th><th style={th}>Reset GPS</th><th style={th}>Delay</th><th style={th}>Actions</th></tr></thead><tbody>{entries.map((entry, index) => <tr key={`${entry.experiment_id}-${index}`}><td style={td}>{index + 1}</td><td style={td}>{history.find(item => item.experiment_id === entry.experiment_id)?.profile_name ?? entry.experiment_id}</td><td style={td}><input style={{ ...input, width: 70 }} type="number" min={1} max={100} value={entry.repeats} onChange={e => update(index, { repeats: Number(e.target.value) })} /></td><td style={td}><input type="checkbox" checked={entry.reset_gps_after} onChange={e => update(index, { reset_gps_after: e.target.checked })} /></td><td style={td}><input style={{ ...input, width: 90 }} type="number" min={0} max={3600} value={entry.delay_after_s} onChange={e => update(index, { delay_after_s: Number(e.target.value) })} /></td><td style={td}><div style={buttonRow}><button style={button()} onClick={() => move(index, -1)} title="Move up">Up</button><button style={button()} onClick={() => move(index, 1)} title="Move down">Down</button><button style={button()} onClick={() => setEntries(items => [...items.slice(0, index + 1), { ...entry }, ...items.slice(index + 1)])}>Duplicate</button><button style={button('danger')} onClick={() => setEntries(items => items.filter((_, i) => i !== index))}>Remove</button></div></td></tr>)}</tbody></table></div>}
      <div style={{ ...buttonRow, marginTop: 12 }}><button style={button()} disabled={!entries.length} onClick={configure}>Validate Queue</button><button style={button('primary')} disabled={!entries.length || status?.state !== 'ready'} onClick={() => action(api.startDriveTestingQueue)}>Start Queue</button><button style={button()} disabled={status?.state !== 'running'} onClick={() => action(api.pauseDriveTestingQueue)}>Pause Current Run</button><button style={button()} disabled={status?.state !== 'paused'} onClick={() => action(api.resumeDriveTestingQueue)}>Resume Queue</button><button style={button('danger')} disabled={!['running', 'paused'].includes(status?.state ?? '')} onClick={() => action(api.stopDriveTestingQueue)}>Stop Queue</button></div>
      <div style={{ marginTop: 10, color: colors.muted, fontSize: 12 }}>Estimated total duration: {Math.round(status?.estimated_total_duration_s ?? estimate)} seconds. Queue state: {status?.state ?? 'not configured'}.</div>
      {status?.last_error && <div style={{ ...notice('danger'), marginTop: 10 }}>{status.last_error}{status.requires_confirmation ? ' Confirm the failure before continuing.' : ''}</div>}
    </section>
  </>
}
