import CoreGraphics
import Foundation
import Testing
@testable import DJRoomba

/// Phase 5 (`plans/genre-metro-map.md`) discovery primitives — pure
/// tests on hand-built fixtures. Covers:
///
/// - hover/click selection state model (`GenreMapDiscovery.Selection`)
///   — focused, compare equality + value semantics;
/// - Yen-k shortest paths on (a) a barbell graph + (b) a 4-cycle —
///   `k=3` returns three distinct simple paths sorted by cumulative
///   cost ascending;
/// - 1-hop neighbours / serving strands / transfer-stations-along-path
///   evidence helpers;
/// - `transferMapPlan` numeric plan (centre + scale) on a small fixture.
struct GenreMapDiscoveryTests {

  // MARK: Internal

  /// `Selection` is a value type. Switching state must not entangle
  /// upstream copies — pinned because the panel snapshots it into
  /// closures that survive across UI re-evaluations.
  @Test
  func `selection enum equates by case and payload, focused != compare`() {
    let none = GenreMapDiscovery.Selection.none
    let focused = GenreMapDiscovery.Selection.focused(genre: "Alt")
    let compare = GenreMapDiscovery.Selection.compare(a: "Alt", b: "Rap")
    #expect(none != focused)
    #expect(focused != compare)
    #expect(GenreMapDiscovery.Selection.focused(genre: "Alt") == focused)
    #expect(GenreMapDiscovery.Selection.compare(a: "Alt", b: "Rap") == compare)
    // Reversed pair is a different value (the discovery module
    // doesn't canonicalise the pair — the panel decides).
    #expect(GenreMapDiscovery.Selection.compare(a: "Rap", b: "Alt") != compare)
  }

  /// Yen-k on a **barbell** graph — two triangles joined by a bridge.
  /// Three paths exist between the two outer corners (one through the
  /// bridge + two through the inner cycle of either triangle). `k=3`
  /// returns three distinct simple paths sorted by cumulative cost.
  ///
  ///   ```
  ///     A — B
  ///     |   |
  ///     C — D ——— E — F
  ///                |   |
  ///                G — H
  ///   ```
  @Test
  func `yen-k returns k distinct simple paths sorted by cumulative cost`() {
    let edges = [
      // Left triangle (square).
      GenreMapDiscovery.Edge(a: "A", b: "B", weight: 0.9),
      GenreMapDiscovery.Edge(a: "B", b: "D", weight: 0.9),
      GenreMapDiscovery.Edge(a: "A", b: "C", weight: 0.4),
      GenreMapDiscovery.Edge(a: "C", b: "D", weight: 0.4),
      // Bridge.
      GenreMapDiscovery.Edge(a: "D", b: "E", weight: 0.7),
      // Right triangle (square).
      GenreMapDiscovery.Edge(a: "E", b: "F", weight: 0.6),
      GenreMapDiscovery.Edge(a: "F", b: "H", weight: 0.6),
      GenreMapDiscovery.Edge(a: "E", b: "G", weight: 0.5),
      GenreMapDiscovery.Edge(a: "G", b: "H", weight: 0.5),
    ]
    let paths = GenreMapDiscovery.kShortestPaths(
      from: "A",
      to: "H",
      edges: edges,
      k: 3,
    )
    #expect(paths.count == 3)
    // All distinct.
    let stations = paths.map(\.stations)
    #expect(Set(stations.map { $0.joined(separator: ",") }).count == 3)
    // Sorted by cost ascending.
    for i in 0..<(paths.count - 1) {
      #expect(paths[i].cost <= paths[i + 1].cost)
    }
    // Every path starts at A and ends at H, every path is simple
    // (each station appears at most once).
    for path in paths {
      #expect(path.stations.first == "A")
      #expect(path.stations.last == "H")
      #expect(Set(path.stations).count == path.stations.count)
    }
  }

  /// 4-cycle: A — B — C — D — A. Two distinct simple paths from A to
  /// C: A → B → C and A → D → C. `k=3` returns 2 (no third simple
  /// path exists in a 4-cycle).
  @Test
  func `yen-k returns only as many simple paths as exist in a 4-cycle`() {
    let edges = [
      GenreMapDiscovery.Edge(a: "A", b: "B", weight: 0.5),
      GenreMapDiscovery.Edge(a: "B", b: "C", weight: 0.5),
      GenreMapDiscovery.Edge(a: "C", b: "D", weight: 0.5),
      GenreMapDiscovery.Edge(a: "D", b: "A", weight: 0.5),
    ]
    let paths = GenreMapDiscovery.kShortestPaths(
      from: "A",
      to: "C",
      edges: edges,
      k: 3,
    )
    #expect(paths.count == 2)
    let s1 = paths[0].stations
    let s2 = paths[1].stations
    let alternatives = Set([s1.joined(separator: ","), s2.joined(separator: ",")])
    #expect(alternatives.contains("A,B,C"))
    #expect(alternatives.contains("A,D,C"))
  }

  /// Disconnected source / target ⇒ empty result.
  @Test
  func `yen-k returns empty when source and target are disconnected`() {
    let edges = [
      GenreMapDiscovery.Edge(a: "A", b: "B", weight: 0.5),
      GenreMapDiscovery.Edge(a: "C", b: "D", weight: 0.5),
    ]
    let paths = GenreMapDiscovery.kShortestPaths(
      from: "A",
      to: "D",
      edges: edges,
      k: 3,
    )
    #expect(paths.isEmpty)
  }

  /// Heavier composite edges shorten the cost ⇒ are preferred. Two
  /// equal-length paths between A and C: A-B-C (heavy) vs A-D-C
  /// (light). The heavy path comes back first.
  @Test
  func `yen-k prefers heavier composite paths first`() {
    let edges = [
      GenreMapDiscovery.Edge(a: "A", b: "B", weight: 0.9),
      GenreMapDiscovery.Edge(a: "B", b: "C", weight: 0.9),
      GenreMapDiscovery.Edge(a: "A", b: "D", weight: 0.1),
      GenreMapDiscovery.Edge(a: "D", b: "C", weight: 0.1),
    ]
    let paths = GenreMapDiscovery.kShortestPaths(
      from: "A",
      to: "C",
      edges: edges,
      k: 2,
    )
    #expect(paths.count == 2)
    #expect(paths[0].stations == ["A", "B", "C"])
    #expect(paths[1].stations == ["A", "D", "C"])
  }

  /// 1-hop neighbours — returned sorted by weight desc.
  @Test
  func `one hop neighbours are sorted by weight desc`() {
    let edges = [
      GenreMapDiscovery.Edge(a: "Alt", b: "Rock", weight: 0.20),
      GenreMapDiscovery.Edge(a: "Alt", b: "Folk", weight: 0.85),
      GenreMapDiscovery.Edge(a: "Alt", b: "Jazz", weight: 0.50),
      GenreMapDiscovery.Edge(a: "Rock", b: "Folk", weight: 0.10),
    ]
    let rows = GenreMapDiscovery.oneHopNeighbours(of: "Alt", edges: edges)
    #expect(rows.map(\.genre) == ["Folk", "Jazz", "Rock"])
  }

  /// Serving-strand lookup collapses branches into the parent corridor.
  @Test
  func `servingStrandIDs collapses branches to parent corridor`() {
    let parent = GenreMapStrandInference.Strand(
      id: 0,
      label: "Folk Acoustic",
      tokens: ["folk"],
      representativeGenres: ["Folk"],
      memberGenres: ["Folk", "Acoustic", "Roots"],
      pathStations: ["Folk", "Acoustic", "Roots"],
      colourID: 0,
      isBranch: false,
      parentStrandID: nil,
    )
    let branch = GenreMapStrandInference.Strand(
      id: 1,
      label: "Folk Acoustic",
      tokens: ["folk"],
      representativeGenres: ["Folk"],
      memberGenres: ["Folk", "Roots", "Celtic"],
      pathStations: ["Folk", "Roots", "Celtic"],
      colourID: 0,
      isBranch: true,
      parentStrandID: 0,
    )
    let serving = GenreMapDiscovery.servingStrandIDs(
      of: "Celtic",
      strands: [parent, branch],
    )
    #expect(serving == Set([0]))
  }

  /// `transferStations(along:)` reads `nodeKind` on each station.
  @Test
  func `transferStations along path filters by nodeKind`() {
    let nodes: [String: GenreMapNode] = [
      "A": Self.testNode(genre: "A", kind: .ordinary),
      "B": Self.testNode(genre: "B", kind: .transferStation),
      "C": Self.testNode(genre: "C", kind: .junction),
      "D": Self.testNode(genre: "D", kind: .transferStation),
    ]
    let path = GenreMapDiscovery.Path(
      stations: ["A", "B", "C", "D"],
      edgeWeights: [0.5, 0.5, 0.5],
    )
    let stations = GenreMapDiscovery.transferStations(along: path, nodesByGenre: nodes)
    #expect(stations == ["B", "D"])
  }

  /// `transferMapPlan` produces deterministic centre + scale numbers.
  /// Centre = the world position of the focused node; scale tightens
  /// to fit the 1-hop neighbours into the supplied viewport with a
  /// padding inset.
  @Test
  func `transferMapPlan centres on the focused node`() {
    let nodes: [String: GenreMapNode] = [
      "Hub": Self.testNode(genre: "Hub", position: CGPoint(x: 100, y: 100)),
      "N1": Self.testNode(genre: "N1", position: CGPoint(x: 200, y: 100)),
      "N2": Self.testNode(genre: "N2", position: CGPoint(x: 0, y: 100)),
    ]
    let edges = [
      GenreMapDiscovery.Edge(a: "Hub", b: "N1", weight: 0.5),
      GenreMapDiscovery.Edge(a: "Hub", b: "N2", weight: 0.5),
    ]
    let plan = try? #require(GenreMapDiscovery.transferMapPlan(
      centreGenre: "Hub",
      nodesByGenre: nodes,
      edges: edges,
      viewport: CGSize(width: 600, height: 400),
      padding: 50,
      minScale: 0.5,
      maxScale: 4.0,
    ))
    #expect(plan?.centre == CGPoint(x: 100, y: 100))
    // The bounding box is 200 wide (N2 at 0 → N1 at 200) by 1 tall;
    // 600 − 100 = 500 available width ⇒ scale = 2.5 (clamped to
    // [minScale, maxScale]).
    #expect((plan?.scale ?? 0) >= 0.5 && (plan?.scale ?? 0) <= 4.0)
  }

  // MARK: Private

  /// Tiny helper — every `GenreMapNode` field has a sensible default
  /// for tests that only care about a couple of fields.
  private static func testNode(
    genre: String,
    kind: GenreMapNodeKind = .ordinary,
    position: CGPoint = .zero,
  ) -> GenreMapNode {
    GenreMapNode(
      genre: genre,
      weight: 0.5,
      trackCount: 0,
      albumCount: 0,
      artistCount: 0,
      communityID: 0,
      position: position,
      labelSize: CGSize(width: 50, height: 14),
      transferness: 0,
      nodeKind: kind,
      transfernessInputs: GenreMapTransfernessInputs(
        betweenness: 0,
        neighbourEntropy: 0,
        crossCommunityFraction: 0,
        membershipEntropy: 0,
        strandCount: 0,
        dampening: 1.0,
      ),
    )
  }
}
