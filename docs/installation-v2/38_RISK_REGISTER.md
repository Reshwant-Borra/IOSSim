# Risk register and confidence matrix

## Risk register

| ID | Risk | Likelihood / impact | Evidence | Mitigation / owner gate |
| --- | --- | --- | --- | --- |
| R1 | No approved fresh DDI source | High / critical | cache-only code; mirror/Apple docs | ADR-003 product+legal decision before M6/public claim |
| R2 | Apple private auth/provisioning changes or terms disallow product flow | Medium-high / critical | version-bound adapter/history | legal/product acceptance, version adapter, fixtures, kill switch, preserve apps |
| R3 | Initial Lockdown pairing differs across iOS/macOS | Medium / high | upstream API, no current ABI/clean test | narrow wrapper and M5/M15 physical matrix |
| R4 | Pairing candidate protocol has replay or split-brain flaw | Medium / critical | current no-op proof/delete-first | formal threat review, crypto vectors, staged promotion, crash testing |
| R5 | External LocalDevVPN changes/disappears | Medium / high | external App Store dependency | publisher/support agreement, compatibility matrix, typed block/fallback product policy |
| R6 | Cross-process state corruption/mis-scoping | High current / high | singleton files, process-only actors | M3 lock/journal/CAS and multi-process fault suite |
| R7 | Release metadata diverges from bytes again | High current / critical | inspected architecture/schema mismatch | M1/M13 mounted artifact-derived manifest and single builder |
| R8 | Native AppService succeeds only on prior developer Mac/cache | Medium / high | saved physical record, no clean final test | clean-host/final-artifact matrix |
| R9 | Keychain ACL blocks helper/codesign or cleanup deletes unrelated identity | Medium / critical | static code only for current user | scoped tags, disposable probe, isolated/physical ACL tests, no broad deletion |
| R10 | Profile/certificate expiry causes destructive reinstall/resource churn | Medium / high | lifecycle incomplete | staged renewal, read-before-create, reference-aware cleanup |
| R11 | Test suite masks defects through live/default state | High current / high | 36 failures and default leakage | M2 hard gate before implementation |
| R12 | Support archive exposes identifiers/secrets | Medium / critical | broad schema-7 struct export | allowlist schema 8, random aliases, negative scanner |
| R13 | Universal build contains single-arch bridge/payload component | High current / high | arm64 artifact vs universal sidecar | audit every Mach-O; Intel qualification; fail release |
| R14 | Branding/bundle-ID migration loses pairing/Keychain/app mapping | Medium / high | identity coupling | V2-first staged migration, stable tags, optional dual-ID proof |
| R15 | Runtime proof alters location or leaves simulation active | Low-medium / high | proof not implemented | bounded safe set/observe/clear, pending Clear journal, physical validation |
| R16 | Transitive dependency license/vulnerability issue | Medium / high | only two direct notices packaged | exact SBOM/license/vulnerability release gate |

## Newest test-log classification

Log: `.build/iossim/logs/20260915T182122Z-mac-swift-test.log`: 279 tests, 7 skipped, 36 assertion failures, 1 unexpected failure. `CONFIRMED_LOCAL_IOSSIM_TEST`

| Group | Observed failures | Classification | Required milestone |
| --- | --- | --- | --- |
| Apple Personal Team / SetupStore authorization | 2 test cases | `TEST_ISOLATION_DEFECT` plus broken mock/default live boundary; expected taxonomy also stale | M2, M10 |
| Consumer provisioning disconnected/downstream fault | 2 test cases, several expectations | `BROKEN MOCK/FIXTURE`: current inventory skips install so injected install faults never execute | M2 |
| Support-bundle exact assertion | 1 assertion | `STALE TEST`; V2 exporter still needs replacement for privacy | M2, M12 |
| Backend default/headless Xcode | 2 cases, 3 assertions | `STALE TEST` after native Personal Team default and fallback removal | M2 |
| RemotePairing repair | 1 unexpected case | `BROKEN MOCK/FIXTURE` against current operational validation; no-op real proof remains a product defect found by source, not this failure | M2, M8 |
| SetupStore routes/actions | 13 cases, 26 assertions | mostly `TEST_ISOLATION_DEFECT` and incomplete new reconcile mock; some `STALE TEST` state expectations | M2, M4 |

No failure in this log alone conclusively demonstrates a new production behavior defect. The non-hermetic harness is a real engineering defect and may hide product defects, so “all failures are stale” is rejected. The suite is not an acceptance gate until M2 passes.

## Confidence matrix

| Subsystem | Understanding | Architecture | Implementation confidence | Evidence | Remaining uncertainty | Physical? |
| --- | --- | --- | --- | --- | --- | --- |
| Packaged engine/call graph | High | High | High | local source/checks | final installed signature/handshake | Yes |
| Initial Lockdown trust | High mechanism | High | Medium | pinned idevice source | Apple prompt/persistence across OS | Yes |
| Discovery/exact device selection | High | High | High | source + prior physical | duplicate USB/network order after fix | Yes |
| Apple Personal Team | High current behavior | Medium-high | Medium | source + references | private service/terms/version stability | Yes |
| Keychain/signing | High static | High | Medium | source/tests | ACL behavior on supported macOS | Yes |
| Profile renewal | Medium-high | High | Medium | source/target design | limits/expiry ambiguity | Yes |
| Native install | High | High | High | source/tests/prior records | clean final artifact | Yes |
| DDI acquisition | High gap | Low until decision | Low | cache code, open source, Apple docs | approved source and rights | Yes; product decision first |
| DDI personalization/mount | High | High | Medium-high | bridge/upstream source | device/build breadth/TSS outages | Yes |
| AppService launch | High | High | Medium-high | source + prior record | clean final/cross-version | Yes |
| RemotePairing delivery | High | High target | Medium | Mac/phone source | proof primitive and crash promotion | Yes |
| LocalDevVPN | High current | High target | Medium | source/App Store/Apple docs | publisher/version/approval behavior | Yes |
| Rich runtime | High | High | High preserve | source/prior physical | new readiness probe regression | Yes |
| State/concurrency | High gap | High | Medium | source | OS/filesystem crash edge behavior | Yes for reboot; automated first |
| Diagnostics/privacy | High current | High | Medium-high | exporter source | scanner completeness/usability | Yes |
| Release provenance | High | High | High | exact artifact/code comparison | Developer ID/notary/reproducibility | Yes |
| Veya migration | Medium | High staged | Medium | identity/source analysis | final bundle-ID/product decision | Yes |

Confidence is scoped to understanding/design, not a probability of shipment. Any row requiring hardware remains unpassed.
