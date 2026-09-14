# Mac-assisted renewal

`MacAssistedRenewalCoordinator` separates profile expiry, certificate validity,
Apple session validity, pairing health, and installed-app state. A valid
certificate is reused while profiles are refreshed; revoked/expired
certificates are recreated; an expired Apple session requests legitimate
reauthentication. Refresh uses in-place Installation Proxy upgrade semantics,
then verifies inventory, runtime mapping, and the existing pairing proof.

Renewal never deletes pairing or app data as a side effect. Pairing repair is a
separate action. Autonomous on-phone signing and background seven-day refresh
are intentionally out of scope for this release.

Profile/certificate dates and in-place upgrade behavior remain
`AWAITING_PHYSICAL_VALIDATION`.
