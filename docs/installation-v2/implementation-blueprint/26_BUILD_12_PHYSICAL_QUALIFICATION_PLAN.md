# Build 12 Physical Qualification Plan

## Environments

- Development Apple Silicon Mac with known history.
- Clean Apple Silicon Mac/user with no Xcode/Homebrew/Rust/Python dependency.
- Intel Mac with clean user and native x86_64 execution.
- At least one supported iPhone/iOS build per DDI catalog claim.
- Dedicated qualification Apple account plus a controlled account containing unrelated certificates.

Every run begins with read-only inventory and records artifact, Mac architecture/OS, app state class, device model/iOS build, account scenario ID, and permitted mutations. Never reset a personal account/device to manufacture a case.

## Matrix

| Scenario | Automated portion | Required proof |
|---|---|---|
| Fresh Veya install | artifact audit + harness | auth/user actions, install, full READY |
| Previous Veya install | inspect/reconcile | minimal transitions, no repeated prompts |
| IOSSim migration | ledger assertions | new signer active, legacy writes absent |
| Same/new build reinstall | scenario runner | reuse/repair and full proof |
| Mac reboot | auto relaunch/report | journal recovery, no prompt, reproof |
| iPhone reboot | detection/report | reconnect, VPN/pair/runtime recovery |
| Capacity available/full | API trace assertions | bounded issuance; owned-only revoke |
| Owned stale cert | trace + inventory | one safe revoke only if necessary |
| Unknown/unrelated cert | trace | zero revocations, safe user action |
| Second Mac | correlated reports | distinct key; no cross-Mac damage |
| Profile renewal | clock/real expiry fixture then authorized live | candidate renewal and promotion |
| Pairing recovery | receipts and proof | active survives candidate failure |
| VPN recovery | endpoint state | approval only when Apple requires |
| Spoof | scripted bounded Rich write | exact target observation/clear/READY |
| Drive | product workflow | sustained capability after READY |

## Procedure and acceptance

Run safe inspection first, then one authorized scenario at a time. Screen-record only user interaction surfaces; collect structured reports/support bundle with secret scan. SecurityAgent, Keychain-password, certificate terminology exposed to consumer, unexplained `UNEXPECTED_ERROR`, stale READY, unknown certificate revocation, destructive reset, or reliance on developer tools is P0/P1.

Fresh, reinstall, migration, reboot, and runtime cases must pass on Apple Silicon. Core install/sign/launch and no-dependency gates must pass on Intel. Clean-Mac failure blocks release even when development Mac passes. Results are scoped to the tested iOS builds; untested builds remain unsupported.

