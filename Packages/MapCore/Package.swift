// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MapCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "MapCore", targets: ["MapCore"]),
    ],
    targets: [
        .target(
            name: "MapCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapCoreTests",
            dependencies: ["MapCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
