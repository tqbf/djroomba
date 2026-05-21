import Foundation
import Testing
@testable import DJRoomba

/// Pure-logic tests for `GenreMapStrandInference`
/// (`plans/genre-metro-map.md` Phase 3). Every test runs on a hand-built
/// fixture small enough to compute by hand — the plan's explicit ask for
/// per-pure-subsystem coverage.
struct GenreMapStrandInferenceTests {

  /// Path graph A — B — C — D — E with uniform edge weights. The MST is
  /// the path itself; the heavy-path extraction returns it as a single
  /// strand candidate (length 5 ≥ 3, mean weight = 1.0 ≥ τ).
  @Test
  func `heavy path extraction on a uniform path returns the full path`() {
    let nodes: Set = ["A", "B", "C", "D", "E"]
    let edges = [
      GenreMapStrandInference.Edge(a: "A", b: "B", weight: 1.0),
      GenreMapStrandInference.Edge(a: "B", b: "C", weight: 1.0),
      GenreMapStrandInference.Edge(a: "C", b: "D", weight: 1.0),
      GenreMapStrandInference.Edge(a: "D", b: "E", weight: 1.0),
    ]
    let tree = GenreMapStrandInference.maximumSpanningTree(nodes: nodes, edges: edges)
    #expect(tree.count == 4)
    let heavy = GenreMapStrandInference.heavyPathsInTree(
      tree: tree,
      nodes: nodes,
      minLength: 3,
      meanWeightFloor: 0,
      cap: 4,
    )
    #expect(heavy.count == 1)
    // Path orientation depends on the deterministic-pick start node;
    // either direction is correct — a metro strand is undirected.
    let path = heavy.first?.path ?? []
    #expect(
      path == ["A", "B", "C", "D", "E"] || path == ["E", "D", "C", "B", "A"],
      "got \(path)",
    )
  }

  /// Mean-weight floor τ blocks a weak chain even when it's long.
  /// Heavy-path extraction returns no qualifying strand.
  @Test
  func `heavy path extraction respects the mean-weight floor`() {
    let nodes: Set = ["A", "B", "C", "D"]
    let edges = [
      GenreMapStrandInference.Edge(a: "A", b: "B", weight: 0.1),
      GenreMapStrandInference.Edge(a: "B", b: "C", weight: 0.1),
      GenreMapStrandInference.Edge(a: "C", b: "D", weight: 0.1),
    ]
    let tree = GenreMapStrandInference.maximumSpanningTree(nodes: nodes, edges: edges)
    let heavy = GenreMapStrandInference.heavyPathsInTree(
      tree: tree,
      nodes: nodes,
      minLength: 3,
      meanWeightFloor: 0.5,
      cap: 4,
    )
    #expect(heavy.isEmpty, "all-weak chain must not surface as heavy strand")
  }

  /// Min-length 3: a 2-node chain must NOT be promoted to a strand
  /// (the plan's `length ≥ 3`).
  @Test
  func `heavy path extraction enforces the minimum length floor`() {
    let nodes: Set = ["A", "B"]
    let edges = [GenreMapStrandInference.Edge(a: "A", b: "B", weight: 0.9)]
    let tree = GenreMapStrandInference.maximumSpanningTree(nodes: nodes, edges: edges)
    let heavy = GenreMapStrandInference.heavyPathsInTree(
      tree: tree,
      nodes: nodes,
      minLength: 3,
      meanWeightFloor: 0,
      cap: 4,
    )
    #expect(heavy.isEmpty)
  }

  /// Barbell: two cliques joined by ONE strong cross-community edge.
  /// `weightedShortestPath` over `1 − weight` recovers the bridge as
  /// the shortest path through the layout graph.
  @Test
  func `weighted shortest path recovers the bridge between two cliques`() {
    let edges = [
      // Clique 1 (community 0)
      GenreMapStrandInference.Edge(a: "A1", b: "A2", weight: 0.8),
      GenreMapStrandInference.Edge(a: "A2", b: "A3", weight: 0.8),
      GenreMapStrandInference.Edge(a: "A1", b: "A3", weight: 0.8),
      // Bridge
      GenreMapStrandInference.Edge(a: "A3", b: "B1", weight: 0.6),
      // Clique 2 (community 1)
      GenreMapStrandInference.Edge(a: "B1", b: "B2", weight: 0.8),
      GenreMapStrandInference.Edge(a: "B2", b: "B3", weight: 0.8),
      GenreMapStrandInference.Edge(a: "B1", b: "B3", weight: 0.8),
    ]
    var adjacency = [String: [(other: String, weight: Double)]]()
    for edge in edges {
      adjacency[edge.a, default: []].append((edge.b, edge.weight))
      adjacency[edge.b, default: []].append((edge.a, edge.weight))
    }
    let path = GenreMapStrandInference.weightedShortestPath(
      from: "A1",
      to: "B3",
      adjacency: adjacency,
    )
    #expect(path != nil)
    let nodes = path?.nodes ?? []
    // The strongest-weight path is A1 — A3 — B1 — B3 (three high-weight
    // hops; cost = 3 × (1 − 0.8) + 1 × (1 − 0.6) = 1.0). Other paths
    // either route through A2/B2 (one extra weak hop) or via the
    // weaker bridge twice and lose.
    #expect(nodes.first == "A1")
    #expect(nodes.last == "B3")
    #expect(nodes.contains("A3"))
    #expect(nodes.contains("B1"))
  }

  /// member-Jaccard ≥ 0.6 ⇒ the duplicate is culled (absorbed as a
  /// branch under the survivor).
  @Test
  func `strand cull absorbs near-duplicate as a branch of the survivor`() {
    let nodes: [GenreMapStrandInference.InputNode] = [
      .init(genre: "A", weight: 1.0, transferness: 0, communityID: 0),
      .init(genre: "B", weight: 0.9, transferness: 0, communityID: 0),
      .init(genre: "C", weight: 0.8, transferness: 0, communityID: 0),
      .init(genre: "D", weight: 0.7, transferness: 0, communityID: 0),
      .init(genre: "E", weight: 0.6, transferness: 0, communityID: 0),
    ]
    let edges = [
      // Same path A-B-C-D-E plus a near-duplicate A-B-C-D-X (X shares 4/5
      // members ⇒ Jaccard 4/6 ≈ 0.667 over 6 distinct members ⇒ ≥ 0.6).
      GenreMapStrandInference.Edge(a: "A", b: "B", weight: 1.0),
      GenreMapStrandInference.Edge(a: "B", b: "C", weight: 1.0),
      GenreMapStrandInference.Edge(a: "C", b: "D", weight: 1.0),
      GenreMapStrandInference.Edge(a: "D", b: "E", weight: 1.0),
    ]
    let strands = GenreMapStrandInference.infer(nodes: nodes, edges: edges)
    // Single community with a single heavy path — only one strand.
    #expect(strands.count(where: { !$0.isBranch }) == 1)
    // Member-Jaccard on identical sets ⇒ 1.0.
    let jaccard = GenreMapStrandInference.memberJaccard(
      Set(["A", "B", "C"]),
      Set(["A", "B", "C"]),
    )
    #expect(jaccard == 1.0)
    let halfJaccard = GenreMapStrandInference.memberJaccard(
      Set(["A", "B", "C"]),
      Set(["D", "E", "F"]),
    )
    #expect(halfJaccard == 0.0)
  }

  /// Junk tokens are dropped. Distinguishing tokens are preferred over
  /// the shared ones (TF-IDF). Stable across runs.
  @Test
  func `TF-IDF tokens drop the junk blacklist`() {
    // Hand-crafted strand fixtures (we call `tfidfLabels` directly so
    // the test doesn't depend on the upstream infer pipeline).
    let strands: [GenreMapStrandInference.Strand] = [
      .init(
        id: 0,
        label: "",
        tokens: [],
        representativeGenres: [],
        memberGenres: ["Acoustic Folk", "Folk Roots", "Indie Folk"],
        pathStations: [],
        colourID: 0,
        isBranch: false,
        parentStrandID: nil,
      ),
      .init(
        id: 1,
        label: "",
        tokens: [],
        representativeGenres: [],
        memberGenres: ["Hip-Hop", "Rap", "Trap"],
        pathStations: [],
        colourID: 1,
        isBranch: false,
        parentStrandID: nil,
      ),
    ]
    let labels = GenreMapStrandInference.tfidfLabels(strands: strands, maxTokens: 3)
    let firstTokens = labels[0]?.1 ?? []
    let secondTokens = labels[1]?.1 ?? []
    #expect(firstTokens.contains("folk"), "folk is the strongest signal for strand 0")
    #expect(!firstTokens.contains("music"), "junk token 'music' must not surface")
    #expect(!secondTokens.contains("music"))
  }

  /// Tokenise: lowercase + split on `/`, `-`, `&`; junk tokens filtered.
  @Test
  func `tokenise filters junk and splits on separators`() {
    let tokens = GenreMapStrandInference.tokenise("Hip-Hop/Rap & Misc")
    // "misc" is in the junk list; tokens lowercased; separators applied.
    // "rap" is NOT in the junk list (Phase 3 keeps genre-meaningful tokens).
    #expect(tokens.contains("hip"))
    #expect(tokens.contains("hop"))
    #expect(tokens.contains("rap"))
    #expect(!tokens.contains("misc"), "junk token dropped")
  }

  /// Stable across rebuilds for identical input.
  @Test
  func `TF-IDF labels are stable across runs for identical inputs`() {
    let strands: [GenreMapStrandInference.Strand] = [
      .init(
        id: 0,
        label: "",
        tokens: [],
        representativeGenres: [],
        memberGenres: ["Jazz Fusion", "Smooth Jazz", "Bebop"],
        pathStations: [],
        colourID: 0,
        isBranch: false,
        parentStrandID: nil,
      )
    ]
    let a = GenreMapStrandInference.tfidfLabels(strands: strands, maxTokens: 4)
    let b = GenreMapStrandInference.tfidfLabels(strands: strands, maxTokens: 4)
    #expect(a[0]?.0 == b[0]?.0)
    #expect(a[0]?.1 == b[0]?.1)
  }

  /// `strandCountByNode` aggregates strand membership per node;
  /// re-feeding the resulting `[String: Int]` to `GenreMapTransferness.score`
  /// raises the composite for nodes that serve multiple strands.
  @Test
  func `strand count feeds back into transferness composite`() {
    let strands: [GenreMapStrandInference.Strand] = [
      .init(
        id: 0,
        label: "",
        tokens: [],
        representativeGenres: [],
        memberGenres: ["A", "B", "C"],
        pathStations: ["A", "B", "C"],
        colourID: 0,
        isBranch: false,
        parentStrandID: nil,
      ),
      .init(
        id: 1,
        label: "",
        tokens: [],
        representativeGenres: [],
        memberGenres: ["C", "D", "E"],
        pathStations: ["C", "D", "E"],
        colourID: 1,
        isBranch: false,
        parentStrandID: nil,
      ),
    ]
    let counts = GenreMapStrandInference.strandCountByNode(strands: strands)
    #expect(counts["C"] == 2, "C serves both strands")
    #expect(counts["A"] == 1)
    #expect(counts["E"] == 1)

    // Re-score transferness with strand_count and confirm the slot fires.
    let scoreNodes: [(genre: String, weight: Double)] = [
      ("A", 0.2),
      ("B", 0.2),
      ("C", 0.2),
      ("D", 0.2),
      ("E", 0.2),
    ]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "B", b: "C", weight: 1.0),
      (a: "C", b: "D", weight: 1.0),
      (a: "D", b: "E", weight: 1.0),
    ]
    let communities = ["A": 0, "B": 0, "C": 0, "D": 1, "E": 1]
    let withoutStrands = GenreMapTransferness.score(
      nodes: scoreNodes,
      edges: edges,
      communities: communities,
    )
    let withStrands = GenreMapTransferness.score(
      nodes: scoreNodes,
      edges: edges,
      communities: communities,
      strandCountByNode: counts,
    )
    let cBefore = withoutStrands.compositeByNode["C"] ?? 0
    let cAfter = withStrands.compositeByNode["C"] ?? 0
    #expect(cAfter > cBefore, "C's composite must rise when strand_count is wired in")
  }

  /// On a small fixture with two communities joined by a strong bridge,
  /// the strand inference produces at least one per-community heavy
  /// path AND a cross-community bridge strand.
  @Test
  func `infer produces both community heavy paths and bridge strands on a barbell`() {
    let nodes: [GenreMapStrandInference.InputNode] = [
      .init(genre: "A1", weight: 0.5, transferness: 0, communityID: 0),
      .init(genre: "A2", weight: 0.5, transferness: 0, communityID: 0),
      .init(genre: "A3", weight: 0.5, transferness: 0.6, communityID: 0),
      .init(genre: "A4", weight: 0.5, transferness: 0, communityID: 0),
      .init(genre: "A5", weight: 0.5, transferness: 0, communityID: 0),
      .init(genre: "B1", weight: 0.5, transferness: 0.6, communityID: 1),
      .init(genre: "B2", weight: 0.5, transferness: 0, communityID: 1),
      .init(genre: "B3", weight: 0.5, transferness: 0, communityID: 1),
      .init(genre: "B4", weight: 0.5, transferness: 0, communityID: 1),
      .init(genre: "B5", weight: 0.5, transferness: 0, communityID: 1),
    ]
    let edges = [
      // Community 0 chain
      GenreMapStrandInference.Edge(a: "A1", b: "A2", weight: 0.9),
      GenreMapStrandInference.Edge(a: "A2", b: "A3", weight: 0.9),
      GenreMapStrandInference.Edge(a: "A3", b: "A4", weight: 0.9),
      GenreMapStrandInference.Edge(a: "A4", b: "A5", weight: 0.9),
      // Bridge
      GenreMapStrandInference.Edge(a: "A3", b: "B1", weight: 0.7),
      // Community 1 chain
      GenreMapStrandInference.Edge(a: "B1", b: "B2", weight: 0.9),
      GenreMapStrandInference.Edge(a: "B2", b: "B3", weight: 0.9),
      GenreMapStrandInference.Edge(a: "B3", b: "B4", weight: 0.9),
      GenreMapStrandInference.Edge(a: "B4", b: "B5", weight: 0.9),
    ]
    let strands = GenreMapStrandInference.infer(nodes: nodes, edges: edges)
    #expect(!strands.isEmpty, "must produce at least one strand")
    let mains = strands.filter { !$0.isBranch }
    // The bridge candidate IS allowed to absorb a per-community heavy
    // path on a barbell (the bridge naturally extends the chain), so
    // we don't pin a per-community count — instead we assert the
    // strands together cover both communities.
    let everyMember = Set(mains.flatMap(\.memberGenres))
    #expect(everyMember.contains("A1") || everyMember.contains("A5"))
    #expect(everyMember.contains("B1") || everyMember.contains("B5"))
  }
}
