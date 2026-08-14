import React, { useState } from 'react'
import { api, DriveTestingComparison, DriveTestingHistoryRow } from '../../api/client'
import { button, buttonRow, field, input, notice, section, sectionTitle, table, tableWrap, td, th } from './styles'

interface Props { history: DriveTestingHistoryRow[]; initialSelection: string[]; onError: (message: string) => void }
const presets = ['14 vs 15 vs 16 mph', '0.4 vs 0.5 vs 0.6 mile', '1-second vs 2-second vs 5-second updates', 'constant speed vs gradual acceleration', 'constant speed vs city', 'city vs highway', 'timed static updates vs legacy GPX', 'legacy GPX vs timestamped GPX', 'stationary phone vs physically moving phone', 'Drive observations vs Trip observations']

export default function ExperimentComparison({ history, initialSelection, onError }: Props) {
  const [selected, setSelected] = useState<string[]>(initialSelection)
  const [preset, setPreset] = useState(presets[0])
  const [result, setResult] = useState<DriveTestingComparison | null>(null)
  const toggle = (id: string) => setSelected(items => items.includes(id) ? items.filter(item => item !== id) : [...items, id])
  const compare = async () => {
    if (selected.length < 2) { onError('Select at least two experiments to compare.'); return }
    try { setResult(await api.compareDriveTestingExperiments(selected, preset)) } catch (error: any) { onError(error.message) }
  }
  return <>
    <section style={section}><div style={sectionTitle}>Comparison Setup</div><label style={field}>Comparison preset<select style={input} value={preset} onChange={e => setPreset(e.target.value)}>{presets.map(item => <option key={item}>{item}</option>)}</select></label><div style={{ marginTop: 10, display: 'grid', gap: 6 }}>{history.map(row => <label key={row.experiment_id} style={{ display: 'flex', gap: 8, fontSize: 12 }}><input type="checkbox" checked={selected.includes(row.experiment_id)} onChange={() => toggle(row.experiment_id)} />{row.profile_name} - {row.method} - {row.experiment_id}</label>)}</div><div style={{ ...buttonRow, marginTop: 12 }}><button style={button('primary')} onClick={compare}>Compare Runs</button></div></section>
    {result && <section style={section}><div style={sectionTitle}>Comparison Results</div><div style={notice('warning')}>{result.disclaimer} {result.show_percentages ? 'Three or more comparable runs are included.' : 'Raw counts only because fewer than three runs are selected.'}</div><div style={{ ...tableWrap, marginTop: 10 }}><table style={table}><thead><tr><th style={th}>Experiment</th><th style={th}>Configuration</th><th style={th}>Host metrics</th><th style={th}>Manual conditions</th><th style={th}>Observed outcome</th><th style={th}>QC differences</th></tr></thead><tbody>{result.comparison.map((item: any) => <tr key={item.experiment_id}><td style={td}>{item.experiment_id}</td><td style={td}><pre>{JSON.stringify(item.configuration, null, 2)}</pre></td><td style={td}><pre>{JSON.stringify(item.host_metrics, null, 2)}</pre></td><td style={td}><pre>{JSON.stringify(item.manual_conditions, null, 2)}</pre></td><td style={td}>{item.observed_outcome}</td><td style={td}><pre>{JSON.stringify(item.qc, null, 2)}</pre></td></tr>)}</tbody></table></div><div style={{ marginTop: 10, fontSize: 12 }}>Outcome counts: {JSON.stringify(result.outcome_counts)}</div></section>}
  </>
}
