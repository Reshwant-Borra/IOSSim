# Vanish lessons: adopt, adapt, reject

| Pattern | Decision | Reason |
| --- | --- | --- |
| Resolve every packaged dependency from the signed app | ADOPT | Removes repository/environment ambiguity |
| Prebuilt re-signable iPhone payload | ADOPT | Already current Veya architecture |
| Progress and domain-specific repair UI | ADOPT | Reduces destructive full setup reruns |
| One-click pairing placement with manual export fallback | ADAPT | Use Veya’s envelope, request binding, staged proof |
| Per-device/account saved state | ADAPT | Store opaque Keychain refs and scoped metadata, not passwords by default |
| External LocalDevVPN integration | ADAPT | Keep App Store dependency and verify compatibility/readiness |
| GitHub-backed updater/release identity | ADAPT | GitHub Releases is acceptable only with signed manifest and rollback policy |
| Mobile refresh/reminders | ADAPT | Add expiry-aware Mac repair first; phone refresh needs separate security design |
| Bundled Python/PMD | REJECT | Veya already has native bridge; GPL and bundle-size/attack-surface cost |
| Third-party DDI mirror as production source | REJECT pending explicit approval | Supply and rights unresolved |
| Coordinate-only DVT as primary runtime | REJECT | Regresses Rich runtime invariants |
| Default saved Apple password | REJECT | Session/key references can reduce prompts with less secret persistence |
| Mandatory cloud account/telemetry | NOT APPLICABLE | No product requirement established |
| Proprietary Vanish source or wire format | REJECT | Clean-room evidence only |
| Vanish clean first-trust/DDI reliability | UNKNOWN | No live trace in this research |
