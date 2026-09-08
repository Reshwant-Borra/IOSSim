// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IOSSimMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IOSSimMacCore", targets: ["IOSSimMacCore"]),
        .executable(name: "IOSSimMac", targets: ["IOSSimMac"]),
        .executable(name: "IOSSimProvisioner", targets: ["IOSSimProvisioner"])
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
            dependencies: ["BigInt"]
        ),
        .executableTarget(
            name: "IOSSimMac",
            dependencies: ["IOSSimMacCore"]
        ),
        .executableTarget(
            name: "IOSSimProvisioner",
            dependencies: ["IOSSimMacCore"]
        ),
        .testTarget(
            name: "IOSSimMacCoreTests",
            dependencies: ["IOSSimMacCore", "BigInt"],
            exclude: ["Fixtures"]
        )
    ]
)
