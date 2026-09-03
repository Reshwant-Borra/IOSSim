// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IOSSimMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IOSSimMacCore", targets: ["IOSSimMacCore"]),
        .executable(name: "IOSSimMac", targets: ["IOSSimMac"])
    ],
    targets: [
        .target(name: "IOSSimMacCore"),
        .executableTarget(
            name: "IOSSimMac",
            dependencies: ["IOSSimMacCore"]
        ),
        .testTarget(
            name: "IOSSimMacCoreTests",
            dependencies: ["IOSSimMacCore"]
        )
    ]
)
