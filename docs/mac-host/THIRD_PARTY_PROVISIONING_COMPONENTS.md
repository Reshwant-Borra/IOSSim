# Third-Party Provisioning Components

Audit date: 2026-09-07. Distribution status: `LOCAL_TEST_ONLY`.

| Component | Version / commit | Purpose | License | Linkage / redistribution | Source disclosure | Production conclusion |
| --- | --- | --- | --- | --- | --- | --- |
| `jkcoxson/idevice` and `idevice-ffi` | crate 0.1.66; `c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5` | iPhone-side RPPairing, tunnel, RSD, DVT, LocationSimulation, XCTest; candidate Mac discovery/pair/install stack | MIT | Statically linked into the iPhone artifact. Preserve copyright and MIT permission/warranty notice in distributions | No copyleft source-disclosure duty | Technically acceptable under MIT after all dependency notices are complete; physical/protocol qualification is separate |
| `idevice-tools` | 0.1.66 at the same pin | Reference implementation for discovery, lockdown pairing, RPPairing, install, and inventory | MIT | Not currently bundled or invoked | None | Do not bundle the broad CLI as-is; it can select the first device and has non-production error behavior |
| `idevice_pair` | inspected 2026-09-07 | Reference GUI for lockdown/RPPairing generation, validation, and AFC app handoff | MIT | Not included, linked, downloaded, or invoked | None | Redistribution permission exists under MIT, but IOSSim should use the already-pinned idevice library instead |
| `libimobiledevice` | none | No current purpose | LGPL-2.1-or-later (project libraries; component-specific review would be required) | Not included or linked | Potential LGPL obligations if introduced | Not required and not approved for addition by this work |
| `idevicepair` from libimobiledevice | none | No current purpose | LGPL-2.1-or-later in the current source file | Not included or invoked | LGPL relinking/source obligations would apply if distributed in a combined work | Not required; do not bundle without a separate legal review |
| `usbmuxd` / `libusbmuxd` | none | The target design talks to Apple's existing macOS usbmux service through Rust protocol code | Upstream daemon is GPL-2.0; client library is LGPL-2.1; neither is shipped here | No daemon/library included | None for Apple's system service use | External Homebrew usbmuxd is not a customer prerequisite |
| Apple usbmux service | macOS system component | USB device multiplexing endpoint | Apple system software | Used in place; not redistributed | Not applicable | Acceptable ordinary macOS dependency |

The exact checked-in idevice license is `ios/Vendor/idevice/LICENSE.txt`. Package
assembly now copies it to
`Contents/Resources/ThirdPartyNotices/idevice-LICENSE.txt`, and `audit-app`
requires an exact hash match.

License sources inspected:

- <https://github.com/jkcoxson/idevice/blob/c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5/LICENSE>
- <https://github.com/jkcoxson/idevice_pair>
- <https://github.com/libimobiledevice/libimobiledevice/blob/master/tools/idevicepair.c>
- <https://github.com/libimobiledevice/libusbmuxd>
- <https://github.com/libimobiledevice/usbmuxd>

## Rust Dependency Audit

`cargo metadata --offline` was run against the pinned FFI workspace. The graph
reports permissive choices including MIT, Apache-2.0, ISC, BSD-2-Clause,
BSD-3-Clause, Zlib, 0BSD, Unlicense, CC0/MIT-0, Unicode-3.0, and
CDLA-Permissive-2.0. It also reports:

- `cbindgen` as MPL-2.0, used as a build tool rather than linked runtime code;
- `r-efi` with the disjunctive choice `MIT OR Apache-2.0 OR LGPL-2.1-or-later`,
  allowing a permissive license choice;
- workspace packages with `UNKNOWN` metadata (`idevice-ffi` and the test
  harness), which are repository-local wrappers and still require explicit
  notice metadata before public distribution.

No GPL/LGPL component was intentionally linked into the current iPhone runtime.
However, copying only the top-level idevice MIT notice is not a complete
transitive attribution bundle. Before a public release, generate and review a
locked dependency SBOM/notice file from the exact feature-resolved release
build, include all required notices, record hashes, and obtain distribution
review. Therefore production public distribution is **not yet approved by this
licensing audit**. The local RC remains acceptable for private qualification.

## Integrity Requirements

- Keep the idevice commit pin and patch in source control.
- Verify the required symbols, including RPPairing serialization, during build.
- Hash every bundled helper/library in the package manifest before enabling a
  native host bridge.
- Codesign helpers with the containing app and verify signatures without using
  `--deep` as a signing-order substitute.
- Never download executable code at runtime.
- Never package pairing data, Apple credentials, signing keys, profiles, or
  developer-machine paths.
