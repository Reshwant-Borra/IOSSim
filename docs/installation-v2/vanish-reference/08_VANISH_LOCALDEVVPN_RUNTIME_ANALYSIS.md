# Vanish LocalDevVPN and runtime analysis

The Vanish IPA advertises/query-references `localdevvpn`; desktop code establishes RSD independently and the phone payload participates in pairing/runtime. The Mac bundle does not contain a clearly installable LocalDevVPN payload, and static evidence does not prove whether Vanish deep-links to the App Store, requires prior installation, or owns a separate distribution channel. `CONFIRMED_VANISH_ARTIFACT`; acquisition ownership `UNKNOWN`.

Veya's current policy should remain explicit: LocalDevVPN is an external App Store dependency identified by `com.jkcoxson.LocalDevVPN`. Veya checks inventory, guides installation when missing, launches it through native AppService, triggers its own phone-side inbox, waits for Apple's VPN approval, and verifies the expected authenticated runtime endpoint. Apple VPN consent remains a user action.

Veya's runtime differs materially from Vanish. It must retain RPPairing, supplied RSD, TestManager/XCTest runner, XCUILocation, DriveScheduler smooth 2 Hz with 1 Hz fallback, Stop & Hold, Resume, Clear, destination hold, and the single-writer/no-backlog invariants. Vanish can inform setup UX and reconnect behavior; it cannot substitute for a successful Veya Rich runtime proof.

Target LocalDevVPN states are `MISSING`, `INSTALLED`, `VPN_PERMISSION_REQUIRED`, `CONFIGURED`, `RUNNING`, and `RUNTIME_ENDPOINT_REACHABLE`. Scene activation must restart a pending phone-side request observer; a one-shot `.task` is insufficient.
