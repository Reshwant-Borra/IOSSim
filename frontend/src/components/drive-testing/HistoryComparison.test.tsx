import React from 'react'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, DriveTestingHistoryRow } from '../../api/client'
import ExperimentComparison from './ExperimentComparison'
import ExperimentHistory from './ExperimentHistory'

const rows: DriveTestingHistoryRow[] = [
  { experiment_id: 'EXP-1', created_at: '2026-01-01T00:00:00Z', state: 'completed', run_id: 'RUN-1', repeat_number: 1, total_repeats: 1, profile_name: '14 mph', method: 'timed_static', requested_distance_m: 965, emitted_distance_m: 964, calculated_average_apparent_speed_mph: 13.9, actual_duration_s: 150, write_failures: 0, observed_result: 'trip_observed', qc_status: 'PASS', notes: 'manual' },
  { experiment_id: 'EXP-2', created_at: '2026-01-02T00:00:00Z', state: 'completed', run_id: 'RUN-2', repeat_number: 1, total_repeats: 1, profile_name: '16 mph', method: 'timestamped_gpx', requested_distance_m: 965, emitted_distance_m: 0, calculated_average_apparent_speed_mph: 0, actual_duration_s: 140, write_failures: 0, observed_result: 'no_event_observed', qc_status: 'PASS WITH WARNINGS', notes: '' },
]

afterEach(() => { vi.restoreAllMocks() })

describe('history and comparison', () => {
  it('renders history actions and requires local-delete confirmation', () => {
    render(<ExperimentHistory rows={rows} onRefresh={() => {}} onSelect={() => {}} onCompare={() => {}} onObservation={() => {}} onError={() => {}} />)
    expect(screen.getByText('EXP-1')).toBeInTheDocument()
    expect(screen.getAllByText('Record Observation')).toHaveLength(2)
    expect(screen.getByText(/does not delete third-party driving history/i)).toBeInTheDocument()
  })

  it('selects runs and displays raw counts for fewer than three comparisons', async () => {
    vi.spyOn(api, 'compareDriveTestingExperiments').mockResolvedValue({ ok: true, comparison: [], charts: [], outcome_counts: { trip_observed: 1, no_event_observed: 1 }, comparable_run_count: 2, show_percentages: false, disclaimer: 'Exploratory observations only. Not a validated success probability.' })
    render(<ExperimentComparison history={rows} initialSelection={[]} onError={() => {}} />)
    fireEvent.click(screen.getByLabelText(/14 mph/))
    fireEvent.click(screen.getByLabelText(/16 mph/))
    fireEvent.click(screen.getByText('Compare Runs'))
    await waitFor(() => expect(api.compareDriveTestingExperiments).toHaveBeenCalled())
    expect(screen.getByText(/Raw counts only/)).toBeInTheDocument()
  })
})
