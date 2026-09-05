# Production And Development Variants

Both variants are built from the same Swift packages and iPhone sources. They do
not duplicate the app or runtime architecture.

## Production

Production is compiled with `IOSSIM_BUNDLED_ENGINE` and uses
`BundledProvisioningEngine` plus the compiled `IOSSimProvisioner` helper.

- consumer setup stages and friendly errors
- explicit iPhone and Personal Team selection
- bundled profile-free main and runner artifacts
- no repository lookup or CLI fallback
- no Witness artifact or install
- no Gate 3, raw XCTest, raw service, or Drive validation controls in normal UI
- sanitized support bundle export
- dashboard refresh, repair, and profile validity

The production host still requires Xcode-managed account state, Apple developer
tooling, and `devicectl`. It does not collect Apple credentials.

## Development

Development uses `DevelopmentCLIEngine` and may invoke repository `./iossim`
commands. It retains current developer diagnostics and validation tooling,
including Gate 3 controls, Apple Location Controls, Drive Diagnostics, Witness,
verbose logs, raw bundle IDs, provisioning details, and exact service failures.

Developer source identities and defaults remain canonical. Personal Team derived
identities are generated only for consumer-installed artifacts.

## Build Separation

`./iossim package-app` compiles the production feature gate and packages only
the compiled GUI, compiled helper, artifact manifest, main iPhone app, and XCTest
runner. Development repository location files and source are forbidden by the
package audit. There is no user-facing engine switch that can route a production
install through the repository.
