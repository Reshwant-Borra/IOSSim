# IOSSim to Veya migration strategy

Brand migration follows functional qualification. This research does not rename products, bundle identifiers, signing identifiers, paths, or Keychain services.

## Sequence

1. Ship an IOSSim-branded V2-compatible release that can read schema-4 state and write keyed V2 state.
2. Freeze stable internal resource IDs and add aliases for display name versus bundle/storage namespaces.
3. Introduce Veya display/app/artifact naming while retaining current bundle IDs and Keychain application tags for one migration release unless a product decision requires new IDs.
4. If bundle IDs must change, provision/register both old and new IDs, install/verify Veya alongside IOSSim, migrate phone container mappings through explicit authenticated transfer, then retire old app only after Rich proof.
5. Keep a signed migration receipt and rollback path to the last compatible IOSSim release.

## State migration

The migrator reads old Application Support/UserDefaults/Keychain items without moving secrets through logs or JSON. It writes a candidate keyed snapshot, validates physical state, commits, and marks the old record imported. Old files remain read-only for a retention period; ambiguous identities are not guessed.

Keychain keys and certificates should remain reusable through stable application tags and access requirements. A display-name change must not create duplicate Apple certificates. Pairing records are reused only after possession/operational proof. Existing installed iPhone bundle IDs and runner mapping remain valid until an explicit dual-ID migration is qualified.

## User-facing behavior

The About panel says “Veya (formerly IOSSim)” for the migration window. The installer identifies the detected old version/state and exact action. Update logic recognizes only signed compatible migration paths; downgrades that cannot understand V2 state are blocked.

## Rollback

Before promotion the migrator records old paths/versions and makes no destructive change. Rollback selects the old signed app and state snapshot, leaves Apple/device resources intact, and marks any Veya-only candidate resources for later scoped cleanup.
