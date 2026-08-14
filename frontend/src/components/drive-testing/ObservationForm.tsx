import React, { useState } from 'react'
import { DriveTestingObservation } from '../../api/client'
import { button, buttonRow, field, grid2, input, notice, section, sectionTitle } from './styles'

interface Props { experimentId: string | null; onSubmit: (observation: DriveTestingObservation) => Promise<void>; onError: (message: string) => void }

const initial: DriveTestingObservation = { result: 'application_not_checked', checked_at: new Date().toISOString(), connectivity: 'unknown', phone_state: 'unknown', screen_state: 'unknown', application_state: 'not_checked', notes: '', interpretation: '' }

export default function ObservationForm({ experimentId, onSubmit, onError }: Props) {
  const [form, setForm] = useState<DriveTestingObservation>(initial)
  const [busy, setBusy] = useState(false)
  const set = (key: keyof DriveTestingObservation, value: any) => setForm(valueForm => ({ ...valueForm, [key]: value }))
  const submit = async () => {
    if (!experimentId) { onError('Create an experiment before recording an observation.'); return }
    setBusy(true)
    try { await onSubmit({ ...form, checked_at: form.checked_at || new Date().toISOString() }) } finally { setBusy(false) }
  }
  const toggles: [keyof DriveTestingObservation, string][] = [
    ['drive_detection_enabled', 'Drive Detection enabled'], ['arity_sharing_enabled', 'Arity sharing enabled'], ['location_permission_always', 'Location permission set to Always'], ['motion_fitness_enabled', 'Motion & Fitness permission enabled'],
    ['background_app_refresh_enabled', 'Background App Refresh enabled'], ['low_power_mode_disabled', 'Low Power Mode disabled'], ['battery_above_10_percent', 'Battery above 10 percent'], ['strong_cellular_signal', 'Strong cellular signal'], ['test_performed_by_passenger', 'Test performed by passenger'],
  ]
  return <>
    <section style={section}><div style={sectionTitle}>Manual External Observation</div><div style={notice('warning')}>This form is manual. IOSSim does not automate taps, logins, screenshots, or extraction from a third-party application.</div></section>
    <section style={section}><div style={grid2}>
      <label style={field}>Observed result<select style={input} value={form.result} onChange={e => set('result', e.target.value)}><option value="drive_observed">Drive observed</option><option value="trip_observed">Trip observed</option><option value="no_event_observed">No event observed</option><option value="still_processing">Still processing</option><option value="application_not_checked">Application not checked</option><option value="inconclusive">Inconclusive</option><option value="test_failed">Test failed</option><option value="other">Other</option></select></label>
      <label style={field}>Time result was checked<input style={input} type="datetime-local" value={(form.checked_at ?? '').slice(0, 16)} onChange={e => set('checked_at', new Date(e.target.value).toISOString())} /></label>
      <NumberField label="Delay before result appeared (seconds)" value={form.delay_before_result_s} onChange={value => set('delay_before_result_s', value)} />
      <NumberField label="Displayed distance" value={form.displayed_distance} onChange={value => set('displayed_distance', value)} />
      <NumberField label="Displayed duration (seconds)" value={form.displayed_duration_s} onChange={value => set('displayed_duration_s', value)} />
      <NumberField label="Displayed average speed (mph)" value={form.displayed_average_speed_mph} onChange={value => set('displayed_average_speed_mph', value)} />
      <NumberField label="Displayed maximum speed (mph)" value={form.displayed_maximum_speed_mph} onChange={value => set('displayed_maximum_speed_mph', value)} />
      <label style={field}>Wi-Fi or cellular<select style={input} value={form.connectivity} onChange={e => set('connectivity', e.target.value)}><option value="unknown">Unknown</option><option value="wifi">Wi-Fi</option><option value="cellular">Cellular</option><option value="both">Both</option></select></label>
      <label style={field}>Physical phone state<select style={input} value={form.phone_state} onChange={e => set('phone_state', e.target.value)}><option value="unknown">Unknown</option><option value="stationary">Phone stationary</option><option value="physically_moving">Phone physically moving</option></select></label>
      <label style={field}>Screen state<select style={input} value={form.screen_state} onChange={e => set('screen_state', e.target.value)}><option value="unknown">Unknown</option><option value="locked">Screen locked</option><option value="unlocked">Screen unlocked</option></select></label>
      <label style={field}>Third-party application state<select style={input} value={form.application_state} onChange={e => set('application_state', e.target.value)}><option value="not_checked">Not checked</option><option value="unknown">Unknown</option><option value="foreground">Foreground</option><option value="background">Background</option></select></label>
      <label style={field}>Optional screenshot filename<input style={input} value={form.screenshot_filename ?? ''} onChange={e => set('screenshot_filename', e.target.value)} placeholder="manual-screenshot.png" /></label>
    </div></section>
    <section style={section}><div style={sectionTitle}>User-Entered Test Conditions</div><div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(250px,1fr))', gap: 8 }}>{toggles.map(([key, label]) => <label key={key} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12 }}><input type="checkbox" checked={Boolean(form[key])} onChange={e => set(key, e.target.checked)} />{label}</label>)}</div></section>
    <section style={section}><div style={grid2}><label style={field}>Notes<textarea style={{ ...input, minHeight: 90 }} value={form.notes} onChange={e => set('notes', e.target.value)} /></label><label style={field}>Interpretation<textarea style={{ ...input, minHeight: 90 }} value={form.interpretation} onChange={e => set('interpretation', e.target.value)} placeholder="Association under the recorded conditions; no causal claim." /></label></div><div style={{ ...buttonRow, marginTop: 12 }}><button style={button('primary')} disabled={!experimentId || busy} onClick={submit}>{busy ? 'Saving...' : 'Record Observation'}</button><button style={button()} onClick={() => setForm({ ...initial, checked_at: new Date().toISOString() })}>Reset Form</button></div></section>
  </>
}

function NumberField({ label, value, onChange }: { label: string; value: number | undefined; onChange: (value: number | undefined) => void }) { return <label style={field}>{label}<input style={input} type="number" min={0} step="any" value={value ?? ''} onChange={e => onChange(e.target.value === '' ? undefined : Number(e.target.value))} /></label> }
