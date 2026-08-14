export interface DriveTestingFrontendFlags {
  VITE_ENABLE_EXPERIMENTAL_FEATURES?: string
  VITE_ENABLE_DRIVE_TESTING?: string
}

export function isDriveTestingFrontendEnabled(flags: DriveTestingFrontendFlags): boolean {
  return flags.VITE_ENABLE_EXPERIMENTAL_FEATURES === '1' && flags.VITE_ENABLE_DRIVE_TESTING === '1'
}
