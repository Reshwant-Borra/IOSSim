# Product invariants

These are acceptance constraints, not implementation preferences.

## User and distribution invariants

- A consumer installs one canonical DMG, moves Veya to Applications, and runs setup without cloning the repository or installing full Xcode.
- Apple-required Trust, passcode, Developer Mode, developer-profile trust, Apple Account/2FA, and VPN approval remain explicit user actions. Veya never bypasses them.
- The packaged GUI calls only its signed embedded helper and resources. Repository lookup, `DEVELOPER_DIR`, `xcodebuild`, `devicectl`, and arbitrary environment path selection are forbidden in the consumer graph.
- A public artifact is Developer ID signed, hardened, notarized, stapled, Gatekeeper-qualified, content-audited, and identifiable by version, build, commit, channel, artifact hash, schema set, and architecture.

## Runtime invariants

Preserve the proven Spoof and Drive behavior: retained/preinstalled XCTest runner, supplied RSD, LocalDevVPN, RPPairing, saved pairing, Rich/XCUILocation default path, DVT compatibility fallback, smooth 2 Hz cadence, baseline 1 Hz fallback, Stop & Hold, Resume, Clear, destination hold, one writer, one scheduler, and no backlog replay. `CONFIRMED_LOCAL_IOSSIM_CODE`

Installation V2 may change how prerequisites are created and proven. It must not silently replace the runtime primitive with Vanish’s coordinate-only DVT behavior.

## State and security invariants

- Every mutation is scoped by release, team, device, and artifact identity as applicable.
- Operations are idempotent, resumable, checkpointed, generation-aware, cross-process safe, atomic, secret-safe, and fail closed.
- A successful configuration write is not operational readiness.
- An imported pairing receipt is not possession proof; possession proof is not developer-service proof; developer-service proof is not Rich runtime proof.
- Existing valid credentials, pairings, profiles, and installed apps remain usable until replacements are verified.
- Passwords, 2FA, tokens, cookies, private keys, pairing records/PSKs, profile blobs, raw device IDs, and route coordinates never enter logs or support bundles.
- Private Apple protocol behavior is isolated behind a versioned adapter and may be disabled independently.

## Evidence invariant

Claims use the evidence label that actually supports them. Physical success requires a timestamped, identity-bound record or a new lab run. Artifact bytes outrank desired configuration; current source outranks old reports; Apple-supported documentation outranks third-party convenience.
