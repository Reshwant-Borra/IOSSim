// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IOSSimOnDeviceDVTPOC",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "IOSSimOnDeviceDVTPOC",
            targets: ["IOSSimOnDeviceDVTPOC"]
        ),
        .executable(
            name: "POCUnitChecks",
            targets: ["POCUnitChecks"]
        )
    ],
    targets: [
        .target(
            name: "IOSSimOnDeviceDVTPOC"
        ),
        .executableTarget(
            name: "POCUnitChecks",
            dependencies: ["IOSSimOnDeviceDVTPOC"]
        )
    ]
)
