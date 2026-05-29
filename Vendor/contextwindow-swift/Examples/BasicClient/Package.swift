// swift-tools-version: 6.0
import PackageDescription

// Standalone example package. It consumes the ContextWindow library from the
// repo root via a local path dependency, so it is NOT part of the main
// package's build graph (the main package's targets are explicit and live in
// Sources/, never Examples/).
let package = Package(
    name: "BasicClient",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "BasicClient",
            dependencies: [
                .product(name: "ContextWindow", package: "ContextWindow"),
                .product(name: "ContextWindowOpenAI", package: "ContextWindow")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
