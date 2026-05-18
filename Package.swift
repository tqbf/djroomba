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
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    // apple/swift-profile-recorder: in-process sampling profiler for perf
    // investigations. Dormant unless PROFILE_RECORDER_SERVER_URL_PATTERN is
    // set at launch; the server is only started behind `#if DEBUG` (see
    // App/PlaylistPlayerApp.swift), so release/notarized builds never run it.
    // Used to profile the known import hot path (see plans/profiling.md).
    .package(
      url: "https://github.com/apple/swift-profile-recorder.git",
      .upToNextMinor(from: "0.3.0"),
    ),
    // swift-log: required to construct the `Logger` that
    // `ProfileRecorderServer.runIgnoringFailures(logger:)` takes. Already in
    // the graph transitively via swift-profile-recorder; declared directly
    // so the target can `import Logging`. Only referenced behind `#if DEBUG`.
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.1"),
    // tqbf/fdg — ForceGraph: a reusable SwiftUI force-directed graph
    // control. **Vendored** at `Vendor/ForceGraph` (the exact v1.0.0
    // commit 0a8a43e we previously consumed remotely), not a remote SPM
    // dependency, so two upstreamable fixes with no public API hook can be
    // applied — the search-pulse redraw-pin (cursor flicker / tight loop)
    // and pan-only (vs zoom-to-readable) search centring. See the
    // "DJROOMBA PATCH" comments in Vendor/ForceGraph and plans/genre-graph.md.
    .package(path: "Vendor/ForceGraph"),
  ],
  targets: [
    .executableTarget(
      name: "DJRoomba",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "ProfileRecorderServer", package: "swift-profile-recorder"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ForceGraph", package: "ForceGraph"),
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
