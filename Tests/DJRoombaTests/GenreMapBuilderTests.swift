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
      measureLabel: { _, _ in CGSize(width: 60, height: 24) },
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
      measureLabel: { text, _ in CGSize(width: CGFloat(text.count * 7), height: 22) },
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
    let measure: (String, CGFloat) -> CGSize = { text, _ in
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
}
