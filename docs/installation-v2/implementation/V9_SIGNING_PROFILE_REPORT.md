# V9 signing / certificate / profile lifecycle report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Converted IOSSim-managed signing metadata to an active/candidate lifecycle. New or recovered identities are stored under a separate Keychain metadata account and do not overwrite the last active mapping during certificate request, profile creation, signing, or installation.
- Added idempotent candidate promotion. Promotion updates the active metadata first and removes the candidate only after the active Keychain write succeeds; it never deletes the prior private key or certificate.
- Added `pendingPromotion` to the typed signing identity and carried the non-secret lifecycle flag across the packaged helper boundary.
- Converted native provisioning artifacts to separate owner-only active and candidate files. Candidate writes use atomic replacement and mode `0600`; active artifacts remain readable and unchanged until promotion.
- Setup’s reuse shortcut now accepts only active profiles. Merely preparing profiles can no longer make a future setup session treat them as installed.
- The packaged provisioner promotes identity metadata and profiles only after exact post-install bundle/team/version inventory succeeds. A crash after Keychain promotion but before artifact promotion resumes idempotently from the retained candidate artifact.
- Preserved immutable payload workspaces, explicit nested inside-out signing, entitlement/profile verification, Keychain private-key confinement, expiration validation, exact-team install checks, and non-destructive handling of unknown certificates, profiles, and apps.

## Acceptance evidence

- Focused Apple/signing/provisioning suites executed 89 tests with one opt-in local-system skip and zero failures.
- Candidate-store tests prove a staged profile set is not active, an existing active set remains unchanged while a replacement is staged, and explicit promotion atomically advances the active set.
- Identity tests prove first creation is candidate-only, promotion is explicit, stale/missing-key recovery preserves the prior active mapping, mismatched certificates do not delete identities, and certificate/device/App ID limits never trigger revocation/deletion.
- Downstream fault injection proves failures at signing resolution, artifact preparation, validation, install, and inventory retain the candidate context and a retry completes without destructive rollback.
- Broad safe Swift suite executed 328 tests with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected.
- `git diff --check` passed. No real Apple account, production Keychain identity, device install, or profile mutation was used by this gate.

## Safety and compatibility

- Existing valid active identities and profiles remain reusable.
- Expired profiles fail validation and flow back through provisioning; replacement remains candidate state until verified installation.
- Candidate failure cannot overwrite the active artifact or active Keychain metadata.
- No `codesign --deep --force` signing path exists. Nested code is signed explicitly inside-out; `codesign --deep` remains verification-only.
- Unknown user certificates, profiles, keys, and device apps are not deleted. Cross-team application ownership remains an explicit conflict.
- Private keys remain in Keychain and are never serialized into the artifact handoff.

## Physical validation deferred

- Personal Team certificate and profile creation/renewal against a current approved Apple test account.
- Candidate signing using the packaged helper, native install/upgrade, exact inventory confirmation, promotion, and restart reuse on a supported iPhone.
- Expiry/renewal with a still-working prior installation; certificate-limit and revoked-certificate behavior from live Apple services.
- Keychain ACL behavior across packaged GUI/helper/codesign processes on a clean macOS user.

## Known limitations

- Retirement of superseded IOSSim-managed Keychain keys/certificates is intentionally deferred until a physical grace-period policy is proven. V9 preserves old resources rather than risking destructive cleanup.
- Apple revocation state cannot be proven offline; the versioned Apple adapter and physical qualification must supply that evidence.
- Public qualification remains blocked by the production DDI decision and later release/physical gates.

## Gate

Valid resources are reused, expired profiles require renewal, candidate preparation and downstream failure preserve the active installation state, nested signing remains explicit, exact installed inventory controls promotion, cross-team conflicts stay explicit, and secret material remains confined to Keychain/owner-only state. Physical Apple and iPhone proof remains outstanding.
