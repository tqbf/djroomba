// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextWindow",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ContextWindow",
            targets: ["ContextWindow"]
        ),
        .library(
            name: "ContextWindowOpenAI",
            targets: ["ContextWindowOpenAI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
    ],
    targets: [
        .target(
            name: "ContextWindow",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ContextWindowOpenAI",
            dependencies: ["ContextWindow"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ContextWindowTests",
            dependencies: ["ContextWindow"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ContextWindowOpenAITests",
            dependencies: ["ContextWindow", "ContextWindowOpenAI"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
