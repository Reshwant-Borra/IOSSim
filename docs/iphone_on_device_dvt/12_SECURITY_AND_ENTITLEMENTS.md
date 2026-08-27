# Security And Entitlements

## Developer Mode

STATUS: CONFIRMED

Apple documentation states Developer Mode is required for development workflows such as Xcode run/install and protects users from developer-only attack surface. Locus/Mirage setup requires Developer Mode for pairing/developer location behavior. IOSSim POC should require Developer Mode enabled and document the user-visible prompts.

## NetworkExtension

STATUS: CONFIRMED

Packet Tunnel providers require `com.apple.developer.networking.networkextension` with `packet-tunnel-provider`. Managing VPN configurations uses NetworkExtension APIs and may require the VPN API entitlement.

Distribution impact:

- Personal sideload: may not be able to use Packet Tunnel entitlement directly; external LocalDevVPN can supply the tunnel.
- Paid developer account: likely required to build an app with its own Packet Tunnel extension.
- TestFlight/App Store: possible entitlement and review blockers; WLOC/MITM apps have documented rejection. DVT self-location behavior may also be review-sensitive.

## Local Network Permission

STATUS: STRONG EVIDENCE

iOS 27 pairable-host flows use Bonjour/NWListener and require Local Network permission so Settings/Developer Mode can discover the advertised host-like service.

## Keychain And File Protection

STATUS: REQUIRED

RPPairing material contains a private signing key. POC storage should use:

- Keychain item with accessible-after-first-unlock or when-unlocked class chosen deliberately.
- Or an app container file with `NSFileProtectionComplete` and no iCloud backup unless explicitly chosen.
- Redacted diagnostics by default.

## Sensitive Artifacts

STATUS: IMPLEMENTED FOR RESEARCH FOLDER

This research folder includes a folder-local `.gitignore` for:

- `pairing/`
- `secrets/`
- `*.mobiledevicepairing`
- `*.mobiledevicepair`
- `*.rpPairing`
- `*.rppairing`
- `rp_pairing_file.plist`
- `host_pairing_file.plist`
- `selfIdentity.plist`

Before a POC creates artifacts elsewhere, add equivalent path-specific ignore rules there.

## Shipping Constraints

STATUS: UNKNOWN / RISK

An IOSSim self-DVT app may be easiest as a sideload/developer tool. App Store eligibility is not established. TestFlight may be blocked by the nature of simulated-location tooling or by NetworkExtension usage. Do not plan commercial distribution until entitlement and review feasibility are separately researched.
