# Device Stack Decision

## Decision

Use a native Rust device bridge linked as a static library through the existing signed IOSSimProvisioner process boundary. Pin idevice at commit 1838db107d38701b4044361163aac049006c2627 (0.1.67, MIT) and expose an IOSSim-owned versioned C ABI/Swift wrapper. Keep the existing iPhone-side FFI pin and runtime separate. Do not embed pymobiledevice3 in the consumer. Do not make libimobiledevice the modern developer-service stack.

## Options

| Criterion | Rust native | Bundled pmd3 | Hybrid | libimobiledevice supplemental | Apple private components |
|---|---:|---:|---:|---:|---:|
| iOS 26/RSD | high | high current source | high | low-medium | medium |
| Xcode independence | high | high | high | high | medium |
| DDI/Developer Mode | high | high | high | classic plus gap | unknown |
| Install/AFC/House Arrest | high | high | high | high | medium |
| RemotePairing/DVT | high | high | high | insufficient alone | medium |
| Packaging | small native | Python/runtime/deps | hardest | C plus supplement | not redistributable |
| License | MIT, audit transitive | GPL-3.0-or-later | GPL plus Rust | LGPL 2.1 | Apple terms |
| Testability/security | typed ABI | larger runtime | many boundaries | C safety | opaque |
| Decision | PRIMARY | reference/diagnostic | rejected | fallback/oracle | rejected |

Current pmd3 11.12.5 requires Python >=3.9 and is GPL-3.0-or-later. It has excellent current USB/Lockdown, RemotePairing/CoreDevice tunnels, AMFI, personalized images, installation_proxy, AFC, House Arrest and DVT/XCTest coverage. It is not embedded due to license, dependency/runtime surface and upgrade burden. Subprocess isolation does not automatically erase GPL obligations.

Pmd3 is pure Python at the package layer and advertises Windows, Linux and macOS, but tunnel choices vary by platform and macOS version; the audited source does not give IOSSim a stable supported-macOS contract. It has a substantial dependency graph for cryptography, plist/serialization, HTTP/QUIC/TCP helpers, image/TSS tooling and optional tunnel stacks. A bundled interpreter is a packaging and signing surface, not merely the 1.2 MB wheel. It generally avoids root for userspace tunnels but cannot remove the macOS usbmux/USB device services.

Current pmd3 documentation explicitly supports iOS 17+ developer services. On macOS it prefers the system remoted/remotepairingd path without root or Xcode; on iOS 17.4+ it can use in-process CoreDeviceProxy without privilege; iOS 17.0-17.3.1 is routed through native remoted on macOS. Its documentation does not declare a minimum macOS release, so IOSSim must treat macOS 13 compatibility as UNKNOWN until its own gate rather than inherit a claim. iOS 18.2+ removes the older QUIC tunnel path in current source and uses TCP, with Python 3.13 constraints in that implementation. Those details illustrate why importing pmd3’s whole transport selector would increase maintenance.

libimobiledevice is mature LGPL 2.1 for classic usbmuxd, lockdownd, AFC, House Arrest, Installation Proxy and current image-mounter pieces. The audited tree does not supply IOSSim’s full RemotePairing/CoreDevice/RSD/DVT/TestManager path. Use only as a supplemental classic-service fallback if needed.

Its normal architecture expects the system usbmuxd daemon and C callers; it is portable but has C ownership and daemon-packaging concerns. Developer Mode and iOS 17+ personalized mounter support do not imply current RSD/DVT parity. Any supplemental use needs separate dynamic-link/relink and notice review.

idevice has concrete modules for usbmuxd, Lockdown, pairing, AMFI, image mounter/TSS, CoreDeviceProxy, RSD/RemoteXPC, RemotePairing, Installation Proxy, AFC, House Arrest, AppService, DVT and XCTest feature gates. Its pre-0.2 API may break, hence the ABI. Its pairing convenience connector can regenerate keys on any validation failure; the wrapper must call explicit pair-verify and only regenerate on classified missing/stale records.

The crate is MIT and exposes an FFI-friendly workspace pattern, making Swift interoperability practical without exposing Tokio/Rust types. A release build should produce universal arm64/x86_64 archives, LTO and an SBOM; exact size is a release measurement. Active maintenance is useful, but IOSSim must own its compatibility layer and run a compile smoke test on every pin update.

idevice source explicitly models CoreDeviceProxy and RSD for iOS 17+, XCTest through lockdown for older systems and RSD for iOS 17+, and paired-host mDNS behavior introduced in iOS 26.4+. It does not publish a formal host/iOS compatibility matrix or stable-API guarantee. Therefore source availability is CONFIRMED, the first iOS 17.4/18/26 product matrix is LIKELY, and each physical cell remains REQUIRES_PHYSICAL_VALIDATION.

XcodesLoginKit is IDMSA web authentication, not a Personal Team GSA replacement. Current xtool and isideload release are reference implementations for auth fields, not copied dependencies.

## Apple System Component Boundary

| Component | Availability | Consumer use decision |
|---|---|---|
| macOS usbmux/device daemon and USB plumbing | built into macOS behavior observed by public stacks | use through protocol/socket; do not redistribute |
| Foundation URLSession, Security/Keychain, CommonCrypto/CryptoKit, codesign/security/ditto | macOS system tools/frameworks | legitimate packaged-app building blocks, subject to normal platform rules |
| AOSKit/AuthKit | private system frameworks present on audited macOS | existing dynamic use may remain behind availability checks; no copying; legal/release compatibility review |
| MobileDevice/CoreDevice private frameworks | system/Xcode-private implementation detail | do not link/copy as the device stack |
| devicectl, xcodebuild and iPhone SDK/platform assets | full Xcode | build/release only; no consumer invocation |
| Command Line Tools | separate Apple package; xcodebuild/devicectl not supplied as a full substitute | do not require from consumers |
| DDI/personality assets | delivered with Apple developer support/Xcode or separately sourced | discover authorized local cache or approved provider; rights review required |

## Option E: Native-remoted Adapter

A fifth architecture is a Swift/Rust adapter that piggybacks Apple’s per-user remoted/remotepairingd, similar to pmd3’s current macOS native path. It can provide a no-root kernel-routable RSD endpoint and may perform better than a userspace TCP stack. It is not the primary because it relies on undocumented daemon IPC and OS-specific behavior, and IOSSim already needs its own explicit USB pairing, installation and container protocols. The bridge may add it later as a capability-selected acceleration after CoreDeviceProxy userspace behavior is proven; failure must fall back inside the same process, not start a privileged daemon.

## Platform and Packaging

Host baseline remains macOS 13+ and universal Intel/Apple Silicon. First product matrix is iOS 17.4+, 18.x and 26.x as separately qualified cells; app deployment target 17.0 is not a protocol promise. Consumer runtime ships signed Swift app/provisioner plus signed universal Rust bridge and manifest. Consumer execution requires no full Xcode, Python, Node, repository or arbitrary shell. Build and notarization may use Xcode on CI.

## ABI

Minimum calls: version, discover, open device, inspect, readiness, install, upgrade, uninstall, list apps, launch, read/write container, ensure/validate RemotePairing, open RSD, close. Every call has timeout, cancellation, identity token and safe receipt. Rust cannot receive arbitrary commands or paths.
