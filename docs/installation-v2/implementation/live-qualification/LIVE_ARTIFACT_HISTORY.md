# Live Artifact History

| Build | Commit | SHA-256 | Root cause fixed | Qualification result | Next first failure |
|---|---|---|---|---|---|
| 8 | fd4fbfe | 81880997245f394fb8f3a1f33fe00e95f3ac34e0d2568f503d011b3aba578557 | PHYSICAL_DEFECT_005 signing-key partition repair | Failed: PHYSICAL_DEFECT_006 personal-team metadata Keychain prompt | com.iossim.mac.personal-team-signing prompt |
| 9 | fd4fbfe | c75b8f40eb2dc349f2afdf159fcfdb6444d334b2413446219da0356cb430a189 | PHYSICAL_DEFECT_006 signing metadata moved out of login Keychain + local key recovery | Pending live retest | TBD |
| 10 | fd4fbfe | cb58d36922b980a9ee4e01dd7d06231cde31a5c3d427bd1206aea2d855113462 | PHYSICAL_DEFECT_006 follow-up: fail-closed signing-keychain scoping; remove SecKeychainItemSetAccess reuse prompt | Pending live retest | TBD |
| 11 | fd4fbfe | 3f8967b9969925651b784eb3c08e5a0c5012c4e14b9815a4db2bfb8b0e977399 | PHYSICAL_DEFECT_006 follow-up: partition repair best-effort; codesign proof remains authoritative | Pending live retest | TBD |
