// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hung_detect",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(
            name: "hung_detect",
            targets: ["hung_detect"]
        ),
    ],
    targets: [
        .target(
            name: "CGSInternalShim",
            path: "Sources/CGSInternalShim",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../third_party/CGSInternal"),
            ]
        ),
        .executableTarget(
            name: "hung_detect",
            dependencies: ["CGSInternalShim"],
            path: "Sources/hung_detect",
            sources: ["main.swift", "Version.swift"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "HungDetectCLITests",
            dependencies: ["hung_detect"],
            path: "Tests/HungDetectCLITests"
        ),
        .testTarget(
            name: "HungDetectCoreTests",
            dependencies: ["hung_detect"],
            path: "Tests/HungDetectCoreTests"
        ),
    ]
)
