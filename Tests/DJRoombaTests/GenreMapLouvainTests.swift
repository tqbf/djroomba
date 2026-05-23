import Testing
@testable import DJRoomba

/// In-tree Louvain (`plans/genre-metro-map.md` Phase 1, step 5). Pins:
/// the three-community fixture (the textbook test), determinism, and
/// degenerate-input safety.
struct GenreMapLouvainTests {

  @Test
  func `three clearly separated communities are recovered`() {
    // Three tight triangles connected by single weak bridges. Modularity
    // -optimising any Louvain pass at γ=1.0 finds these three triangles.
    let edges: [GenreMapLouvain.Edge] = [
      // Triangle 1.
      .init(a: "A1", b: "A2", weight: 1.0),
      .init(a: "A1", b: "A3", weight: 1.0),
      .init(a: "A2", b: "A3", weight: 1.0),
      // Triangle 2.
      .init(a: "B1", b: "B2", weight: 1.0),
      .init(a: "B1", b: "B3", weight: 1.0),
      .init(a: "B2", b: "B3", weight: 1.0),
      // Triangle 3.
      .init(a: "C1", b: "C2", weight: 1.0),
      .init(a: "C1", b: "C3", weight: 1.0),
      .init(a: "C2", b: "C3", weight: 1.0),
      // Weak inter-triangle bridges.
      .init(a: "A1", b: "B1", weight: 0.05),
      .init(a: "B1", b: "C1", weight: 0.05),
    ]
    let nodes = ["A1", "A2", "A3", "B1", "B2", "B3", "C1", "C2", "C3"]
    let partition = GenreMapLouvain.detect(
      nodes: nodes,
      edges: edges,
      gamma: 1.0,
    )
    // Each triangle's three members must share a community.
    for triangle in ["A", "B", "C"] {
      let ids = (1 ... 3).compactMap { partition["\(triangle)\($0)"] }
      #expect(ids.count == 3)
      #expect(Set(ids).count == 1, "triangle \(triangle) all in one community")
    }
    // The three triangles' communities differ.
    let a = partition["A1"]
    let b = partition["B1"]
    let c = partition["C1"]
    #expect(a != b)
    #expect(b != c)
    #expect(a != c)
  }

  @Test
  func `same input produces the same partition twice`() {
    let edges: [GenreMapLouvain.Edge] = [
      .init(a: "X", b: "Y", weight: 1.0),
      .init(a: "Y", b: "Z", weight: 0.6),
      .init(a: "X", b: "Z", weight: 0.7),
      .init(a: "P", b: "Q", weight: 1.0),
      .init(a: "P", b: "R", weight: 0.9),
      .init(a: "Q", b: "R", weight: 0.5),
    ]
    let nodes = ["X", "Y", "Z", "P", "Q", "R"]
    let first = GenreMapLouvain.detect(nodes: nodes, edges: edges, gamma: 1.0)
    let second = GenreMapLouvain.detect(nodes: nodes, edges: edges, gamma: 1.0)
    #expect(first == second)
  }

  @Test
  func `empty graph returns empty partition`() {
    let partition = GenreMapLouvain.detect(nodes: [], edges: [], gamma: 1.0)
    #expect(partition.isEmpty)
  }

  @Test
  func `no edges produces a singleton community per node`() {
    let nodes = ["a", "b", "c"]
    let partition = GenreMapLouvain.detect(
      nodes: nodes,
      edges: [],
      gamma: 1.0,
    )
    #expect(Set(partition.values).count == nodes.count)
  }

  /// Phase 2's first carry-forward task: the medium-resolution γ retune
  /// from 1.0 → 0.85. On the same fixture the lower-γ partition must
  /// have ≤ communities than the higher-γ partition (the modularity-vs-
  /// resolution sweep is monotone non-increasing in γ over a connected
  /// component). This pins the *direction* of the retune, not an exact
  /// number — the real library is a perceptual check, not a unit-test
  /// invariant.
  @Test
  func `gamma 0_85 yields no more communities than gamma 1_0 on the same fixture`() {
    // Five triangles weakly bridged in a chain — at γ=1.0 they tend to
    // sit as ~5 communities; at γ=0.85 the modularity preference for
    // larger communities folds neighbouring triangles together.
    var edges = [GenreMapLouvain.Edge]()
    var nodes = [String]()
    for cluster in 0 ..< 5 {
      let names = (0 ..< 3).map { "C\(cluster)_N\($0)" }
      nodes.append(contentsOf: names)
      edges.append(.init(a: names[0], b: names[1], weight: 1.0))
      edges.append(.init(a: names[0], b: names[2], weight: 1.0))
      edges.append(.init(a: names[1], b: names[2], weight: 1.0))
    }
    // Weak inter-cluster bridges between successive clusters.
    for cluster in 0 ..< 4 {
      edges.append(.init(
        a: "C\(cluster)_N0",
        b: "C\(cluster + 1)_N0",
        weight: 0.20,
      ))
    }
    let unity = GenreMapLouvain.detect(nodes: nodes, edges: edges, gamma: 1.0)
    let eightyFive = GenreMapLouvain.detect(nodes: nodes, edges: edges, gamma: 0.85)
    let unityCount = Set(unity.values).count
    let eightyFiveCount = Set(eightyFive.values).count
    #expect(
      eightyFiveCount <= unityCount,
      "γ=0.85 yielded \(eightyFiveCount) communities; γ=1.0 yielded \(unityCount)",
    )
  }

  @Test
  func `coarser gamma produces fewer or equal communities`() {
    // Three triangles with stronger bridges — at γ=1.0 they should split;
    // at γ=0.3 the algorithm should merge them.
    let edges: [GenreMapLouvain.Edge] = [
      .init(a: "A1", b: "A2", weight: 1.0),
      .init(a: "A1", b: "A3", weight: 1.0),
      .init(a: "A2", b: "A3", weight: 1.0),
      .init(a: "B1", b: "B2", weight: 1.0),
      .init(a: "B1", b: "B3", weight: 1.0),
      .init(a: "B2", b: "B3", weight: 1.0),
      .init(a: "A1", b: "B1", weight: 0.6),
    ]
    let nodes = ["A1", "A2", "A3", "B1", "B2", "B3"]
    let medium = GenreMapLouvain.detect(nodes: nodes, edges: edges, gamma: 1.0)
    let coarse = GenreMapLouvain.detect(nodes: nodes, edges: edges, gamma: 0.2)
    let mediumCount = Set(medium.values).count
    let coarseCount = Set(coarse.values).count
    #expect(coarseCount <= mediumCount)
  }
}
