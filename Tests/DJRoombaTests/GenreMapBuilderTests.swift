import CoreGraphics
import Testing
@testable import DJRoomba

// MARK: - SplitMix64

/// Deterministic seeded PRNG. Originated in `GenreMapForceLayout`
/// (retired in Phase E of `plans/son-of-genre-map.md`); kept here so
/// the synthetic-real-library-shape regression test below stays
/// reproducible.
private struct SplitMix64 {

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
    z = z ^ (z &>> 31)
    return z
  }

  mutating func nextUnitFraction() -> Double {
    Double(next() &>> 11) / Double(1 << 53)
  }

  private var state: UInt64
}

// MARK: - GenreMapBuilderTests

/// End-to-end pure-pipeline tests for `GenreMapBuilder`. The metro
/// renderer retired in Phase E of `plans/son-of-genre-map.md`;
/// `GenreMapBuilder` survives as the **substrate loader** the tree
/// view's `GenreTreeService` reads through (community detection +
/// transferness + cross-resolution Louvain matching).
struct GenreMapBuilderTests {

  @Test
  func `empty input yields an empty model`() {
    let result = GenreMapBuilder.build(nodes: [], evidence: [])
    #expect(result.model.nodes.isEmpty)
    #expect(result.model.layoutEdges.isEmpty)
    #expect(result.model.communities.isEmpty)
    #expect(result.stateRows.isEmpty)
  }

  @Test
  func `every input genre gets a node in the model`() {
    let nodes = (0 ..< 8).map { index in
      GenreNode(
        genre: "G\(index)",
        trackCount: 10,
        albumCount: 2,
        artistCount: 2,
        weight: 0.2 + 0.1 * Double(index),
      )
    }
    // A small ring of evidence so the layout graph is connected.
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
    let result = GenreMapBuilder.build(nodes: nodes, evidence: evidence)
    #expect(result.model.nodes.count == 8)
    // Layout graph is connected (after MST).
    var uf = UnionFind(elements: Set(result.model.nodes.map(\.genre)))
    for edge in result.model.layoutEdges {
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
    let first = GenreMapBuilder.build(nodes: nodes, evidence: evidence)
    let second = GenreMapBuilder.build(nodes: nodes, evidence: evidence)
    #expect(first.model.layoutEdges == second.model.layoutEdges)
    #expect(first.model.nodes.map(\.communityID) == second.model.nodes.map(\.communityID))
  }

  /// Phase-1 gate regression pin: with the **default** `Configuration`,
  /// a synthetic library shaped like the real one (115 genres + a
  /// long-tail Jaccard distribution skewing toward small composites)
  /// must surface enough layout edges that Louvain doesn't fragment
  /// into near-singletons.
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
}
