# Keychain and credential model

## Current implementation

The live Personal Team code creates a 2048-bit RSA key in the default traditional user Keychain, tags it to IOSSim/team, requests a certificate, adds the certificate, and stores persistent key metadata. Access policy accounts for the GUI, embedded helper, and `/usr/bin/codesign`. `NativeSigningIdentityResolver` validates profile certificate/team, locates the exact managed key, constant-time compares public keys, resolves `SecIdentity`, checks `security find-identity`, then signs and strictly verifies a disposable app. `CONFIRMED_LOCAL_IOSSIM_CODE`

This research did not create, change, or delete a real identity.

## V2 item model

| Item | Keychain class/access | Account key | Data |
| --- | --- | --- | --- |
| Apple session envelope | generic password; this-device-only, user-unlocked | adapter version + account hash | DSID/token/cookies/expiry, encrypted by Keychain |
| Signing private key | SecKey permanent, non-exportable where supported | product namespace + team ID + key UUID | private key |
| Signing key metadata | generic password | team ID | key tag/ref, public digest, cert fingerprint, created/last-used |
| RemotePairing record | generic password; this-device-only | team ID + device hash + slot(active/candidate) | pairing bytes and state |
| Phone pairing record | iOS Keychain appropriate accessibility | team/device + slot | pairing bytes |

Passwords, 2FA values, and SRP ephemeral values are never Keychain items. The UI passes them once through an in-memory/pipe channel; buffers are released promptly. Saving an Apple password is not a V2 feature.

## ACL and compatibility

The signing key must be usable by the signed GUI/helper and the system codesign tool without broad “allow all applications” ACLs. The release qualification matrix covers each supported macOS and new user Keychain. If modern access-control APIs cannot express the required system-tool access consistently, Veya documents the Keychain prompt rather than weakening access.

## Renewal and cleanup

Certificate renewal first attempts the current managed key if Apple policy and expiry allow. A new key/cert is created as a candidate and promoted only after profiles, disposable signing, artifact signing, install, and launch verify. Old key/cert remain until no profile/artifact/installed receipt references them and a retention window passes.

Cleanup queries only the exact Veya application tag/service. It records candidates, proves no live reference, removes certificate before/with key as an explicit transaction, and never deletes third-party identities. Account sign-out removes session items but not working signing resources unless the user selects a scoped reset.
