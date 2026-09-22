# RemotePairing Specification

## Transaction

`observe -> create candidate -> encrypt -> deliver -> phone import receipt -> possession challenge -> developer-service proof -> promote -> retire old`.

Candidate identity binds pairing ID, Mac installation ID, device UDID hash, device public material, generation, created/expiry time, and SHA-256 of encrypted bytes. Active pairing remains until candidate proof and journal promotion.

## Storage and delivery

- Mac pairing material is stored as a data-protection Keychain item scoped to device + pairing ID; journal stores only references/digests.
- Delivery uses the existing House Arrest/AFC inbox for the exact installed payload. Envelope encryption uses an ephemeral session key sealed to the phone payload's authenticated key; the raw pairing record is never logged or left in a general container path.
- Envelope includes nonce, generation, device and payload identities, expiry, one-time delivery ID, and MAC/signature. Phone rejects replay, wrong device, wrong payload, old generation, or expired envelope.
- Phone writes a receipt containing delivery digest and a random challenge response. Mac then proves the imported record can establish the intended developer service; an inbox receipt alone is not possession proof.

## Recovery

Crash before delivery leaves a local candidate. Crash after delivery re-reads phone receipt and performs possession proof; it does not redeliver blindly. Phone reboot resumes from its encrypted candidate inbox. Wrong-device delivery is quarantined and never promoted. Failure retains active pairing; repair first revalidates active, then creates a candidate only if necessary.

Migration reads both current service-name variants but writes only `com.veya.remote-pairing.v2`. Replay counters and receipts are journaled. Support bundles include IDs/digests, never pairing bytes, escrow bags, private keys, or decrypted envelopes.

