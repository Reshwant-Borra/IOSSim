# Readiness and recovery

`ReadinessCoordinator` evaluates host, device, Apple account, signing,
installation, developer support, pairing, VPN/tunnel, runtime, and user-intent
domains. Each domain has a structured state (`UNKNOWN`, `CHECKING`, `READY`,
`USER_ACTION_REQUIRED`, `TRANSIENT_FAILURE`, `REPAIRABLE`, `BLOCKED`,
`UNSUPPORTED`, `EXPIRED`, or `STALE`) plus a safe reason.

The resulting recovery plan is bounded and specific: unlock/trust is a user
action, pairing repair repairs pairing only, expiry renews signing, DDI state
prepares developer support, and transient runtime/tunnel errors use finite
backoff. A non-secret `SetupJournalStore` records safe progress and reconciles
real state on resume. It rejects secret-shaped fields and uses 0700/0600 file
permissions.

Location intent remains protected by the existing runtime generation and
single-writer semantics; setup recovery does not replay cleared or held Drive
coordinates.
