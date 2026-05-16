// swift-tools-version: 6.0
import PackageDescription

// DJ Roomba builds with SwiftPM only — no .xcodeproj, no XcodeGen, no
// xcodebuild. `swift build` compiles the executable; ./build.sh assembles &
// signs the .app; the Makefile orchestrates dev/run/install/dist. Xcode is
// only ever a toolchain provider (swift / codesign / notarytool / stapler),
// invoked by `make dist`. This mirrors the tqbf/mdv build environment.
//
// GRDB (roadmap Phase 2 / M3, local-first pivot) is the SQLite layer that
// owns the library. Pinned to a major version per the risk register
// ("Third-party dependency: GRDB — pin a major version"); never edit a
// shipped migration (see DJRoomba/Persistence/Database/LibraryMigrator.swift).
//
// The DJRoomba executable target keeps its `@main`; on the Swift 6.3 SwiftPM
// toolchain `@testable import DJRoomba` from a .testTarget links and runs
// cleanly (verified), so no `@main` restructuring is needed and app behavior
// is unchanged. `swift test` is the Phase 2 store/migration gate.

let package = Package(
  name: "DJRoomba",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
  ],
  targets: [
    .executableTarget(
      name: "DJRoomba",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: "DJRoomba",
      exclude: [
        "Info.plist",
        "DJRoomba.entitlements",
      ],
      swiftSettings: [
        // Swift 6 language mode == strict concurrency "complete",
        // matching the retired project.yml's
        // SWIFT_STRICT_CONCURRENCY: complete.
        .swiftLanguageMode(.v6)
      ],
    ),
    .testTarget(
      name: "DJRoombaTests",
      dependencies: [
        "DJRoomba",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests/DJRoombaTests",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ],
    ),
  ],
)
