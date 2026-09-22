# Adversarial confidence review

## Assumptions still open

1. **In-process signer compatibility:** public isideload/apple-codesign source is strong precedent, but Veya's main/runner/nested payload shapes have not been signed by the proposed implementation or installed on target iOS versions.
2. **Vanish behavior:** actual private-key storage, max-cert policy, multi-Mac safety, reinstall and update behavior remain inferred or unknown.
3. **Apple APIs:** private Developer Services contracts can change, return ambiguous capacity, rate-limit or require renewed authentication.
4. **DDI distribution:** a lawful/reliable production image source remains unresolved. A perfect installer cannot reach developer services without it.
5. **LocalDevVPN:** external acquisition, approval and lifecycle are partly outside Veya's control.
6. **Intel parity:** Vanish is no precedent and current Veya Keychain history came from Intel; proposed signer must be independently qualified on both architectures.
7. **Clean packaging:** local ad-hoc behavior can differ from Developer ID/notarized cdhash, quarantine and update behavior.

## Ways tests can lie

- Apple fixtures can preserve an obsolete response shape.
- Independent `codesign` verification can accept output that a particular iOS InstallationProxy rejects.
- Temporary Keychains do not exactly reproduce a consumer login session, although the target signer intentionally reduces that dependency.
- A development Mac may reuse Xcode services, DDI cache, system pairing, installed apps or permissive historical ACLs.
- A device test may pass from stale installed/pairing/runtime state unless the run records initial inventory and proof bindings.
- A mocked production port can prove engine decisions but not the native adapter it replaces.
- A clean Mac with a reused Apple account is not a clean Apple scenario.
- One successful reinstall does not cover missing components, second Mac, or expiry.

## Adversarial questions

| Question | Answer / required control |
| --- | --- |
| Can stale state make tests pass? | yes; snapshot initial resources, bind proofs to run/device/generation/artifact, and include empty-root plus contaminated-root lanes |
| Can reinstall break? | yes; all A-W scenarios run through production engine, with installed app data preserved and no pre-clean |
| Can another Mac break it? | yes through certificate quota; other-install markers are never auto-revocable and a two-Mac physical lane is mandatory |
| Can revocation damage unrelated development? | yes if ownership is weak; require exact serial + this-install marker/ledger + inactive-key proof + blocked issuance + persisted intent |
| Can Keychain UI still appear? | auth/pairing Keychain access still can; prompt sentinel and packaged clean-Mac tests remain mandatory. Signing prompts should be structurally removed. |
| Can packaged signing differ? | yes; run actual packaged helper and signer after final Developer ID signing/notarization, not only Swift/Rust tests |
| Can architectures differ? | yes; run signer/store/helper/physical gates on x86_64 and arm64 |
| Are mocks testing release code? | only if the production engine and signer are invoked with port substitutions; delete test-only engine |
| Can physical state invalidate assumptions? | yes; record lock/Trust/Developer Mode/OS/build/install/pairing/VPN/DDI state at start and after every mutation |
| What happens after six months? | certificate expiry triggers candidate identity/profile/sign/install/proof transaction; must be simulated now and soak-tested over real lifecycle |
| What Apple interaction remains? | Trust/passcode, Developer Mode/reboot/confirmation, credentials/2FA, developer-profile Trust and VPN approval where required |

## Vanish differences not yet captured

Vanish packages Python/pmd3 and may have years of downstream signer/protocol fixes not present in the preserved upstream. Its phone-side self-refresh may reduce Mac dependency after the first install. Veya should not claim parity until refresh/expiry and runtime recovery are physically measured. Conversely, Veya's ownership-proofed revocation, active/candidate pairing and Rich runtime requirements are intentionally stricter than observable Vanish evidence.

## Confidence by subsystem

Scores express current planning confidence, not shipping readiness.

| Subsystem | Confidence | Rationale / next proof |
| --- | ---: | --- |
| Architecture | 80% | coherent boundary and evidence-backed root cause; production consolidation not implemented |
| Signing | 60% | strong open-source precedent and clear removal of prompt class; actual Veya payload/device acceptance untested |
| Apple provisioning | 72% | substantial current code/tests and physical auth/profile evidence; private API/7460/live renewal uncertainty |
| Reinstall | 45% | matrix is complete but production transaction and contaminated/clean physical runs absent |
| Device installation | 58% | native transport and simulated tests exist; new signer output and interrupted physical install unproved |
| Pairing | 65% | strong active/candidate tests and one contaminated-host success; clean first install/reboot/reinstall incomplete |
| VPN | 48% | coordinator/tests and one prior success; external approval/acquisition and reboot matrix incomplete |
| AppService | 55% | native path and prior event success; OS matrix and clean packaging incomplete |
| Rich runtime | 52% | explicit proof model exists; full packaged physical proof and recovery incomplete |
| Packaging | 50% | mounted-byte audits are good; Developer ID/notarization/quarantine/update clean lanes unresolved |
| Clean-Mac behavior | 30% | one early Intel no-Xcode flow reached signing, but Builds 1-11 and host contamination prevent confidence |

## Recommendation

**IMPLEMENT**, after explicit authorization, using the milestone order in `15_CONSOLIDATED_IMPLEMENTATION_PLAN.md`. Research is sufficient to reject further ACL patching and begin foundations. Implementation remains blocked from a release candidate, not from starting: production DDI sourcing, signer compatibility, clean packaging and physical scenario gates must be closed before any consumer claim.

Do not create Build 12 until the lower-layer exit gates pass. If the in-process signer cannot sign/install Veya's real nested payload on the physical matrix, stop at Milestone 3/5 and revisit the ADR rather than falling back silently to another Keychain ACL patch.

