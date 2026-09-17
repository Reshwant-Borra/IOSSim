# V15 diagnostics and support report

Verdict: `PASS`

## Implemented

- Added a stable diagnostic descriptor with code, namespace, stage, user message, redacted developer detail, retryability, automatic-repair flag, required user action, and safe support fields.
- Covered every legacy `ConsumerProvisioningErrorCode` and all required namespaces: integrity, device, trust, developer support, Apple, signing, profile, install, pairing, VPN, developer service, runner, runtime, state, and update.
- Unknown errors resolve to the owning stage namespace's `099` code rather than a misleading executable or doctor identity.
- Packaged helper failure JSON now includes the stable diagnostic descriptor while preserving the legacy error object for compatibility.
- Failure descriptions shown across process boundaries begin with the stable `VEYA-*` identity and retain the legacy code only as safe compatibility context.
- Support export remains an explicit one-file allowlist (`support.json`). It serializes only modeled support fields and now declares that allowlist in schema 8.
- Added a final redact-then-scan gate before ZIP creation. The exporter fails closed and saves no report if it detects an unredacted password, 2FA code, Apple/auth token, cookie, private key, pairing secret, or PSK.
- Support diagnostics contain stable codes and redacted details; they never include raw pairing records, provisioning payloads, Keychain values, session material, or private signing keys.

## Acceptance evidence

- Diagnostic taxonomy tests: 4/4 passed, including exhaustive legacy-code coverage and exact namespace coverage.
- Support export sentinel test passed with injected password, email, six-digit 2FA code, Apple token, cookie, pairing PSK, and PEM private key. Every sentinel was absent after ZIP extraction.
- The extracted ZIP contained exactly one regular file named `support.json`.
- Packaged boundary suite: 11 executed, one explicit artifact-path skip, zero failures.
- Broad safe macOS suite: 353 tests executed, 9 explicit opt-in/local-system/physical skips, 0 failures, 0 unexpected. Full output is retained in `v15-swift-test.log`.
- Six artifact-identity tests, no-Xcode runtime/routing audits, and `git diff --check` passed.

## Known limitations

- Stable numeric assignments now form compatibility API and must not be repurposed; future errors require new codes.
- Support diagnostics intentionally omit raw Apple/device responses, even when those responses could simplify vendor debugging.

## Gate

The stable taxonomy is machine-readable and secret-safe, support export is allowlisted rather than directory-based, and injected sentinel secrets are absent from the final ZIP. No physical validation is required for this software-only gate.
