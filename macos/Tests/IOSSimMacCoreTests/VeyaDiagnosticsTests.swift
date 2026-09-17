import Foundation
import XCTest
@testable import IOSSimMacCore

final class VeyaDiagnosticsTests: XCTestCase {
    func testEveryLegacyProvisioningErrorHasStableTaxonomyIdentity() {
        for legacyCode in ConsumerProvisioningErrorCode.allCases {
            let descriptor = VeyaErrorTaxonomy.descriptor(for: legacyCode, stage: .failed)
            XCTAssertNotNil(
                descriptor.code.range(of: "^VEYA-[A-Z]+-[0-9]{3}$", options: .regularExpression),
                legacyCode.rawValue
            )
            XCTAssertEqual(descriptor.supportFields["legacyCode"], legacyCode.rawValue)
            XCTAssertEqual(descriptor.supportFields["stage"], ConsumerProvisioningStage.failed.rawValue)
        }
    }

    func testTaxonomyPublishesEveryRequiredNamespace() {
        XCTAssertEqual(Set(VeyaErrorNamespace.allCases.map(\.rawValue)), [
            "VEYA-INTEGRITY", "VEYA-DEVICE", "VEYA-TRUST", "VEYA-DEVSUPPORT",
            "VEYA-APPLE", "VEYA-SIGNING", "VEYA-PROFILE", "VEYA-INSTALL",
            "VEYA-PAIRING", "VEYA-VPN", "VEYA-DEVSERVICE", "VEYA-RUNNER",
            "VEYA-RUNTIME", "VEYA-STATE", "VEYA-UPDATE",
        ])
    }

    func testFailureDescriptorRedactsDeveloperDetailAndModelsUserAction() {
        let failure = ConsumerProvisioningFailure(
            code: .computerTrustRequired,
            stage: .checkingDevice,
            userMessage: "Tap Trust on your iPhone.",
            remediation: "Unlock the iPhone and tap Trust.",
            developerDetail: "password=sentinel-password"
        )

        let descriptor = failure.diagnosticDescriptor

        XCTAssertEqual(descriptor.code, "VEYA-TRUST-003")
        XCTAssertEqual(descriptor.retryability, .afterUserAction)
        XCTAssertEqual(descriptor.requiredUserAction, failure.remediation)
        XCTAssertFalse(descriptor.safeDeveloperDetail.contains("sentinel-password"))
    }

    func testSupportSecretScannerFailsClosedOnEveryProhibitedSecretClass() {
        let unsafe = Data("""
        password=sentinel
        verification-code=123456
        authorization=sentinel
        cookie=sentinel
        pairing-psk=sentinel
        -----BEGIN PRIVATE KEY-----
        sentinel-private-key
        -----END PRIVATE KEY-----
        """.utf8)
        XCTAssertEqual(
            Set(SupportSecretScanner.findings(in: unsafe)),
            ["PRIVATE_KEY", "PASSWORD", "TOKEN", "COOKIE", "PAIRING_SECRET", "TWO_FACTOR_CODE"]
        )

        let safe = Data(Redactor.redact(String(decoding: unsafe, as: UTF8.self)).utf8)
        XCTAssertTrue(SupportSecretScanner.findings(in: safe).isEmpty)
    }
}
