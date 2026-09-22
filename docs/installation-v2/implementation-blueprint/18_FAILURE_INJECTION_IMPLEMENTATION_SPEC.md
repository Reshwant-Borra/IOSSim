# Failure Injection Implementation

## Mechanism

Inject protocols at real domain boundaries: clock, random/ID source, filesystem/atomic writer, Keychain client, Apple transport, signer, device transport, DDI provider/TSS, pairing delivery, VPN endpoint, and runtime prover. Production composition uses live implementations; tests substitute fakes. Planner, journal, promotion, recovery, and error mapping are identical.

`FailureSchedule` maps `(domain, operation, ordinal)` to an action: throw typed error, return fixture, delay, disconnect, corrupt returned bytes, or terminate at a named crash point. Compile-time test support supplies schedules to unit tests; packaged debug qualification accepts only a signed local fixture and is omitted/disabled in release distribution.

## Mandatory scenarios

| Injection | Boundary | Expected invariant |
|---|---|---|
| auth expired / API unavailable | Apple transport | old session retained; user/retry class correct |
| 7460 / capacity full | certificate API | refresh, revoke max one owned, issue max twice |
| owned stale / unknown cert | inventory fixture | owned selectable; unknown never revoked |
| key/metadata missing | observer | reconstruct or replace; no label inference |
| key corruption | key store decrypt | active not used; GCM failure classified |
| stale profile | profile observer | candidate renewal; no stale promotion |
| sign failure | signing core | source/active untouched |
| install failure/disconnect/locked | device transport | inventory resolves ambiguity; no uninstall |
| DDI missing / TSS failure | provider/mounter | exact-build/actionable failure |
| pairing failure | delivery/possession | active pairing retained |
| VPN failure | endpoint proof | never advances to runtime |
| AppService / Rich failure | runtime prover | never READY; cleanup attempted |
| crash before candidate promotion | crash point | candidate recoverable, active intact |
| crash after proof before promotion | crash point | proof revalidated then promotable |
| crash during journal write | atomic writer | old or new valid document, never mixed |
| disk full / wrong clock | filesystem/clock | typed safe stop; no destructive repair |

Each scenario asserts external call count/order, durable journal state, active/candidate survival, first error code, emitted secrets absence, and successful resume. Fakes cannot directly edit the journal or return READY.

