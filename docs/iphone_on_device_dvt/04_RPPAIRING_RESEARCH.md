# RPPairing Research

## File Format

STATUS: STRONG EVIDENCE

idevice `RpPairingFile` stores:

- `public_key`: 32-byte Ed25519 verifying key.
- `private_key`: 32-byte Ed25519 signing key.
- `identifier`: stable host identifier.
- `alt_irk`: optional 16-byte identity key used for mDNS auth tags.

The file is serialized as an XML or binary plist. Locus stores it as `Application Support/Pairing/rp_pairing_file.plist` with POSIX mode `0600`.

## Cryptographic Role

STATUS: STRONG EVIDENCE

RPPairing is not a simple token. Source shows:

- X25519 pair-verify creates a shared secret.
- Ed25519 signs a transcript containing the host X25519 public key, the pairing identifier, and the device public key.
- HKDF-SHA512 derives pair-verify encryption keys.
- ChaCha20Poly1305 protects pairing messages.
- The pair-verify shared secret becomes the tunnel TLS-PSK for newer TCP tunnel transport.

## Lifecycle

STATUS: PLAUSIBLE / UNKNOWN

Evidence supports that a pairing file can be imported and reused after the computer is powered off. Locus and Mirage both build around that assumption, and idevice raw RPPairing uses only the file and reachable endpoint at runtime.

Still unknown until experiment:

- Whether records survive all iOS updates.
- Whether Developer Mode toggling invalidates them.
- Whether device erase/reset invalidates them.
- Whether reboot changes any listener/bootstrap requirement.
- Whether records expire. No audited source found an explicit expiry.

## Tied To Host Or Device?

STATUS: STRONG EVIDENCE

The pairing material represents a host identity accepted by a specific device. The file contains the host private key and identifier; pair-setup stores/updates peer-device data including `altIRK` and remote pairing UDID. Copying/importing the file is sufficient only if the device has accepted that host identity and the file is not a different pairing format.

## Lockdown Pairing Is Not Enough

STATUS: CONFIRMED

Locus setup and Mirage docs both warn that older lockdown/SideStore `.mobiledevicepairing` files are not the required RPPairing format. RPPairing plists may be named `.plist` or `.mobiledevicepairing` by tools, so content validation should check semantic keys (`public_key`, `private_key`, `identifier`, optional `alt_irk`) rather than extension alone.

## Secure Handling

STATUS: CONFIRMED REQUIREMENT

Do not commit or log pairing files. Treat them like private keys.

Required handling for POC:

- Store in iOS Keychain or protected app container file with complete file protection.
- Never print full plist contents.
- Redact `private_key`, `public_key`, `identifier`, `alt_irk`, peer `accountID`, and UDID in logs unless the user explicitly exports a diagnostic bundle.
- Add project-level `.gitignore` rules before creating any POC artifacts outside this research folder.
