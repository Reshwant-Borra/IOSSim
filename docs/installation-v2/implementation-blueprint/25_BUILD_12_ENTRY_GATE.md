# Build 12 Entry Gate

Build 12 is authorized only when a single signed qualification report proves every condition below against the intended release commit. Any required skip is a failure.

- M0 through M12 exit gates are complete.
- All baseline Swift and relevant Rust tests pass; format/lint/check pass; no unexpected skips.
- State-machine/model, journal crash/corruption, hermetic Apple, real key-store, signer golden/integration, certificate, profile, install, reinstall, migration, and failure-injection campaigns pass.
- Production-driven `veya-qualify` passes all safe local stages using the packaged helper and universal bridge.
- Exact Veya payload has been signed by the new path, independently verified, and installed/launched on the qualification iPhone under an authorized test transaction.
- Real packaged key-store create/reopen/upgrade tests generate no SecurityAgent UI.
- Active/candidate failure tests prove the active path survives all named failures.
- Universal `arm64`/`x86_64`, load-command, resource, schema, ABI, SBOM, license, secret, and mounted-byte-equivalent audits pass.
- Runtime on clean test hosts has no repository, Python, Xcode, Cargo/Rust, Homebrew, or network dependency for local signing.
- Static/runtime audits show no legacy payload `/usr/bin/codesign`, SecIdentity, Keychain search-list, ACL/partition repair, or old-signer fallback.
- No known P0/P1 installation defect; every P2 has an owner, user impact, and explicit acceptance.
- Production DDI supported builds are enumerated. Any broader sourcing limitation is displayed as unsupported, not hidden.
- Reports bind git commit, dirty-state policy, toolchains, schemas, fixtures, device/OS scope, and artifact hashes.
- Security review signs off wrapping-key behavior, secret redaction, signer dependency/MPL compliance, pairing storage, and journal permissions.
- A human release owner records `BUILD_12_AUTHORIZED` after reviewing the report.

Implementation completion, a green unit suite alone, or a successful development-Mac install cannot authorize Build 12.

