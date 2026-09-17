# Vanish pairing analysis

Vanish exposes explicit select, export, place, cancel, and repair pairing operations. Selection and repair allow time for the phone's Lockdown Trust prompt. Electron can call PMD remote-pairing helpers and stores sideloader state beneath its user-data directory. Pairing-related failures have dedicated `VAN-6xx` messages. `CONFIRMED_VANISH_STATIC_CODE`

The evidence does not reveal enough of the proprietary Rust helper to claim the pairing envelope, proof, promotion, or rollback semantics. Vanish therefore provides a consumer behavior reference: the user does not manually find/copy a pairing file; Trust remains explicit; repair is available; pairing is treated separately from app install.

Veya already has a stronger inspectable foundation: House Arrest request delivery, a phone-generated 32-byte bootstrap key and nonce, an AES-GCM envelope, Keychain import, and a receipt. It needs hardening rather than replacement:

```text
active record remains usable
-> create request-bound candidate
-> encrypt and transfer candidate
-> phone imports candidate slot
-> receipt authenticates request/artifact/device
-> fresh challenge proves current phone Keychain possession
-> developer-service operation proves usability
-> atomically promote both sides
-> retain old record through grace period, then remove
```

Initial USB Lockdown pairing is a separate state machine. RemotePairing import, RPPairing tunnel authentication, Developer Mode, profile trust, and VPN approval must never collapse into one `paired` flag.
