# Commercial Architecture Evidence

Commercial sources are useful market evidence but weak protocol evidence. Treat all product behavior descriptions below as VENDOR CLAIM unless independently corroborated.

## iAnyGo / iAnyGo iOS Assistant

STATUS: VENDOR CLAIM

Observed vendor documentation:

- Computer installs iAnyGo iOS Assistant and signs in with Apple account.
- iOS app is installed and trusted under VPN & Device Management.
- User adds VPN configuration and changes location from the iOS app.
- Vendor says the computer is no longer needed after installing the iOS app, with seven-day login/validity extension language.

Interpretation: supports "computer-assisted provisioning then phone-only runtime" as a shipped commercial model. It does not prove the DVT/RPPairing/LocalDevVPN implementation details.

## iMyFone AnyTo / iGo

STATUS: VENDOR CLAIM

Observed vendor documentation:

- First-time iOS users need a computer to install desktop helper.
- iOS 16+ requires Developer Mode.
- iOS 17 flow mentions driver/config profile steps.
- The iGo iOS app uses a stable Wi-Fi/VPN configuration workflow.

Interpretation: likely helper-app/provisioning architecture. The docs do not expose whether the "native" mode is DVT, NetworkExtension, accessory/Bluetooth, or network positioning.

## MocPOGO And Similar

STATUS: VENDOR CLAIM

Vendor pages claim no jailbreak/root and iOS direct download for broad iOS ranges. Current public pages are not detailed enough to classify the underlying engine.

## Mode Separation

STATUS: CONFIRMED NEED

Do not conflate:

- desktop DVT location simulation;
- desktop-to-phone Wi-Fi/Bluetooth workflows;
- helper iOS app plus VPN;
- external GPS/accessory-style Bluetooth flows;
- WLOC/network-positioning MITM;
- modified app/client-specific behavior.

The IOSSim POC should intentionally test DVT software simulation and record `isSimulatedBySoftware` so it does not accidentally validate only a weaker network-positioning or accessory mode.
