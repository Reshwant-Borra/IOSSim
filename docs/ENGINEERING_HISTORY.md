# Engineering History

This document keeps lessons that should influence future work without cluttering
the current-state overview.

## Preserved Lessons

| Issue | Lesson |
| --- | --- |
| Missing provisioning manifest routing | Consumer setup must route through the packaged helper and persisted manifest, not stale development assumptions. |
| Canonical main bundle ID portability | Canonical source IDs cannot be assumed available for arbitrary Personal Teams; deterministic derived IDs are required for installed artifacts. |
| Keychain codesign prompts | Keychain access must remain scoped and explicit. Do not use broad `set-key-partition-list` or weaken ACLs. |
| TLS PSK / RPPairing mismatch | Parsing pairing material is not proof of physical trust. Tunnel creation must validate updated RPPairing state and preserve prior valid records on update failure. |
| Stale RSD/TestManager service state | Refresh can preserve app data while invalidating retained service handles. Rebuild runtime handles once and restore current position. |
| Historical-team state contamination | Stale local manifests must not override authoritative current selected-device inventory and current provisioning context. |
| Redacted signing fingerprint | Do not compare signing identifiers after diagnostic redaction. Resolve identity cryptographically and keep output redaction separate from internal matching. |
| False install verification | Do not let pre-install inventory overrule post-install authoritative evidence. |
| Developer-profile trust classification | Installed is not trusted, and trusted is not runtime-ready. Model all three explicitly. |
| Fresh Install misuse | Fresh Install is a deliberate repair operation, not the default response to trust, runtime, or transient inventory issues. |

## RPPairing History

Earlier work found that RPPairing material could parse successfully while the
physical TLS PSK tunnel still failed with "Connection reset by peer." The
architecture was improved to serialize updated RPPairing state, validate it,
persist it securely in Keychain, and preserve the previous valid record if an
update fails.

Physical evidence proves the runtime chain with valid pairing material. Clean
recovery behavior across all pairing update edge cases remains a test area, not a
license to redesign the runtime.

## Legacy Host Architecture

The old host-controlled React/Vite + FastAPI application remains preserved on
the `desktop-legacy` branch and in historical docs. It used the computer as the
runtime control plane. The current native product uses the Mac mainly for setup,
refresh, signing, installation, diagnostics, and support; normal location
simulation is intended to run from the iPhone runtime app.

## Documentation Rule

When older documents conflict with these current handoff documents, prefer:

1. current source code;
2. current physical evidence;
3. `docs/CURRENT_STATE.md`;
4. focused current docs in `docs/`;
5. historical mac-host, wireless, and drive documents.
