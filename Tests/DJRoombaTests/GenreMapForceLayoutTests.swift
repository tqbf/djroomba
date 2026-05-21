import CoreGraphics
import Testing
@testable import DJRoomba

/// Layout-pipeline behaviour tests for `GenreMapForceLayout`.
///
/// **Phase-3-gate 2026-05-20 (the "stop compacting" reset).** The
/// post-settle compaction polish pass that lived in `GenreMapForceLayout`
/// is gone — it was a fit-to-viewport hack that fought the user's
/// "pan/zoom is the interaction; give labels more room" directive.
/// These tests pin the new defaults (`worldSide = 5000`, `idealEdgeLength
/// = 700`, no compaction pass) and the layout's determinism / non-
/// regression on a deterministic fixture.
struct GenreMapForceLayoutTests {

  /// Pin the Phase-3-gate widened defaults so a future agent can't
  /// silently re-shrink the world or re-bake compaction pressure back
  /// in. The numbers themselves are documented inline in
  /// `GenreMapForceLayout.Configuration`.
  @Test
  func `phase-3-gate defaults: worldSide 5000, idealEdgeLength 700, no compaction`() {
    let configuration = GenreMapForceLayout.Configuration()
    #expect(configuration.worldSide == 5000)
    #expect(configuration.idealEdgeLength == 700)
    #expect(configuration.edgeAttraction == 0.030)
    // The compaction pass was deleted — `Configuration` no longer
    // carries a `compactionIterations` knob. This compile-time check
    // (the field is gone, this file refers to none) plus the absence
    // of the post-settle pass in `layout(...)` is the gate.
  }

  /// Layout determinism: identical inputs ⇒ identical positions across
  /// runs. The SplitMix64 seed is fixed; no global state; pure.
  @Test
  func `layout is deterministic on a fixture`() throws {
    let inputs: [GenreMapForceLayout.InputNode] = (0 ..< 6).map { index in
      GenreMapForceLayout.InputNode(
        id: "N\(index)",
        weight: 0.5,
        labelSize: CGSize(width: 60, height: 24),
        communityID: index / 3, // two communities of 3
      )
    }
    let edges = [
      GenreMapEdge(genreA: "N0", genreB: "N1", totalWeight: 0.9),
      GenreMapEdge(genreA: "N1", genreB: "N2", totalWeight: 0.85),
      GenreMapEdge(genreA: "N3", genreB: "N4", totalWeight: 0.9),
      GenreMapEdge(genreA: "N4", genreB: "N5", totalWeight: 0.85),
      GenreMapEdge(genreA: "N2", genreB: "N3", totalWeight: 0.4),
    ]
    let lhs = GenreMapForceLayout.layout(nodes: inputs, edges: edges)
    let rhs = GenreMapForceLayout.layout(nodes: inputs, edges: edges)
    for input in inputs {
      let lhsP = try #require(lhs.positions[input.id])
      let rhsP = try #require(rhs.positions[input.id])
      #expect(lhsP.x == rhsP.x)
      #expect(lhsP.y == rhsP.y)
    }
  }

  /// Label-aware repulsion (the main settle pass — no compaction) keeps
  /// a ring of same-community heavy labels non-overlapping at the
  /// Phase-3-gate widened world. Replaces the Phase-1 / 2 "post-pipeline
  /// labels do not overlap on a dense ring" test that relied on the
  /// compaction pass. With `idealEdgeLength = 700` the equilibrium
  /// pair distance is well clear of the label rectangles.
  @Test
  func `phase-3-gate: labels do not overlap on a small same-community ring at default config`() {
    let nodeCount = 6
    var inputs = [GenreMapForceLayout.InputNode]()
    for index in 0 ..< nodeCount {
      inputs.append(GenreMapForceLayout.InputNode(
        id: "N\(index)",
        weight: 0.5,
        labelSize: CGSize(width: 90, height: 24),
        communityID: 0,
      ))
    }
    var edges = [GenreMapEdge]()
    for index in 0 ..< nodeCount {
      let a = "N\(index)"
      let b = "N\((index + 1) % nodeCount)"
      edges.append(GenreMapEdge(
        genreA: min(a, b),
        genreB: max(a, b),
        totalWeight: 1.0,
      ))
    }
    let output = GenreMapForceLayout.layout(nodes: inputs, edges: edges)
    let halfBox = Dictionary(uniqueKeysWithValues: inputs.map {
      ($0.id, CGSize(width: $0.labelSize.width / 2, height: $0.labelSize.height / 2))
    })
    let names = inputs.map(\.id)
    for lhs in 0 ..< names.count {
      for rhs in (lhs + 1) ..< names.count {
        guard
          let lhsP = output.positions[names[lhs]],
          let rhsP = output.positions[names[rhs]],
          let lhsH = halfBox[names[lhs]],
          let rhsH = halfBox[names[rhs]]
        else { continue }
        let dx = abs(lhsP.x - rhsP.x)
        let dy = abs(lhsP.y - rhsP.y)
        let overlapX = (lhsH.width + rhsH.width) - dx
        let overlapY = (lhsH.height + rhsH.height) - dy
        let overlaps = overlapX > 0 && overlapY > 0
        #expect(
          !overlaps,
          "labels \(names[lhs]) and \(names[rhs]) overlap: overlapX=\(overlapX), overlapY=\(overlapY)",
        )
      }
    }
  }
}
