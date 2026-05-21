import CoreGraphics
import Testing
@testable import DJRoomba

/// End-to-end pure-pipeline tests for `GenreMapBuilder`
/// (`plans/genre-metro-map.md` Phase 1).
struct GenreMapBuilderTests {

  @Test
  func `empty input yields an empty model`() {
    let model = GenreMapBuilder.build(
      nodes: [],
      evidence: [],
      measureLabel: { _, _, _ in CGSize(width: 60, height: 24) },
    )
    #expect(model.nodes.isEmpty)
    #expect(model.layoutEdges.isEmpty)
    #expect(model.communities.isEmpty)
  }

  @Test
  func `every input genre gets a position in the model`() {
    let nodes = (0 ..< 8).map { index in
      GenreNode(
        genre: "G\(index)",
        trackCount: 10,
        albumCount: 2,
        artistCount: 2,
        weight: 0.2 + 0.1 * Double(index),
      )
    }
    // A small ring of evidence so the layout is connected.
    var evidence = [GenreEdgeEvidence]()
    for i in 0 ..< 8 {
      let a = "G\(i)"
      let b = "G\((i + 1) % 8)"
      evidence.append(GenreEdgeEvidence(
        genreA: min(a, b),
        genreB: max(a, b),
        artistOverlapJaccard: 0.5,
        albumOverlapJaccard: 0.4,
        trackOverlapJaccard: 0.3,
        playlistCooccurWeight: 0.2,
        sharedArtistCount: 2,
        sharedAlbumCount: 1,
        sharedTrackCount: 1,
        totalWeight: 0.5,
      ))
    }
    let model = GenreMapBuilder.build(
      nodes: nodes,
      evidence: evidence,
      measureLabel: { text, _, _ in CGSize(width: CGFloat(text.count * 7), height: 22) },
    )
    #expect(model.nodes.count == 8)
    for node in model.nodes {
      #expect(node.position.x.isFinite)
      #expect(node.position.y.isFinite)
    }
    // Layout graph is connected (after MST).
    var uf = UnionFind(elements: Set(model.nodes.map(\.genre)))
    for edge in model.layoutEdges {
      _ = uf.union(edge.genreA, edge.genreB)
    }
    #expect(uf.componentCount() == 1)
  }

  @Test
  func `identical inputs produce identical model output`() {
    let nodes = (0 ..< 5).map { index in
      GenreNode(
        genre: "G\(index)",
        trackCount: 5,
        albumCount: 2,
        artistCount: 2,
        weight: Double(index) / 5.0,
      )
    }
    let evidence: [GenreEdgeEvidence] = [
      GenreEdgeEvidence(
        genreA: "G0",
        genreB: "G1",
        artistOverlapJaccard: 0.5,
        albumOverlapJaccard: 0.5,
        trackOverlapJaccard: 0.5,
        playlistCooccurWeight: 0.5,
        sharedArtistCount: 2,
        sharedAlbumCount: 2,
        sharedTrackCount: 2,
        totalWeight: 0.5,
      ),
      GenreEdgeEvidence(
        genreA: "G2",
        genreB: "G3",
        artistOverlapJaccard: 0.4,
        albumOverlapJaccard: 0.4,
        trackOverlapJaccard: 0.4,
        playlistCooccurWeight: 0.4,
        sharedArtistCount: 2,
        sharedAlbumCount: 2,
        sharedTrackCount: 2,
        totalWeight: 0.4,
      ),
      GenreEdgeEvidence(
        genreA: "G1",
        genreB: "G2",
        artistOverlapJaccard: 0.2,
        albumOverlapJaccard: 0.2,
        trackOverlapJaccard: 0.2,
        playlistCooccurWeight: 0.2,
        sharedArtistCount: 2,
        sharedAlbumCount: 2,
        sharedTrackCount: 2,
        totalWeight: 0.2,
      ),
    ]
    let measure: (String, CGFloat, GenreMapNodeKind) -> CGSize = { text, _, _ in
      CGSize(width: CGFloat(text.count * 8), height: 22)
    }
    let first = GenreMapBuilder.build(
      nodes: nodes,
      evidence: evidence,
      measureLabel: measure,
    )
    let second = GenreMapBuilder.build(
      nodes: nodes,
      evidence: evidence,
      measureLabel: measure,
    )
    #expect(first.layoutEdges == second.layoutEdges)
    // Communities and positions identical.
    #expect(first.nodes.map(\.communityID) == second.nodes.map(\.communityID))
    for (lhs, rhs) in zip(first.nodes, second.nodes) {
      #expect(lhs.position.x == rhs.position.x)
      #expect(lhs.position.y == rhs.position.y)
    }
  }

  /// Phase-1 gate regression pin: with the **default** `Configuration`,
  /// a synthetic library shaped like the real one (115 genres + a long-
  /// tail Jaccard distribution skewing toward small composites) must
  /// surface enough layout edges that Louvain doesn't fragment into
  /// near-singletons. The original Phase-1 defaults produced 41 layout
  /// edges / 93 communities on the real library — the gate review
  /// dropped the floor to recover ~120–180 edges and ≤25 communities.
  /// This test pins the FILTER pre-flight specifically, so a future
  /// regression on the threshold gets caught before live verification.
  @Test
  func `default candidate-filter floor lets a real-library-shaped graph through`() {
    let genreCount = 115
    let nodes = (0 ..< genreCount).map { index in
      GenreNode(
        genre: String(format: "G%03d", index),
        trackCount: 50 + index,
        albumCount: 10 + index / 2,
        artistCount: 5 + index / 3,
        weight: 0.05 + 0.9 * (Double(index) / Double(genreCount - 1)),
      )
    }
    // Build a synthetic candidate set roughly matching the real
    // library: each node connects to ~10 random partners with a
    // composite total weight drawn from a long-tailed range (most
    // small, a few large). Determinism via a fixed-seed PRNG so the
    // test never flakes.
    var rng = SplitMix64(seed: 0xCAFE_F00D_DEAD_BEEF)
    var seen = Set<String>()
    var evidence = [GenreEdgeEvidence]()
    for index in 0 ..< genreCount {
      let neighbourCount = 10
      for _ in 0 ..< neighbourCount {
        let other = Int(rng.next() % UInt64(genreCount))
        guard other != index else { continue }
        let lhs = String(format: "G%03d", min(index, other))
        let rhs = String(format: "G%03d", max(index, other))
        let key = "\(lhs)|\(rhs)"
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        // Composite drawn from `[0.002, 0.4]` skewed toward the low end
        // — same shape as the real `genre_edge_evidence.total_weight`
        // histogram.
        let u = rng.nextUnitFraction()
        let weight = 0.002 + 0.4 * pow(u, 3)
        evidence.append(GenreEdgeEvidence(
          genreA: lhs,
          genreB: rhs,
          artistOverlapJaccard: weight * 0.5,
          albumOverlapJaccard: weight * 0.4,
          trackOverlapJaccard: weight * 0.2,
          playlistCooccurWeight: weight * 0.1,
          sharedArtistCount: 2,
          sharedAlbumCount: 1,
          sharedTrackCount: 1,
          totalWeight: weight,
        ))
      }
    }
    let configuration = GenreMapBuilder.Configuration()
    let filtered = GenreMapBuilder.filterCandidates(
      evidence: evidence,
      nodeNames: Set(nodes.map(\.genre)),
      configuration: configuration,
    )
    // Floor: 120 edges. This is the "Phase 2 has a real substrate to
    // stand on" bar — Louvain on a 115-node graph with ~120+ edges
    // converges into ≤25 communities, not into 90+ singletons. Lower
    // this number and the fragmentation defect comes back.
    #expect(
      filtered.count >= 120,
      "candidate filter too aggressive: only \(filtered.count) edges survived (need ≥120)",
    )
  }

  @Test
  func `candidate filter respects minimum edge weight`() {
    let nodes = (0 ..< 4).map { index in
      GenreNode(
        genre: "G\(index)",
        trackCount: 3,
        albumCount: 1,
        artistCount: 1,
        weight: 0.5,
      )
    }
    let evidence: [GenreEdgeEvidence] = [
      // Just barely above the floor.
      GenreEdgeEvidence(
        genreA: "G0",
        genreB: "G1",
        artistOverlapJaccard: 0.5,
        albumOverlapJaccard: 0.5,
        trackOverlapJaccard: 0.5,
        playlistCooccurWeight: 0.5,
        sharedArtistCount: 2,
        sharedAlbumCount: 2,
        sharedTrackCount: 2,
        totalWeight: 0.5,
      ),
      // Below the configured floor.
      GenreEdgeEvidence(
        genreA: "G2",
        genreB: "G3",
        artistOverlapJaccard: 0.01,
        albumOverlapJaccard: 0.01,
        trackOverlapJaccard: 0.01,
        playlistCooccurWeight: 0.01,
        sharedArtistCount: 2,
        sharedAlbumCount: 0,
        sharedTrackCount: 0,
        totalWeight: 0.01,
      ),
    ]
    var configuration = GenreMapBuilder.Configuration()
    configuration.minEdgeWeight = 0.10
    let filtered = GenreMapBuilder.filterCandidates(
      evidence: evidence,
      nodeNames: Set(nodes.map(\.genre)),
      configuration: configuration,
    )
    #expect(filtered.count == 1)
    #expect(filtered.first?.genreA == "G0")
  }

  /// **Phase-3-gate 2026-05-20 (the "stop compacting" reset).** The
  /// model's `defaultCentre` is the centroid of the **heaviest
  /// community** — the one with the largest summed member weight — not
  /// the world centroid. The panel uses this to centre the default
  /// presentation on a recognisable neighbourhood at scale 1.0×; the
  /// rest of the map scrolls.
  @Test
  func `default centre is the heaviest community's centroid`() throws {
    // Two clear communities: heavy (G0/G1/G2 with weight ~0.9) and
    // light (G3/G4/G5 with weight ~0.2). Edge weights make the
    // partition unambiguous (heavy within-cluster, weak across).
    let heavy = (0 ..< 3).map { index in
      GenreNode(
        genre: "G\(index)",
        trackCount: 100,
        albumCount: 20,
        artistCount: 20,
        weight: 0.9,
      )
    }
    let light = (3 ..< 6).map { index in
      GenreNode(
        genre: "G\(index)",
        trackCount: 5,
        albumCount: 1,
        artistCount: 1,
        weight: 0.2,
      )
    }
    var evidence = [GenreEdgeEvidence]()
    func edge(_ a: String, _ b: String, _ weight: Double) -> GenreEdgeEvidence {
      GenreEdgeEvidence(
        genreA: min(a, b),
        genreB: max(a, b),
        artistOverlapJaccard: weight,
        albumOverlapJaccard: weight,
        trackOverlapJaccard: weight,
        playlistCooccurWeight: weight,
        sharedArtistCount: 4,
        sharedAlbumCount: 2,
        sharedTrackCount: 2,
        totalWeight: weight,
      )
    }
    // Heavy cluster — strong internal edges.
    evidence.append(edge("G0", "G1", 0.9))
    evidence.append(edge("G1", "G2", 0.9))
    evidence.append(edge("G0", "G2", 0.85))
    // Light cluster — strong internal edges (so it forms its own
    // community), but weight-sum stays low because members are small.
    evidence.append(edge("G3", "G4", 0.9))
    evidence.append(edge("G4", "G5", 0.9))
    evidence.append(edge("G3", "G5", 0.85))
    // One weak bridge keeps the graph connected.
    evidence.append(edge("G2", "G3", 0.05))
    let model = GenreMapBuilder.build(
      nodes: heavy + light,
      evidence: evidence,
      measureLabel: { text, _, _ in CGSize(width: CGFloat(text.count * 7), height: 22) },
    )
    // Find the heaviest community by summed member weight.
    let weightByGenre = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.genre, $0.weight) })
    let heaviestCommunity = try #require(model.communities.max(by: { lhs, rhs in
      let lhsSum = lhs.members.reduce(0.0) { $0 + (weightByGenre[$1] ?? 0) }
      let rhsSum = rhs.members.reduce(0.0) { $0 + (weightByGenre[$1] ?? 0) }
      return lhsSum < rhsSum
    }), "no communities")
    // `defaultCentre` matches the heaviest community's centroid exactly.
    #expect(abs(model.defaultCentre.x - heaviestCommunity.centroid.x) < 1.0e-6)
    #expect(abs(model.defaultCentre.y - heaviestCommunity.centroid.y) < 1.0e-6)
    // And the heaviest community's members are the high-weight ones.
    let heaviestMembers = Set(heaviestCommunity.members)
    #expect(heaviestMembers.contains("G0") || heaviestMembers.contains("G1") || heaviestMembers.contains("G2"))
  }
}
