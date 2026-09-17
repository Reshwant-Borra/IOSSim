# Apple-supported architecture

## Supported or documented elements

- macOS code signing, Developer ID distribution, packaging, notarization, stapling, and Gatekeeper are documented Apple distribution mechanisms. `CONFIRMED_APPLE_DOCUMENTATION`
- Developer Mode and “Trust This Computer” are legitimate user-controlled security gates. Veya preserves both. `CONFIRMED_APPLE_DOCUMENTATION`
- Personal Team supports on-device development/testing with limitations; it is not App Store distribution and profiles are short-lived. `CONFIRMED_APPLE_DOCUMENTATION`
- Network Extension packet-tunnel providers are app extensions with Apple-controlled entitlement/configuration approval. An external App Store LocalDevVPN avoids assuming Veya’s Personal Team payload can obtain that entitlement. `CONFIRMED_APPLE_DOCUMENTATION`
- Apple documents downloading additional Xcode components through Xcode and `xcodebuild`. `CONFIRMED_APPLE_DOCUMENTATION`

Official references:

- https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components
- https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
- https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- https://support.apple.com/en-us/109054
- https://developer.apple.com/support/compare-memberships/
- https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment

## What is not a supported substitute

Sign in with Apple authenticates users to apps; it is not Developer Services provisioning authorization. App Store Connect API keys belong to eligible developer teams and do not reproduce a free Personal Team username/password flow. A system `codesign` binary can sign when a valid identity/profile exists, but its presence does not supply certificates, profiles, device trust, SDK products, or DDI assets.

## Supported target envelope

Veya should use public macOS Security/Keychain/process/filesystem APIs, Apple’s ordinary user prompts, and signed/notarized distribution. Device and Personal Team protocol behavior that lacks public Apple APIs must be explicitly labeled private/undocumented, versioned, compatibility-tested, and fail closed. No document may describe that layer as Apple-supported.
