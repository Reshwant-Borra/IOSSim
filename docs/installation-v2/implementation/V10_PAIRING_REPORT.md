# V10 staged RemotePairing replacement report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Removed the force-repair delete of the active Mac pairing record. The coordinator never deletes active pairing before replacement proof.
- Added separate active/candidate Keychain accounts on macOS and iOS, plus explicit candidate load/save/promote operations. Promotion replaces the active item only after the candidate is proven; the prior active record survives every earlier failure.
- Added schema-2 request binding across bootstrap, encrypted envelope, candidate receipt, possession challenge/response, promotion request, and final operational receipt.
- Bound the transaction to physical device UDID, team, request ID, pairing generation, release identity, bootstrap nonce, challenge nonce, pairing identifier, and public-key fingerprint.
- Added a fresh candidate-possession challenge. The phone computes an HMAC over the complete bound challenge using a key derived from the staged pairing material; raw pairing bytes never leave the encrypted delivery or Keychain stores.
- Changed the phone inbox to import into candidate state, retain the prior active record, answer the possession challenge from the candidate, and promote only after an explicit promotion request.
- Replaced the production no-op operational proof with `NativeDeveloperServicesRemotePairingProof`, which revalidates the candidate natively and requires a ready developer-services receipt before promotion.
- Made restart recovery idempotent: an existing matching candidate is reused rather than creating another pairing record.
- Preserved app-private House Arrest delivery, exact-device routing, encrypted AES-GCM transfer, and secret-free logs/journals.

## Acceptance evidence

- macOS focused pairing suite: 9 tests passed, zero failures.
- Tests cover successful create/promotion, active reuse, invalid existing-record repair, wrong-device receipt, replayed/wrong request ID, corrupt possession proof, failed developer-services proof, missing phone promotion receipt, pre-promotion Mac crash, candidate resume, and preservation of the prior active record.
- iPhone `POCUnitChecks` passed. Phone-side checks prove candidate import does not replace active state, possession response is generated from the candidate, explicit promotion advances active state, request/bootstrap/envelope fields are bound, transient files are cleaned only after promotion, and bootstrap keys do not enter receipts.
- Broad safe macOS suite executed 333 tests with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected.
- `git diff --check` passed. No real pairing record, phone Keychain, device app container, Apple account, or device service was mutated.

## Safety and recovery

- Import receipt is only candidate-storage evidence; it cannot mark pairing operational.
- Possession proof alone is insufficient; developer-services proof must also pass.
- Phone disconnect, bad/replayed receipt, failed possession, failed developer services, and either-process failure before promotion leave the previous active record intact.
- A crash after phone promotion but before Mac promotion is recoverable by replaying the same candidate transaction; promotion operations are idempotent at the record level.
- Raw pairing records, private keys, import keys, and proof keys are not logged or added to setup state.

## Physical validation deferred

- App-private request/bootstrap/envelope/challenge/promotion exchange over House Arrest on a supported iPhone.
- Phone background/scene reactivation at every transaction phase.
- Real RemotePairing validation, RemoteXPC/developer-services proof, disconnect after import, phone termination before promotion, Mac termination before promotion, and restart resume.
- Delayed retirement behavior across an actually working prior pairing generation.

## Known limitations

- V12 strengthens developer-services/AppService receipts and identity binding. V10 requires the current native readiness receipt but does not claim the later full AppService qualification gate.
- Physical phone-side Keychain atomicity and scene scheduling remain unproven until V19.

## Gate

The last working pairing is never deleted before replacement. Candidate delivery, authenticated possession, developer-services proof, phone promotion, and Mac promotion are distinct bound stages; failure before final promotion preserves active state. Physical end-to-end proof remains required.
