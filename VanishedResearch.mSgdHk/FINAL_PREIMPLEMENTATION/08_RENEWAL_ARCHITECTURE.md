# Renewal Architecture

The first renewal is Mac-assisted. It refreshes ordinary Personal Team profiles and signed payloads; it does not bypass seven-day expiry or require phone-autonomous account login.

Sequence: warn before expiry; reconcile device; reuse valid Apple session/key/certificate; if session expired, normal login/2FA; if certificate revoked/key mismatch, create managed identity; reconcile exact device/App IDs; obtain profiles; re-sign main and runner; verify Team ID, bundle IDs, entitlements and key/profile match; Installation Proxy Upgrade both apps; verify inventory, app-data receipt, pairing import, VPN/RSD/TestManager and runtime; commit journal only after all proofs.

Upgrade is the intended data-preserving operation but must be physically tested. Team/bundle mismatch, uninstall, reset, entitlement change, device update and app behavior can alter data. Never uninstall first.

Cases: valid cert/profile near expiry -> fresh profile and upgrade; revoked certificate -> new identity; expired profile -> re-sign; expired Apple session -> interactive reauth; app expired -> upgrade; valid pairing -> verify/preserve; stale pairing -> repair pairing only. Renewal is serialized per device and shares ReadinessEngine/journal. Seven-day renewal is ordinary re-sign/install, not bypass. Autonomous phone refresh is later.

