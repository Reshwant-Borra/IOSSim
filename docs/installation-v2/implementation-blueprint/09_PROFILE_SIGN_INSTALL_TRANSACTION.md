# Profile, Sign, Install Transaction

## Transaction

```text
observe App ID/device -> reconcile App ID -> issue candidate profile
-> validate profile -> build immutable candidate payload -> derive entitlements
-> sign in process -> independently verify -> stage -> install
-> inventory -> launch -> candidate capability proof -> promote -> retire old
```

Every arrow is a journaled transition. The transaction key binds team, device UDID hash, app/runner bundle IDs, key SPKI, certificate serial, source artifact digest, and generation.

## Evidence gates

| Edge | Required independent evidence |
|---|---|
| App ID -> profile | Apple inventory says exact ID/team/capabilities/device |
| Profile -> payload | CMS decodes; notBefore/notAfter; team, cert, device, bundle and entitlements match |
| Payload -> signed | Complete bundle graph; per-node valid signature/CMS/entitlements/profile; source digest recorded |
| Signed -> staged | Candidate tree digest, no unexpected files/symlinks, executable modes, architecture policy |
| Staged -> installed | InstallationProxy success plus fresh installed-app inventory reports candidate bundle/version/team |
| Installed -> launched | AppService launch receipt binds device connection generation, exact bundle and process |
| Launched -> promoted | Required generation-scoped capability proof succeeds; journal atomic promotion |

Profile expiry during the transaction invalidates the candidate before install. If expiry occurs after transfer, inventory/proof rejects it and active remains. A disconnect creates an ambiguous install result; reconnect and inventory determine outcome before retry.

The known-good installed payload is not proactively uninstalled. iOS may replace an app with the same bundle ID; therefore rollback evidence includes the staged prior signed artifact. If the candidate install replaces active but launch/proof fails, attempt one reinstall of the last known-good artifact when its certificate/profile remain valid. Otherwise report recovery-required without destructive cleanup.

Staging uses `Application Support/Veya/staging/<generation>/`, same-volume atomic renames, `0700`, no symlink traversal, quota preflight, and cleanup only after the journal no longer references it. Signing never mutates source artifacts.

