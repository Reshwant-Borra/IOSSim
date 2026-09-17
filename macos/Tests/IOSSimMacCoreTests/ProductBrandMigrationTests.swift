import XCTest
@testable import IOSSimMacCore

final class ProductBrandMigrationTests: XCTestCase {
    func testMigrationReleaseUsesVeyaDisplayBrand() {
        XCTAssertEqual(ProductBrand.displayName, "Veya")
        XCTAssertEqual(ProductBrand.migrationDisplayName, "Veya (formerly IOSSim)")
        XCTAssertEqual(ProductBrand.userFacing("Install IOSSim on this iPhone"), "Install Veya on this iPhone")
    }

    func testCompatibilityIdentitiesRemainStable() {
        XCTAssertEqual(ProductBrand.macBundleIdentifier, "com.iossim.mac-provisioner")
        XCTAssertEqual(ProductBrand.applicationSupportNamespace, "IOSSim")
        XCTAssertEqual(ProductBrand.preferencesNamespace, "IOSSimMac")
        XCTAssertEqual(ProductBrand.phoneBundleIdentifier, "com.iossim.on-device-dvt-poc")
        XCTAssertEqual(ProductBrand.runnerBundleIdentifier, "com.iossim.location-control-uitests.xctrunner")
        XCTAssertEqual(ProductBrand.pairingKeychainService, "com.iossim.on-device-dvt-poc.rppairing")
    }

    func testSetupErrorBrandsOnlyUserFacingFields() {
        let error = SetupError(
            headline: "IOSSim could not finish setup.",
            recovery: "Reopen IOSSim and try again.",
            details: "internal path: Library/Application Support/IOSSim"
        )

        XCTAssertEqual(error.headline, "Veya could not finish setup.")
        XCTAssertEqual(error.recovery, "Reopen Veya and try again.")
        XCTAssertEqual(error.details, "internal path: Library/Application Support/IOSSim")
    }
}
