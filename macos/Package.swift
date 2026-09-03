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
    targets: [
        .target(name: "IOSSimMacCore"),
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
            dependencies: ["IOSSimMacCore"]
        )
    ]
)
