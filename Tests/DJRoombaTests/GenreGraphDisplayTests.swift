import ForceGraph
import Foundation
import Testing
@testable import DJRoomba

/// `GenreGraphService.buildDisplayGraph` — the pure fold from the persisted
/// `genre_edge` half-edges to the `ForceGraphView` node/edge lists. Graph
/// *density* is now shaped upstream at analysis time
/// (`rebuildGenreGraph`'s thresholds, covered by `GenreGraphTests`); this
/// fold is a faithful projection. Pins: only the canonical `a<b` half is
/// kept; weight is normalised to `0...1` over the kept edges by the max
/// with a `0.12` floor; **every co-occurring genre stays a node** (so a
/// low-degree genre stays searchable/centerable) even when the edge perf
/// backstop trims its links; the `maxEdges` backstop keeps the strongest;
/// empty input yields empty lists. Deliberately a `nonisolated static` so
/// it tests with no store and no MainActor.
struct GenreGraphDisplayTests {

  @Test
  func `keeps one canonical edge per undirected pair with sorted nodes`() throws {
    // Both directed half-edges, as the store returns them.
    let stored = [
      GenreEdge(genreA: "Rock", genreB: "Jazz", weight: 3),
      GenreEdge(genreA: "Jazz", genreB: "Rock", weight: 3),
    ]
    let built = GenreGraphService.buildDisplayGraph(from: stored)

    #expect(built.edges.count == 1, "the mirror half-edge is dropped")
    let edge = try #require(built.edges.first)
    #expect(edge.a == "Jazz" && edge.b == "Rock", "canonical a<b")
    #expect(edge.weight == 1, "single distinct weight ⇒ normalises to 1")
    #expect(built.nodes.map(\.id) == ["Jazz", "Rock"], "node set, sorted")
    #expect(built.nodes.map(\.label) == ["Jazz", "Rock"])
  }

  /// Weight is `raw / maxRaw`, floored at `0.12` so the weakest edge keeps
  /// a little presence rather than collapsing to zero spring.
  @Test
  func `normalises weights by the max with a floor`() {
    let stored = [
      GenreEdge(genreA: "A", genreB: "B", weight: 10), // max ⇒ 1.0
      GenreEdge(genreA: "A", genreB: "C", weight: 5), // 0.5
      GenreEdge(genreA: "A", genreB: "D", weight: 1), // 0.1 → floored 0.12
    ]
    let built = GenreGraphService.buildDisplayGraph(from: stored)
    let byPair = Dictionary(
      uniqueKeysWithValues: built.edges.map { ("\($0.a)~\($0.b)", $0.weight) }
    )
    #expect(byPair["A~B"] == 1)
    #expect(byPair["A~C"] == 0.5)
    #expect(byPair["A~D"] == 0.12, "floored, not 0.1")
    #expect(built.nodes.map(\.id) == ["A", "B", "C", "D"])
  }

  @Test
  func `empty input yields an empty graph`() {
    let built = GenreGraphService.buildDisplayGraph(from: [])
    #expect(built.nodes.isEmpty)
    #expect(built.edges.isEmpty)
  }

  /// A store that somehow returned only one orientation still produces the
  /// edge (the filter is `a<b`, not "must see both halves").
  @Test
  func `a lone canonical half edge is still emitted`() {
    let built = GenreGraphService.buildDisplayGraph(
      from: [GenreEdge(genreA: "Ambient", genreB: "Techno", weight: 2)]
    )
    #expect(built.edges.count == 1)
    #expect(built.nodes.map(\.id) == ["Ambient", "Techno"])
    #expect(built.edges.first?.weight == 1)
  }

  /// The display-side perf backstop: never hands the view more than
  /// `maxEdges`, and they are the strongest by weight. Density is shaped at
  /// analysis time now; this is purely a responsiveness ceiling.
  @Test
  func `the edge backstop keeps only the strongest edges`() {
    let k4 = [
      GenreEdge(genreA: "A", genreB: "B", weight: 6),
      GenreEdge(genreA: "A", genreB: "C", weight: 5),
      GenreEdge(genreA: "B", genreB: "C", weight: 4),
      GenreEdge(genreA: "A", genreB: "D", weight: 3),
      GenreEdge(genreA: "B", genreB: "D", weight: 2),
      GenreEdge(genreA: "C", genreB: "D", weight: 1),
    ]
    let built = GenreGraphService.buildDisplayGraph(from: k4, maxEdges: 2)

    #expect(
      Set(built.edges.map { "\($0.a)~\($0.b)" }) == ["A~B", "A~C"],
      "the two heaviest canonical edges, strongest first",
    )
    let byPair = Dictionary(uniqueKeysWithValues: built.edges.map { ("\($0.a)~\($0.b)", $0.weight) })
    #expect(byPair["A~B"] == 1, "renormalised over the kept max (6)")
  }

  /// Every co-occurring genre stays a node even though the backstop trimmed
  /// its edges — the "centre americana" guarantee: a perf cap never makes a
  /// genre vanish from (or unsearchable in) the graph.
  @Test
  func `every genre stays a node though edges are capped`() {
    let many = (1 ... 5).map { i in
      GenreEdge(genreA: "P\(i)", genreB: "Q\(i)", weight: i) // disjoint pairs
    }
    let built = GenreGraphService.buildDisplayGraph(from: many, maxEdges: 2)
    #expect(built.edges.count == 2)
    #expect(
      Set(built.edges.map { "\($0.a)~\($0.b)" }) == ["P5~Q5", "P4~Q4"],
      "the two heaviest disjoint edges",
    )
    #expect(
      built.nodes.map(\.id).sorted()
        == ["P1", "P2", "P3", "P4", "P5", "Q1", "Q2", "Q3", "Q4", "Q5"],
      "all 10 genres remain nodes though only 2 edges survived",
    )
  }

  /// The exact field report: a low-connectivity genre ("Americana") whose
  /// lone weak edge falls outside the strongest-`maxEdges` must still be a
  /// node so the user can search and centre it.
  @Test
  func `a genre whose edges are trimmed is still a searchable node`() {
    let edges = [
      GenreEdge(genreA: "Folk", genreB: "Rock", weight: 50),
      GenreEdge(genreA: "Folk", genreB: "Pop", weight: 40),
      GenreEdge(genreA: "Pop", genreB: "Rock", weight: 30),
      GenreEdge(genreA: "Americana", genreB: "Folk", weight: 1),
    ]
    let built = GenreGraphService.buildDisplayGraph(from: edges, maxEdges: 2)
    #expect(
      !built.edges.contains { $0.a == "Americana" || $0.b == "Americana" },
      "Americana's lone weak edge is outside the top-2",
    )
    #expect(
      built.nodes.contains { $0.id == "Americana" },
      "…but Americana is still a node — searchable and centerable",
    )
  }

  /// Under the default backstop (well above any small graph) nothing is
  /// trimmed — the fold is a faithful projection of the analyzed graph.
  @Test
  func `a small graph is passed through intact under the default backstop`() {
    let sparse = [
      GenreEdge(genreA: "Ambient", genreB: "Techno", weight: 4),
      GenreEdge(genreA: "Dub", genreB: "Techno", weight: 2), // canonical D<T
      GenreEdge(genreA: "Dub", genreB: "Reggae", weight: 1),
    ]
    let built = GenreGraphService.buildDisplayGraph(from: sparse)
    #expect(built.edges.count == 3, "nothing trimmed")
    #expect(built.nodes.map(\.id) == ["Ambient", "Dub", "Reggae", "Techno"])
  }
}
