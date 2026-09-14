# Automatic RemotePairing

`RemotePairingCoordinator` is the single Mac lifecycle owner. It validates an
existing record first, creates one over trusted USB RemotePairing lockdown only
when absent/stale, and stores the plist bytes in a per-device/team Keychain
generic-password item. Journals contain only schema, device, team, identifier
metadata, and timestamps.

After app installation, IOSSim writes a one-time AES-GCM envelope to the
app-private `Library/Application Support/IOSSim/SetupInbox`. The iPhone-side
`AutomaticPairingInboxProcessor` checks schema, nonce, device/team binding and
RPPairing semantic lengths before replacing its Keychain record, then returns a
receipt. Receipt success is not operational success: the Mac must still prove
RemotePairing validation, LocalDevVPN/tunnel, authenticated RSD, and (where
required) TestManager reachability.

Repair is targeted to missing, invalid, wrong-device, stale, or pairing-caused
RSD failures. DDI, profile, and generic transport failures do not regenerate
pairing. Manual plist import remains Advanced Diagnostics only.

Creation, delivery, phone receipt, and RSD proof are `AWAITING_PHYSICAL_VALIDATION`.
