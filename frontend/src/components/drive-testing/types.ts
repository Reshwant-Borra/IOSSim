import type { DriveTestingExperimentStatus, DriveTestingProfile, DriveTestingProfileSettings, DriveTestingHistoryRow, LatLon } from '../../api/client'

export interface LabMapState {
  route: LatLon[]
  samples: LatLon[]
  currentSample: number
  currentCoordinate: LatLon | null
  start: LatLon | null
  destination: LatLon | null
}

export interface LabRouteState {
  coordinates: LatLon[]
  start: LatLon | null
  destination: LatLon | null
  provider: string
  cached: boolean
  distance_m: number
  osrm_duration_s: number
  name: string
}

export interface LabProfileState {
  settings: DriveTestingProfileSettings
  generated: DriveTestingProfile | null
}

export interface LabSharedProps {
  route: LabRouteState | null
  profile: DriveTestingProfile | null
  experimentId: string | null
  liveStatus: DriveTestingExperimentStatus | null
  history: DriveTestingHistoryRow[]
}
