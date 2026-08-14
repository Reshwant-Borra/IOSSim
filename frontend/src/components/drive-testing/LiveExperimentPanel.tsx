import React from 'react'
import { DriveTestingChartPoint, DriveTestingExperimentStatus } from '../../api/client'
import { colors, grid3, metric, metricLabel, metricValue, notice, section, sectionTitle, statusPill } from './styles'

export default function LiveExperimentPanel({ status }: { status: DriveTestingExperimentStatus | null }) {
  if (!status || !status.experiment_id) return <div style={notice('info')}>No experiment has been created in this lab session.</div>
  const rows: [string, string][] = [
    ['Experiment ID', status.experiment_id], ['Run ID', status.run_id ?? 'Not started'], ['Profile name', status.profile_name ?? 'Unknown'], ['Test method', status.method ?? 'Unknown'],
    ['Repeat', `${status.repeat_number} / ${status.total_repeats}`], ['Elapsed time', `${status.elapsed_s.toFixed(1)} s`], ['Estimated remaining', status.estimated_remaining_s == null ? 'Unknown' : `${status.estimated_remaining_s.toFixed(1)} s`],
    ['Current phase', status.current_phase ?? 'Not started'], ['Current coordinate', status.current_coordinate ? `${status.current_coordinate.lat.toFixed(6)}, ${status.current_coordinate.lon.toFixed(6)}` : 'Unavailable'],
    ['Current sample', `${status.current_sample} / ${status.total_samples}`], ['Completed distance', `${status.completed_distance_m.toFixed(1)} m`], ['Remaining distance', `${status.remaining_distance_m.toFixed(1)} m`],
    ['Host-planned apparent speed', `${status.host_planned_apparent_speed_mph.toFixed(2)} mph`], ['Host-calculated emitted apparent speed', `${status.host_calculated_emitted_apparent_speed_mph.toFixed(2)} mph`],
    ['Host-calculated average apparent speed', `${status.host_calculated_average_apparent_speed_mph.toFixed(2)} mph`], ['Target update interval', `${status.target_update_interval_s.toFixed(2)} s`],
    ['Actual latest update interval', status.actual_latest_update_interval_s == null ? 'Unavailable' : `${status.actual_latest_update_interval_s.toFixed(3)} s`], ['Latest timing drift', status.latest_timing_drift_s == null ? 'Unavailable' : `${status.latest_timing_drift_s.toFixed(3)} s`],
    ['Latest command latency', status.latest_command_latency_s == null ? 'Unavailable' : `${status.latest_command_latency_s.toFixed(3)} s`], ['Successful location writes', String(status.successful_location_writes)],
    ['Failed location writes', String(status.failed_location_writes)], ['Active subprocess PID', status.active_subprocess_pid == null ? 'Unavailable' : String(status.active_subprocess_pid)],
    ['Device connection', status.device_connected ? 'Connected' : 'Disconnected'], ['Tunnel status', status.tunnel_active ? 'Active' : 'Inactive / not required'], ['Last error', status.last_error ?? 'None'],
  ]
  return <>
    <section style={section}><div style={{ display: 'flex', gap: 10, alignItems: 'center', marginBottom: 12 }}><div style={sectionTitle}>Live Experiment</div><span style={statusPill(status.state === 'completed' ? colors.success : status.state === 'error' ? colors.danger : colors.info)}>{status.state.toUpperCase()}</span></div>
      <div style={grid3}>{rows.map(([label, value]) => <div style={metric} key={label}><div style={metricLabel}>{label}</div><div style={{ ...metricValue, fontSize: value.length > 28 ? 12 : 15 }}>{value}</div></div>)}</div>
      {status.message && <div style={{ ...notice(status.last_error ? 'danger' : 'info'), marginTop: 10 }}>{status.message}</div>}
    </section>
    <section style={section}><div style={sectionTitle}>Live Host Charts</div><div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(260px,1fr))', gap: 10 }}>
      <Spark title="Planned and emitted apparent speed" points={status.chart_points} keys={['planned_speed_mph', 'emitted_speed_mph']} colors={[colors.accent, colors.accent2]} />
      <Spark title="Cumulative distance" points={status.chart_points} keys={['distance_m']} colors={[colors.info]} />
      <Spark title="Timing drift" points={status.chart_points} keys={['timing_drift_s']} colors={[colors.warning]} />
      <Spark title="Command latency" points={status.chart_points} keys={['latency_s']} colors={[colors.danger]} />
    </div></section>
  </>
}

function Spark({ title, points, keys, colors: lineColors }: { title: string; points: DriveTestingChartPoint[]; keys: (keyof DriveTestingChartPoint)[]; colors: string[] }) {
  const width = 320, height = 110, pad = 12
  const values = points.flatMap(point => keys.map(key => Number(point[key]) || 0))
  const max = Math.max(...values, 1), min = Math.min(...values, 0), range = Math.max(.0001, max - min)
  const pathFor = (key: keyof DriveTestingChartPoint) => points.map((point, index) => `${index ? 'L' : 'M'} ${(pad + index * (width - pad * 2) / Math.max(1, points.length - 1)).toFixed(1)} ${(height - pad - ((Number(point[key]) || 0) - min) / range * (height - pad * 2)).toFixed(1)}`).join(' ')
  return <div style={{ border: `1px solid ${colors.border}`, borderRadius: 6, background: colors.panel, padding: 9 }}><div style={{ color: colors.muted, fontSize: 11, marginBottom: 5 }}>{title}</div><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={title} style={{ width: '100%', height: 110, display: 'block' }}><line x1={pad} y1={height - pad} x2={width - pad} y2={height - pad} stroke={colors.border} />{keys.map((key, i) => <path key={key} d={pathFor(key)} fill="none" stroke={lineColors[i]} strokeWidth="2" />)}</svg></div>
}
