// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cyclop",
    // macOS 15: SwiftUI's `.onKeyPress` and `.scrollIndicators`, which the
    // panes use throughout.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cyclop", targets: ["Cyclop"])
    ],
    targets: [
        .executableTarget(
            name: "Cyclop",
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
