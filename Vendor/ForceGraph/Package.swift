// swift-tools-version: 5.10
import PackageDescription

// VENDORED copy of tqbf/fdg's `ForceGraph` library, pinned at the v1.0.0
// commit 0a8a43e8b19d14cd2ae8da8f95ae390944e3c603 (the revision djroomba
// previously consumed remotely). Vendored — not a remote SPM dependency —
// so two upstreamable fixes can be applied that have no public API hook
// (see Sources/ForceGraph/GraphEngine.swift "DJROOMBA PATCH" comments).
// The Lab executable, the test target and the corpus were dropped: djroomba
// only links the `ForceGraph` library product.
let package = Package(
    name: "ForceGraph",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ForceGraph",
            targets: ["ForceGraph"]
        )
    ],
    targets: [
        .target(
            name: "ForceGraph"
        )
    ]
)
