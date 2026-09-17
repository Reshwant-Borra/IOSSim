# Vanish versus Veya

| Dimension | Vanish evidence | Current Veya/IOSSim evidence | Conclusion |
| --- | --- | --- | --- |
| Mac packaging | Electron + Python + Rust + IPAs in one signed app | Native Swift + Rust bridge + helper + payloads | Both can be self-contained; Veya is smaller/native |
| Consumer Xcode | No full-Xcode runtime architecture observed | Packaged native path avoids Xcode, but fresh DDI missing | Vanish is stronger only at acquisition/packaging boundary |
| Device backend | PMD plus Rust sideloader | Native idevice Rust ABI implements most required services | Keep Veya native path |
| Apple provisioning | Local helper, private protocols | Substantial local versioned private adapter | Harden Veya adapter; do not copy |
| Pairing UX | Automated place/repair/export | Automated AES-GCM House Arrest import exists | Refactor proof/rollback in Veya |
| Location runtime | DVT coordinate simulation strongly evidenced | Rich XCTest/XCUILocation plus DVT fallback | Veya runtime is richer; preserve it |
| LocalDevVPN | Separate helper relationship | Explicit coordinator and endpoint proof | Veya has clearer code-level state, incomplete delivery UX |
| Renewal | Mobile self-refresh symbols/reminders | Mac-driven refresh model and expiry checks | Veya needs explicit renewal lifecycle |
| Update | GitHub/Squirrel present | No authoritative GitHub release | Veya needs one release authority |
| Diagnostics | Logs/progress/recovery present | Structured events/support export present | Veya must tighten privacy allowlist |

Vanish has no automatic architectural priority. It is stronger evidence for packaging, guided repair, and lifecycle UX. Veya’s retained Rich runtime and native typed bridge are better aligned with its product invariants.
