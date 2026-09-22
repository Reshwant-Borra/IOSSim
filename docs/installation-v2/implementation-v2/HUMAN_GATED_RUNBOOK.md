# Human-Gated Runbook (after the 2026-09-21 continuation)

Everything below needs Apple credentials, signing assets, the iPhone, or a release decision. All software
that can be finished without them is finished; see `PHYSICAL_E2E_CHECKPOINT_2026-09-21.md`.

## Step 1 — Signing assets for M4 (Apple Developer portal)

Provide, for one Veya team:

1. A signing identity in this Mac's login keychain: **Developer ID Application** (for distribution) or
   **Apple Development** (sufficient for the local proof).
2. A **macOS provisioning profile** for an **explicit** App ID `<TEAM>.<Veya bundle ID>` with the **Keychain
   Sharing** capability. For Mac Development the profile must include this Mac's provisioning UDID.
3. Optional (isolation negative): a second App ID's profile from the same team.

Then report the identity SHA-1 (`security find-identity -v -p codesigning`) and the profile paths.

## Step 2 — M4 gate (automated once Step 1 exists)

```sh
cd /Users/rishiborra/Desktop/IOSSim
VEYA_M4_SIGN_IDENTITY="<identity SHA-1>" \
VEYA_M4_PROFILE="/path/Veya.provisionprofile" \
VEYA_M4_UNRELATED_PROFILE="/path/OtherAppID.provisionprofile" \
swift test --package-path macos --filter SigningKeyStoreTests/testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction
```

Pass = create → reopen (new process) → upgrade (distinct cdhash) → steady-state reuse, zero SecurityAgent
launches, unrelated App ID denied. Then rerun the whole campaign: `./iossim installation-baseline` must be all PASS.

## Step 3 — Build 12 packaging change (needs Step 1; verifiable only by AMFI with the real profile)

Both processes that touch the Keychain must be profile-authorized with the **same first**
`keychain-access-groups` entry (the key store, auth v2 session and v2 pairing store query the default group):

- `Veya.app` (UI: auth session): `Contents/embedded.provisionprofile` + entitlements
  `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups = [<TEAM>.<bundle>]`.
- The helper (key store, pairing, engine): the main executable of a profile-carrying bundle (for example
  `Contents/Helpers/VeyaProvisioner.app` with its own `embedded.provisionprofile` and the same group), as the M4
  gate already builds it. Update the helper path in `BundledProvisioningEngine`/`ProvisionerEngineClient` and
  `PackagedEngineIntegrity` to the new location.
- `macos/scripts/build_app.sh`: sign with the team identity (`IOSSIM_MAC_CODE_SIGN_IDENTITY`), hardened runtime,
  the above entitlements, and embed the profiles. Verify with `codesign -d --entitlements :- <bundle>` and by
  launching both; `amfid` must not log `-413`.

## Step 4 — Physical Apple + iPhone campaign (needs Steps 1–3, the iPhone, and the Apple Account)

Preconditions: the iPhone is connected by USB, unlocked, trusted, Developer Mode on; LocalDevVPN installed.

1. Open the Step-3 `Veya.app` and **sign in to the Apple Account** (password + 2FA). Stop there; do not use the
   legacy Install button. The v2 session is now stored for the helper.
2. Drive the canonical engine through the packaged helper (the UI is not routed yet):

```sh
H="/Applications/Veya.app/Contents/<helper path from Step 3>/IOSSimProvisioner"
Q="swift run --package-path macos VeyaQualify"
CAP=docs/installation-v2/implementation-v2/qualification
UDID="<iPhone UDID>"   # from: ./iossim device-debug (physical UDID, e.g. 00008150-…)
$Q inspect --helper "$H" --device-udid "$UDID" --device-name "iPhone" --connection 1
$Q full --helper "$H" --capabilities $CAP/full-safe-repair.capabilities.json --device-udid "$UDID" --device-name "iPhone" --connection 1 --events-fd 3 3>events.jsonl
```

   Repeat `full` after each user action it reports (exit 2). Expected sequence: `signingKey` → `certificate`
   (1 CSR) → `profile` (device + App IDs + 2 profiles) → `payload` (in-process sign, Apple strict verify) →
   `application` (main + runner installed) → `developerSupport` (Developer Mode / DDI) → `pairing` → `vpn`
   (approve the VPN on the phone) → `runtime` READY. Use `full-destructive-owned.capabilities.json` only if the
   account is at its certificate limit and you accept revoking **this installation's own** retired certificate.
3. Physical failure matrix (each must end READY or with an exact user action, never a prompt):
   relaunch Veya mid-run (`resume --run <id>`), unplug during install (reconnect, `--connection 2`), lock the phone
   during pairing, reinstall the app from the phone (pairing/VPN re-delivered), switch to a second iPhone
   (profiles only reissued), certificate revoked in the Apple portal (replaced within 24 h or on next run),
   Veya upgrade (Step 3 build with a new build number: key reused, no prompt).
4. Record results in `M5`/`M7`/`M9`/`M10`/`M12` result files.

## Step 5 — Route switch + legacy deletion (software, but only after Step 4 passes)

Execute `M11_RESULT.md` → "Exact removal set for the route switch". Gate: `check_legacy_signing_routes.py --scope all`
= 0, full campaign green, then re-run Step 4 on the switched UI.

## Step 6 — Release decision

Build 12 needs every row of `BUILD_12_GATE_EVALUATION.md` PASS and an explicit human `BUILD_12_AUTHORIZED`.
Production DDI support also needs an approved exact-build DDI source (`UNRESOLVED_PRODUCTION_PROVIDER`); until then
every iOS build that needs a DDI reports `VEYA-DDI-030`.
