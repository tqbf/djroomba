import CoreGraphics
import Testing
@testable import DJRoomba

/// Layout-pipeline behaviour tests for `GenreMapForceLayout`
/// (`plans/genre-metro-map.md` Phase 2's label-collision-compaction
/// carry-forward).
struct GenreMapForceLayoutTests {

  /// The Phase-1 gate's "labels-don't-collide PARTIAL" carry-forward.
  /// Post-pipeline labels must not overlap on a fixture where the
  /// community-gravity equilibrium WOULD leave overlapping pills if the
  /// post-settle compaction pass were absent.
  ///
  /// Fixture: a tight ring of same-community nodes whose label
  /// rectangles are wider than the spring-equilibrium pair distance.
  /// Without the compaction pass, community gravity pulls them onto
  /// each other; with it, they slide apart along the short overlap
  /// axis until none overlap.
  @Test
  func `post-pipeline labels do not overlap on a dense same-community ring`() {
    let nodeCount = 8
    var inputs = [GenreMapForceLayout.InputNode]()
    for index in 0 ..< nodeCount {
      inputs.append(GenreMapForceLayout.InputNode(
        id: "N\(index)",
        weight: 0.5,
        // Deliberately wide labels — wider than the spring's natural
        // pair distance. Without compaction these collide.
        labelSize: CGSize(width: 120, height: 28),
        communityID: 0,
      ))
    }
    var edges = [GenreMapEdge]()
    // Ring topology, all heavy edges in one community.
    for index in 0 ..< nodeCount {
      let a = "N\(index)"
      let b = "N\((index + 1) % nodeCount)"
      edges.append(GenreMapEdge(
        genreA: min(a, b),
        genreB: max(a, b),
        totalWeight: 1.0,
      ))
    }
    let output = GenreMapForceLayout.layout(
      nodes: inputs,
      edges: edges,
    )
    // Pairwise no-AABB-overlap check (zero padding allowance — labels
    // can touch but not overlap).
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

  /// The compaction pass must not move labels that are already well-
  /// separated (e.g. a long path graph at natural spring lengths). Pins
  /// the "compaction is bounded, does only the work it needs to do"
  /// guarantee.
  @Test
  func `compaction is a no-op when labels are already separated`() throws {
    let inputs: [GenreMapForceLayout.InputNode] = (0 ..< 4).map { index in
      GenreMapForceLayout.InputNode(
        id: "P\(index)",
        weight: 0.3,
        labelSize: CGSize(width: 36, height: 22),
        communityID: index, // each node its own community ⇒ no gravity collapse
      )
    }
    let edges = (0 ..< 3).map { index in
      GenreMapEdge(
        genreA: "P\(index)",
        genreB: "P\(index + 1)",
        totalWeight: 1.0,
      )
    }
    var configuration = GenreMapForceLayout.Configuration()
    configuration.compactionIterations = 0
    let withoutCompaction = GenreMapForceLayout.layout(
      nodes: inputs,
      edges: edges,
      configuration: configuration,
    )
    let withCompaction = GenreMapForceLayout.layout(
      nodes: inputs,
      edges: edges,
    )
    // Identical or near-identical positions ⇒ compaction did nothing.
    for input in inputs {
      let lhs = try #require(withoutCompaction.positions[input.id])
      let rhs = try #require(withCompaction.positions[input.id])
      #expect(abs(lhs.x - rhs.x) < 1.0e-6)
      #expect(abs(lhs.y - rhs.y) < 1.0e-6)
    }
  }
}
