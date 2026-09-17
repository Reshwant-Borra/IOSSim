# Open-source reference audit

Research snapshots were inspected; only `idevice` is currently linked by the native bridge.

| Project | Pinned revision | License | Question answered | Use/risk |
| --- | --- | --- | --- | --- |
| jkcoxson/idevice | `1838db107d38701b4044361163aac049006c2627` | MIT | usbmux, Lockdown pair, DDI/TSS, AFC/install, RSD/AppService | Linked; keep pinned, include copyright/license and transitive SBOM |
| pymobiledevice3 | `fc0d053411fa1d3c9e80efc17962dc6b4e50526d` | GPL-3.0-or-later | Current DDI acquisition and device-service reference | Studied only; do not bundle without license/product review |
| libimobiledevice | `fa0f79190142bc309307967c058f89c1b36eb6b8` | LGPL-2.1 library; tools vary | Mature Lockdown/mounter comparison | Studied only; adoption would require link/relink analysis |
| DeveloperDiskImage | `5423e4e955fbb3a9eef3e1212acfbfc6e7a26236` | package declares GPL-3.0-or-later; snapshot lacks license file | PMD asset layout/source | Studied only; Apple binary rights remain separate |
| isideload main | `b6d111376657a59207ac26c8ef8be5cca8793cba` | MIT | Personal Team reference, stale token lesson | Studied only |
| isideload release | `f6a4d5dba717d72fc2af63eaba26b27ba44116be` | MIT | Corrected 2026 auth/client behavior | Studied only; version fragility evidence |
| xtool | `4208c77c8128568f8b938d0c67d2f4bdcf04e100` | MIT | Independent Swift GrandSlam implementation | Studied only |
| apple-private-apis | `03beb1aa42991ccdad6214dee77e72282bef461f` | MPL-2.0 | Historical local metadata reference | Studied only; older/maintenance risk |

The snapshots are recent enough to answer the bounded questions, except the historical apple-private-apis source. “Maintained” does not make a private Apple protocol stable.

## Distribution finding

The current canonical assembler copies `idevice-LICENSE.txt` and `BigInt-LICENSE.txt`. It does not prove that every Cargo.lock dependency’s notice/source obligation is covered. V2 release creates an SPDX or CycloneDX SBOM from exact resolved Swift/Rust dependencies, checks license policy, packages required texts, records local modifications, and fails if any dependency has unknown/incompatible metadata. `CONFIRMED_LOCAL_IOSSIM_CODE`

Apple DDI binaries, trust caches, SDK content, and private service use are governed independently from wrapper code licenses. This audit is engineering evidence, not a legal opinion.
