import React from 'react'
import { DriveTestingMethod, DriveTestingPreset, DriveTestingProfile, DriveTestingProfileSettings } from '../../api/client'
import { button, buttonRow, field, grid2, grid3, input, notice, section, sectionTitle } from './styles'

interface Props {
  presets: DriveTestingPreset[]
  settings: DriveTestingProfileSettings
  profile: DriveTestingProfile | null
  onSettings: (settings: DriveTestingProfileSettings) => void
  onGenerate: () => Promise<void>
  onError: (message: string) => void
}

const defaultSettings: DriveTestingProfileSettings = { name: 'Constant 20 mph', kind: 'constant', method: 'timed_static', target_speed_mph: 20, distance_miles: 0.6, update_interval_s: 1, timing_variation_s: 0, random_seed: 1 }

export default function ProfilePanel({ presets, settings, profile, onSettings, onGenerate, onError }: Props) {
  const update = (key: keyof DriveTestingProfileSettings, value: any) => onSettings({ ...settings, [key]: value })
  const loadPreset = (id: string) => {
    const preset = presets.find(item => item.id === id)
    if (preset) onSettings({ ...preset })
  }
  const save = () => {
    localStorage.setItem('iossim-drive-testing-profile', JSON.stringify(settings))
  }
  const loadSaved = () => {
    try {
      const stored = localStorage.getItem('iossim-drive-testing-profile')
      if (!stored) throw new Error('No saved profile exists in this browser.')
      onSettings(JSON.parse(stored))
    } catch (error: any) { onError(error.message) }
  }

  return (
    <>
      <section style={section}>
        <div style={sectionTitle}>Test Method and Profile</div>
        <div style={grid2}>
          <label style={field}>Preset<select style={input} value={settings.id ?? ''} onChange={e => loadPreset(e.target.value)}><option value="">Custom profile</option>{presets.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
          <label style={field}>Test method<select style={input} value={settings.method} onChange={e => update('method', e.target.value as DriveTestingMethod)}><option value="timed_static">Timed coordinate updates - Current Drive Mode mechanism</option><option value="legacy_gpx">Legacy coordinate-only GPX</option><option value="timestamped_gpx">Timestamped GPX experiment</option><option value="gpx_pacing">GPX pacing variations</option><option value="stable_baseline">Existing Drive Mode baseline</option></select></label>
          <label style={field}>Profile model<select style={input} value={settings.kind} onChange={e => update('kind', e.target.value)}><option value="stationary">Stationary baseline</option><option value="constant">Constant apparent speed</option><option value="acceleration">Gradual acceleration</option><option value="deceleration">Gradual deceleration</option><option value="city">City</option><option value="suburban">Suburban</option><option value="highway">Highway</option><option value="instant_jumps">Negative control - instant jumps</option><option value="impossible_speed">Negative control - impossible speed</option><option value="repeated_points">Negative control - repeated points</option><option value="irregular_timing">Negative control - irregular timing</option></select></label>
          <label style={field}>Profile name<input style={input} value={settings.name ?? ''} onChange={e => update('name', e.target.value)} /></label>
          <label style={field}>Host-planned apparent speed (mph)<input style={input} type="number" min={0} max={500} step={1} value={settings.target_speed_mph} onChange={e => update('target_speed_mph', Number(e.target.value))} /></label>
          <label style={field}>Requested distance<select style={input} value={settings.distance_miles} onChange={e => update('distance_miles', Number(e.target.value))}><option value={0.4}>0.4 mile</option><option value={0.5}>0.5 mile</option><option value={0.6}>0.6 mile</option><option value={1}>1.0 mile</option><option value={2}>2.0 miles</option></select></label>
          <label style={field}>Update interval<select style={input} value={settings.update_interval_s} onChange={e => update('update_interval_s', Number(e.target.value))}><option value={1}>1 second</option><option value={2}>2 seconds</option><option value={3}>3 seconds</option><option value={5}>5 seconds</option></select></label>
          <label style={field}>Bounded timing variation (seconds)<input style={input} type="number" min={0} max={Math.max(0, settings.update_interval_s * .45)} step={0.1} value={settings.timing_variation_s ?? 0} onChange={e => update('timing_variation_s', Number(e.target.value))} /></label>
          <label style={field}>Deterministic random seed<input style={input} type="number" value={settings.random_seed} onChange={e => update('random_seed', Number(e.target.value))} /></label>
          <label style={field}>Acceleration/deceleration duration<input style={input} type="number" min={1} max={120} value={settings.transition_s ?? 15} onChange={e => update('transition_s', Number(e.target.value))} /></label>
        </div>
        {(settings.negative_control || settings.kind.startsWith('instant') || settings.kind.startsWith('impossible') || settings.kind.startsWith('repeated') || settings.kind.startsWith('irregular')) && <div style={{ ...notice('warning'), marginTop: 10 }}>Negative control - intentionally unrealistic. Use it to validate analysis and QC, not as a recommended profile.</div>}
        <div style={{ ...notice('info'), marginTop: 10 }}>GPX timestamps control pymobiledevice3 host pacing only. They do not inject CLLocation.speed or CLLocation.course.</div>
        <div style={{ ...buttonRow, marginTop: 12 }}>
          <button style={button()} onClick={() => loadPreset(settings.id ?? '')}>Load Preset</button>
          <button style={button('primary')} onClick={onGenerate}>Generate Profile</button>
          <button style={button()} disabled={!profile} onClick={() => profile && onError(`Profile preview: ${profile.samples.length} samples over ${profile.planned_duration_s.toFixed(1)} seconds.`)}>Preview Profile</button>
          <button style={button()} onClick={() => onSettings(defaultSettings)}>Reset Profile</button>
          <button style={button()} onClick={save}>Save Profile</button>
          <button style={button()} onClick={loadSaved}>Load Saved</button>
        </div>
      </section>
      {profile && <section style={section}><div style={sectionTitle}>Generated Profile Summary</div><div style={grid3}>
        <Summary label="Samples" value={String(profile.samples.length)} />
        <Summary label="Requested distance" value={`${(profile.requested_distance_m / 1609.344).toFixed(3)} mi`} />
        <Summary label="Generated distance" value={`${(profile.generated_distance_m / 1609.344).toFixed(3)} mi`} />
        <Summary label="Difference" value={`${profile.distance_difference_m.toFixed(3)} m (${profile.distance_error_percent.toFixed(3)}%)`} />
        <Summary label="Calculated duration" value={`${profile.planned_duration_s.toFixed(1)} s`} />
        <Summary label="Host-planned apparent speed" value={`${profile.target_apparent_speed_mph.toFixed(1)} mph`} />
      </div></section>}
    </>
  )
}

function Summary({ label, value }: { label: string; value: string }) { return <div style={{ padding: 9, background: '#171a20', border: '1px solid #303640', borderRadius: 6 }}><div style={{ color: '#9aa3af', fontSize: 11 }}>{label}</div><div style={{ marginTop: 4, fontSize: 13 }}>{value}</div></div> }
