import Testing
@testable import DJRoomba

/// Pure-pipeline tests for the **layout graph** construction
/// (`plans/genre-metro-map.md` Phase 1, step 4) — the sparse subset of
/// candidate edges the physics actually sees.
struct GenreMapLayoutGraphTests {

  @Test
  func `mutual k n n result is symmetric and deterministic`() {
    // Star + a few cross-links: enough weight asymmetry that a naive
    // top-k per node would yield an asymmetric result without the
    // mutual filter.
    let candidates: [GenreMapLayoutGraph.Candidate] = [
      .init(a: "A", b: "B", weight: 0.9),
      .init(a: "A", b: "C", weight: 0.85),
      .init(a: "A", b: "D", weight: 0.5),
      .init(a: "B", b: "C", weight: 0.4),
      .init(a: "B", b: "D", weight: 0.3),
      .init(a: "C", b: "D", weight: 0.2),
    ]
    let nodes: Set = ["A", "B", "C", "D"]
    let first = GenreMapLayoutGraph.build(
      candidates: candidates,
      nodes: nodes,
      librarySize: 100,
    )
    let second = GenreMapLayoutGraph.build(
      candidates: candidates,
      nodes: nodes,
      librarySize: 100,
    )
    #expect(first == second, "deterministic across runs")

    // Each kept edge has both endpoints present.
    for edge in first {
      #expect(nodes.contains(edge.a))
      #expect(nodes.contains(edge.b))
      #expect(edge.a < edge.b, "canonical half")
    }
  }

  @Test
  func `m s t backbone keeps the layout graph connected`() {
    // Two disconnected clusters with a single bridge — the mutual-kNN
    // filter might drop the bridge if a cluster has many internal
    // strong edges; the MST guarantee adds it back.
    let candidates: [GenreMapLayoutGraph.Candidate] = [
      // Cluster 1: A-B-C all strong.
      .init(a: "A", b: "B", weight: 0.95),
      .init(a: "A", b: "C", weight: 0.93),
      .init(a: "B", b: "C", weight: 0.92),
      // Cluster 2: D-E-F all strong.
      .init(a: "D", b: "E", weight: 0.94),
      .init(a: "D", b: "F", weight: 0.91),
      .init(a: "E", b: "F", weight: 0.90),
      // Single weak bridge.
      .init(a: "C", b: "D", weight: 0.20),
    ]
    let nodes: Set = ["A", "B", "C", "D", "E", "F"]
    let kept = GenreMapLayoutGraph.build(
      candidates: candidates,
      nodes: nodes,
      librarySize: 30,
    )
    // The MST step must guarantee one connected component.
    var uf = UnionFind(elements: nodes)
    for edge in kept { _ = uf.union(edge.a, edge.b) }
    #expect(uf.componentCount() == 1, "MST keeps the graph connected")
  }

  @Test
  func `k scales with library size`() {
    #expect(GenreMapLayoutGraph.neighbourK(for: 20) == 4)
    #expect(GenreMapLayoutGraph.neighbourK(for: 120) == 6)
    #expect(GenreMapLayoutGraph.neighbourK(for: 800) == 8)
  }

  @Test
  func `maximum spanning tree picks strongest first deterministically`() {
    let candidates: [GenreMapLayoutGraph.Candidate] = [
      .init(a: "A", b: "B", weight: 0.5),
      .init(a: "B", b: "C", weight: 0.7),
      .init(a: "A", b: "C", weight: 0.3),
    ]
    let mst = GenreMapLayoutGraph.maximumSpanningTree(
      candidates: candidates,
      nodes: ["A", "B", "C"],
    )
    #expect(mst.count == 2, "n−1 edges for a 3-node tree")
    let mstWeights = mst.map(\.weight).sorted()
    // Strongest two: 0.7 + 0.5 = 1.2.
    #expect(abs(mstWeights.reduce(0, +) - 1.2) < 1e-9)
  }

  /// Phase-2-gate substrate widening: every community pair that has at
  /// least one inter-community candidate (above the support floor)
  /// should contribute its heaviest crossing to the layout graph.
  /// Without this, mutual-kNN ∪ MST keeps at most ONE edge per
  /// community pair (the MST one), and transferness reads near-zero
  /// cross-community signal even on genuine bridge nodes.
  @Test
  func `inter community bridges admits the heaviest edge per community pair`() {
    // Two communities: 1 = {A, B}, 2 = {C, D}. Three crossings between
    // them: A-C (0.30), A-D (0.50), B-C (0.20). Existing layout edges
    // (simulating mutual-kNN ∪ MST) hold only A-C as the bridge.
    let candidates: [GenreMapLayoutGraph.Candidate] = [
      .init(a: "A", b: "B", weight: 0.95),
      .init(a: "C", b: "D", weight: 0.93),
      .init(a: "A", b: "C", weight: 0.30),
      .init(a: "A", b: "D", weight: 0.50),
      .init(a: "B", b: "C", weight: 0.20),
    ]
    let communities = ["A": 1, "B": 1, "C": 2, "D": 2]
    let existing: [GenreMapLayoutGraph.Candidate] = [
      .init(a: "A", b: "B", weight: 0.95),
      .init(a: "C", b: "D", weight: 0.93),
      .init(a: "A", b: "C", weight: 0.30),
    ]
    let bridges = GenreMapLayoutGraph.interCommunityBridges(
      candidates: candidates,
      communityByGenre: communities,
      existing: existing,
    )
    // One community pair (1,2) ⇒ at most one bridge. A-C is already
    // present; the heaviest crossing (A-D, 0.50) wins and is admitted.
    #expect(bridges.count == 1)
    #expect(bridges.first?.a == "A")
    #expect(bridges.first?.b == "D")
  }

  /// When mutual-kNN ∪ MST already admits the heaviest crossing for
  /// a community pair, no bridge is added — the function is strictly
  /// additive on top of the existing layout edges.
  @Test
  func `inter community bridges skips pairs already in the layout graph`() {
    let candidates: [GenreMapLayoutGraph.Candidate] = [
      .init(a: "A", b: "B", weight: 0.9),
      .init(a: "C", b: "D", weight: 0.9),
      .init(a: "A", b: "C", weight: 0.5),
    ]
    let communities = ["A": 1, "B": 1, "C": 2, "D": 2]
    let existing: [GenreMapLayoutGraph.Candidate] = [
      .init(a: "A", b: "B", weight: 0.9),
      .init(a: "C", b: "D", weight: 0.9),
      .init(a: "A", b: "C", weight: 0.5),
    ]
    let bridges = GenreMapLayoutGraph.interCommunityBridges(
      candidates: candidates,
      communityByGenre: communities,
      existing: existing,
    )
    #expect(bridges.isEmpty, "heaviest crossing already in existing ⇒ no bridge")
  }

  /// Three communities ⇒ up to three community pairs ⇒ up to three
  /// bridges, regardless of per-node top-N filtering (this is the
  /// Phase-2-gate guarantee the brief asks for).
  @Test
  func `inter community bridges admits one bridge per community pair when none exists`() {
    let candidates: [GenreMapLayoutGraph.Candidate] = [
      // Intra: each community has one internal edge so partitions are stable.
      .init(a: "A", b: "B", weight: 0.95),
      .init(a: "C", b: "D", weight: 0.94),
      .init(a: "E", b: "F", weight: 0.93),
      // Crossings, two per pair so we can pick the heaviest.
      .init(a: "A", b: "C", weight: 0.40),
      .init(a: "B", b: "D", weight: 0.50),
      .init(a: "A", b: "E", weight: 0.30),
      .init(a: "B", b: "F", weight: 0.35),
      .init(a: "C", b: "E", weight: 0.20),
      .init(a: "D", b: "F", weight: 0.25),
    ]
    let communities = ["A": 1, "B": 1, "C": 2, "D": 2, "E": 3, "F": 3]
    // Existing layout graph has only intra-community edges — every
    // community pair starts out unconnected.
    let existing: [GenreMapLayoutGraph.Candidate] = [
      .init(a: "A", b: "B", weight: 0.95),
      .init(a: "C", b: "D", weight: 0.94),
      .init(a: "E", b: "F", weight: 0.93),
    ]
    let bridges = GenreMapLayoutGraph.interCommunityBridges(
      candidates: candidates,
      communityByGenre: communities,
      existing: existing,
    )
    #expect(bridges.count == 3, "three community pairs ⇒ three bridges")
    let bridgeKeys = Set(bridges.map { "\($0.a)|\($0.b)" })
    #expect(bridgeKeys.contains("B|D"), "heaviest 1↔2 crossing")
    #expect(bridgeKeys.contains("B|F"), "heaviest 1↔3 crossing")
    #expect(bridgeKeys.contains("D|F"), "heaviest 2↔3 crossing")
  }

  @Test
  func `low degree nodes keep their edges via the per node floor`() {
    // 5 strong + 1 weak link from a degree-1 node. With kNN-4 and an
    // 8-node graph, the weak link is still the degree-1 node's only
    // edge → must survive.
    var candidates = [GenreMapLayoutGraph.Candidate]()
    let hub = "Hub"
    let strongPeers = ["A", "B", "C", "D", "E"]
    for (index, peer) in strongPeers.enumerated() {
      candidates.append(
        .init(a: hub, b: peer, weight: 0.9 - 0.05 * Double(index))
      )
    }
    // Weak peripheral link.
    candidates.append(.init(a: "Edge", b: hub, weight: 0.1))
    let nodes: Set<String> = Set(strongPeers + [hub, "Edge"])

    let kept = GenreMapLayoutGraph.build(
      candidates: candidates,
      nodes: nodes,
      librarySize: 20,
    )
    let hasEdgeLink = kept.contains {
      ($0.a == "Edge" && $0.b == hub) || ($0.b == "Edge" && $0.a == hub)
    }
    #expect(hasEdgeLink, "MST guarantees Edge stays connected to Hub")
  }
}
