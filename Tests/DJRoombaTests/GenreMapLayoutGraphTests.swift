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
