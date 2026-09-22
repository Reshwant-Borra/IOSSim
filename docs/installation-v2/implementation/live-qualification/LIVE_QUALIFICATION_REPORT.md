# Live Qualification Report

Generated: 2026-09-18T15:02:59.746204+00:00

| Stage | Classification | Status | Error | Actual |
| --- | --- | --- | --- | --- |
| baseline | AUTOMATABLE | PASS |  | branch=work/final-no-xcode-setup-v1<br>head=fd4fbfe364383f83b053ae13e6c96ec3af4fbfd6<br>## work/final-no-xcode-setup-v1...origin/work/final-no-xcode-setup-v1<br> M config/release.json<br> M macos/Package.swift<br> M macos/Sources/IOSSimAuthDiagnostic/main.swift<br> M macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamExperimental.swift<br> M macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift<br> M macos/Sources/IOSSimMacCore/Services/VeyaSigningKeychain.swift<br> M macos/Sources |
| connected-device-discovery | PHYSICAL_DEVICE_REQUIRED | PASS |  | Name                    Hostname   Identifier                                    State                Model                              Reality  <br>---------------------   --------   -------------------------------------------   ------------------   --------------------------------   ---------<br>Rishi Borra                        sha256:cdcb559b4ff095e3 (UDID)              available (paired)   iPhone 17 Pro (iPhone18,1)         physical <br>iPad Pro 13-inch (M5)              sha256:677188c928 |
| apple-authorization-keychain-item-metadata | AUTOMATABLE | PASS |  | security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.<br> |
| artifact-identity | AUTOMATABLE | PASS |  | {"path": ".build/iossim/local-release/Veya-0.1.0-build11-fd4fbfe-local-test.dmg", "sha256": "3f8967b9969925651b784eb3c08e5a0c5012c4e14b9815a4db2bfb8b0e977399", "sizeBytes": 16501564} |
| support-secret-scan | AUTOMATABLE | PASS |  | no hits |
