// swift-tools-version: 5.9
import PackageDescription

// Scenario fixtures and failure injection exist only in debug (qualification) builds; release
// helpers are compiled without them and refuse scenario requests.
let qualificationSettings: [SwiftSetting] = [.define("VEYA_QUALIFICATION", .when(configuration: .debug))]

let package = Package(
    name: "IOSSimMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IOSSimMacCore", targets: ["IOSSimMacCore"]),
        .executable(name: "IOSSimMac", targets: ["IOSSimMac"]),
        .executable(name: "IOSSimProvisioner", targets: ["IOSSimProvisioner"]),
        .executable(name: "IOSSimAuthDiagnostic", targets: ["IOSSimAuthDiagnostic"]),
        .executable(name: "VeyaQualify", targets: ["VeyaQualify"])
    ],
    dependencies: [
        // Pure-Swift arbitrary precision arithmetic used only for the
        // RFC 5054 SRP calculation. Pinned for reproducible local RCs.
        .package(
            url: "https://github.com/attaswift/BigInt.git",
            revision: "63feef7820abb1a8fb08587d7da56bb0b7db8751"
        )
    ],
    targets: [
        .target(
            name: "IOSSimMacCore",
            dependencies: ["BigInt"],
            swiftSettings: qualificationSettings
        ),
        .executableTarget(
            name: "IOSSimMac",
            dependencies: ["IOSSimMacCore"],
            swiftSettings: qualificationSettings
        ),
        .executableTarget(
            name: "IOSSimProvisioner",
            dependencies: ["IOSSimMacCore"],
            swiftSettings: qualificationSettings
        ),
        .executableTarget(
            name: "VeyaQualify",
            dependencies: ["IOSSimMacCore"]
        ),
        .executableTarget(
            name: "IOSSimAuthDiagnostic",
            dependencies: ["IOSSimMacCore"]
        ),
        .executableTarget(
            name: "IOSSimSigningKeyTestHelper",
            dependencies: ["IOSSimMacCore"]
        ),
        .testTarget(
            name: "IOSSimMacCoreTests",
            dependencies: [
                "IOSSimMacCore", "IOSSimAuthDiagnostic", "IOSSimSigningKeyTestHelper", "BigInt",
                "IOSSimProvisioner", "VeyaQualify",
            ],
            exclude: ["Fixtures"]
        )
    ]
)
