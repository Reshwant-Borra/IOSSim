export interface WirelessTestingFrontendFlags {
  VITE_ENABLE_EXPERIMENTAL_FEATURES?: string
  VITE_ENABLE_WIRELESS_TESTING?: string
}

export function isWirelessTestingFrontendEnabled(flags: WirelessTestingFrontendFlags): boolean {
  return flags.VITE_ENABLE_EXPERIMENTAL_FEATURES === '1' && flags.VITE_ENABLE_WIRELESS_TESTING === '1'
}
