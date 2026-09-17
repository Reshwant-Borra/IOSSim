# PHYSICAL DEFECT 001 — test results

All runs on the development Mac (Apple Silicon, macOS 26 / Darwin 25.6).
No physical device operation was rerun, and no Apple account state was mutated.

## Narrow signing regression (run first)

```
cd macos && IOSSIM_RUN_KEYCHAIN_INTEGRATION=1 swift test --filter VeyaSigningKeychainRegressionTests
```

```
testLoginKeychainKeyCreatedByAPackagedHelperIsBlockedByItsPartitionList  passed (16.134s)
testPackagedHelperCreatedKeyIsSignableByRealCodesignWithoutAnyPrompt     passed  (0.866s)
testSigningAccessPolicyGrantsOnlyCodesignAndThePackagedVeyaExecutables   passed  (0.003s)
testSigningKeyAttributesCarryAccessAtTheTopLevelAndTargetTheVeyaKeychain passed  (0.002s)
testSigningKeychainPasswordIsRandomPerInstallationAndStoredPrivately     passed  (0.009s)
testSigningQualificationLeavesTheUserKeychainSearchListIntact            passed  (0.995s)

Executed 6 tests, with 0 failures (0 unexpected) in 18.008 seconds
```

The 16-second case is the one that reproduces the shipped defect: it waits out
the SecurityAgent prompt that a login-Keychain key still raises.

## Direct qualification-helper evidence

Run from `IOSSimSigningKeyTestHelper`, an ad-hoc-signed executable
(`codesign -dv` reports `Signature=adhoc`, `TeamIdentifier=not set`) — the same
signature class as the packaged Veya helper:

```
$ IOSSimSigningKeyTestHelper qualify-signing login
partition list: cdhash:24920762851f19cae1405ce524bbce801d2487c9
codesign blocked on a SecurityAgent prompt
exit=3                              <-- reproduces SIGNING_KEY_ACCESS_DENIED

$ IOSSimSigningKeyTestHelper qualify-signing veya
partition list: <none>
codesign signed with no prompt
exit=0                              <-- the fix
```

## Full Swift suite

```
cd macos && swift test
```

```
Executed 362 tests, with 12 tests skipped and 0 failures (0 unexpected) in 24.377 seconds
```

Baseline was 356 executed / 9 skipped. The six new tests account for the
difference: three UNIT tests run by default, three LOCAL_SYSTEM tests skipped
unless `IOSSIM_RUN_KEYCHAIN_INTEGRATION=1` (they mutate the runner's Keychain).

## Repository checks

| gate | result |
|---|---|
| `scripts/checks/test_artifact_identity.py` | Ran 6 tests — OK |
| `scripts/checks/test_device_discovery_cli.py` | Ran 5 tests — OK |
| `scripts/checks/check_no_xcode_consumer_runtime.py` | PASS — packaged consumer composition is native-only and payload-prebuilt |
| `scripts/checks/check_no_xcode_install_routing.py` | PASS — native install routing, no devicectl fallback; native AppService launch wired |
| `scripts/checks/check_bundle_identifiers.py` | PASS — bundle identifier inventory |

## Release build and audits

`./iossim release-local` — PASS, including its in-build package content,
distribution metadata and structural signature audits.

`./iossim release-local-audit <dmg>` — independent mounted-DMG audit:
`Overall: PASS (LOCAL_TEST_ONLY; public gates not assessed)`.
Full log: `logs/defect001-independent-dmg-audit.log`.

## Not rerun, and why

* **Rust native bridge (11/11).** No Rust source was changed by this fix. The
  bridge dylib in the new DMG is rebuilt from the same sources and passes the
  mounted signature and ABI-schema audits (`nativeBridgeABI: 2` matching
  `nativeBridgeABIExpected: 2`).
* **Physical device operations.** Out of scope for a software fix pass, and
  explicitly excluded by the brief.
* **Apple account mutations.** Deliberately avoided; the regression uses a
  throwaway CA and never contacts Apple.
