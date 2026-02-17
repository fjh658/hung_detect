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
        .executableTarget(
            name: "hung_detect",
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
    ]
)
