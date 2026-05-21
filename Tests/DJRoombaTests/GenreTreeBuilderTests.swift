import Foundation
import Testing
@testable import DJRoomba

/// Phase A pure-logic invariants for `GenreTreeBuilder`
/// (`plans/son-of-genre-map.md` Phase A). Fixture-driven — no SQLite, no
/// SwiftUI, no MusicKit — so the MST + trunk selection + BFS forest are
/// pinned independently of the store and the renderer.
struct GenreTreeBuilderTests {

  // MARK: Internal

  /// Build a `GenreNode` from a (name, weight) tuple. Track / album /
  /// artist counts are decorative for these tests (the builder reads
  /// only `genre` + `weight`).
  static func node(_ name: String, _ weight: Double) -> GenreNode {
    GenreNode(
      genre: name,
      trackCount: 0,
      albumCount: 0,
      artistCount: 0,
      weight: weight,
    )
  }

  /// Build a canonical-half `GenreEdgeEvidence` row from a triple
  /// `(a, b, totalWeight)`. Per the schema, `a < b` lexicographically;
  /// the helper enforces that.
  static func edge(_ a: String, _ b: String, _ weight: Double) -> GenreEdgeEvidence {
    let lo = a < b ? a : b
    let hi = a < b ? b : a
    return GenreEdgeEvidence(
      genreA: lo,
      genreB: hi,
      artistOverlapJaccard: 0,
      albumOverlapJaccard: 0,
      trackOverlapJaccard: 0,
      playlistCooccurWeight: 0,
      sharedArtistCount: 1,
      sharedAlbumCount: 1,
      sharedTrackCount: 1,
      totalWeight: weight,
    )
  }

  /// Flatten the tree under `node` into the set of every genre name
  /// it contains (the trunk + every descendant). Used to assert
  /// claim membership without depending on parent/child ordering.
  static func collectGenres(from node: GenreTreeNode) -> Set<String> {
    var out: Set<String> = [node.genre.name]
    for child in node.children {
      out.formUnion(collectGenres(from: child))
    }
    return out
  }

  /// The trunk genre name for the given community in `model`, or
  /// `nil` if no trunk represents that community.
  static func trunkName(in model: GenreTreeModel, forCommunity id: Int) -> String? {
    model.trunks.first { $0.communityID == id }?.root.genre.name
  }

  /// 5-node fixture with a deliberate cycle. The MST must drop the
  /// weakest edge in the cycle (lowest `totalWeight` ⇒ highest cost)
  /// and keep exactly `n − 1 = 4` edges over the 5 nodes.
  ///
  /// Cycle: A–B (0.9), B–C (0.8), A–C (0.5) — must drop A–C.
  /// Spurs:  C–D (0.7), D–E (0.6).
  /// Result: {A–B, B–C, C–D, D–E}.
  @Test
  func `kruskal on a 5 node cycle drops the weakest edge`() {
    let nodes = ["A", "B", "C", "D", "E"].map { Self.node($0, 0.5) }
    let evidence = [
      Self.edge("A", "B", 0.9),
      Self.edge("B", "C", 0.8),
      Self.edge("A", "C", 0.5),
      Self.edge("C", "D", 0.7),
      Self.edge("D", "E", 0.6),
    ]
    let mst = GenreTreeBuilder.kruskalMST(
      evidence: evidence,
      nodeNames: Set(nodes.map(\.genre)),
    )
    #expect(mst.count == 4, "MST over 5 connected nodes keeps 4 edges")
    let kept = Set(mst.map { Pair(a: $0.genreA, b: $0.genreB) })
    #expect(kept.contains(Pair(a: "A", b: "B")))
    #expect(kept.contains(Pair(a: "B", b: "C")))
    #expect(kept.contains(Pair(a: "C", b: "D")))
    #expect(kept.contains(Pair(a: "D", b: "E")))
    #expect(!kept.contains(Pair(a: "A", b: "C")), "weakest cycle edge dropped")
  }

  /// MST cost ordering: the kept edges, sorted by their cost
  /// (`1 − totalWeight`), should always start with the cheapest /
  /// strongest composite-weight edge. The cycle in the previous
  /// fixture means the kept set is `{0.9, 0.8, 0.7, 0.6}` ⇒ the
  /// strongest kept edge is A–B at weight 0.9.
  @Test
  func `kruskal keeps the strongest edges in the spanning tree`() {
    let nodes = ["A", "B", "C", "D", "E"].map { Self.node($0, 0.5) }
    let evidence = [
      Self.edge("A", "B", 0.9),
      Self.edge("B", "C", 0.8),
      Self.edge("A", "C", 0.5),
      Self.edge("C", "D", 0.7),
      Self.edge("D", "E", 0.6),
    ]
    let mst = GenreTreeBuilder.kruskalMST(
      evidence: evidence,
      nodeNames: Set(nodes.map(\.genre)),
    )
    let weights = mst.map(\.totalWeight).sorted(by: >)
    #expect(weights == [0.9, 0.8, 0.7, 0.6])
  }

  /// Disconnected component: edges that don't touch any pair of
  /// in-set nodes are silently dropped (defensive against substrate
  /// rows referencing genres no longer in the active node set).
  @Test
  func `kruskal drops edges that reference unknown nodes`() {
    let nodes = ["A", "B", "C"].map { Self.node($0, 0.5) }
    let evidence = [
      Self.edge("A", "B", 0.9),
      Self.edge("B", "C", 0.8),
      Self.edge("A", "Z", 0.7), // Z is not in the node set.
    ]
    let mst = GenreTreeBuilder.kruskalMST(
      evidence: evidence,
      nodeNames: Set(nodes.map(\.genre)),
    )
    #expect(mst.count == 2, "Z-touching edge dropped, 2 edges over 3 nodes")
    #expect(mst.allSatisfy { $0.genreA != "Z" && $0.genreB != "Z" })
  }

  /// 8 communities, each with one heavy + one light member. The cap
  /// (`trunkCap = 7`) must drop the lowest-community-weight community
  /// entirely — no trunk for it; its members become orphans (no MST
  /// edges to the kept communities in this fixture) or branches of
  /// the surviving trunks (if MST-connected).
  @Test
  func `trunk cap drops the lowest weight communities at k greater than 7`() {
    // Eight isolated 2-member communities. The lightest-weighted
    // (community 8 ⇒ total weight 0.02) must lose its trunk slot.
    var nodes = [GenreNode]()
    var communityByGenre = [String: Int]()
    var evidence = [GenreEdgeEvidence]()
    for i in 1...8 {
      let weight = 1.0 - Double(i - 1) * 0.10 // 1.00, 0.90, 0.80, ..., 0.30
      let primary = "P\(i)"
      let secondary = "S\(i)"
      nodes.append(Self.node(primary, weight))
      nodes.append(Self.node(secondary, weight - 0.05))
      communityByGenre[primary] = i
      communityByGenre[secondary] = i
      // One intra-community edge so the community has an MST shape.
      evidence.append(Self.edge(primary, secondary, 0.8))
    }
    // Connect community 1's primary to every other community's primary
    // with progressively weaker edges so the MST is connected end-to-
    // end. The 8th-community connection still costs `1 − 0.05 = 0.95`
    // so its members may end up as far-flung branches off whichever
    // surviving trunk's BFS claims them first; the test asserts the
    // *cap behaviour*, not which surviving trunk wins those leaves.
    for i in 2...8 {
      evidence.append(Self.edge("P1", "P\(i)", 0.1 - Double(i) * 0.01))
    }
    let model = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communityByGenre,
      metric: .highestWeight,
    )
    #expect(model.trunks.count == GenreTreeBuilder.trunkCap)
    #expect(model.trunks.count == 7)
    // The 8th-heaviest community (id 8) must NOT contribute a trunk.
    let trunkCommunities = Set(model.trunks.map(\.communityID))
    #expect(!trunkCommunities.contains(8))
    // Communities 1..7 are the survivors.
    #expect(trunkCommunities == Set(1...7))
  }

  /// Two completely-symmetric communities (same weights, same edges).
  /// The trunk selection must be deterministic across runs: identical
  /// inputs ⇒ identical trunks, picked in identical order.
  @Test
  func `trunk selection is deterministic on symmetric input`() {
    let nodes = [
      Self.node("A", 0.5),
      Self.node("B", 0.3),
      Self.node("C", 0.5),
      Self.node("D", 0.3),
    ]
    let evidence = [
      Self.edge("A", "B", 0.8),
      Self.edge("C", "D", 0.8),
      Self.edge("B", "C", 0.4),
    ]
    let communities: [String: Int] = ["A": 1, "B": 1, "C": 2, "D": 2]

    let first = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    let second = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    #expect(first == second, "identical inputs must produce identical output")
  }

  /// `selectTrunks` tie-break inside a community: two members with
  /// identical weight ⇒ the lex-smaller name wins.
  @Test
  func `intra community tie break prefers lex smaller name on equal weight`() {
    let nodes = [
      Self.node("BetaGenre", 0.7),
      Self.node("AlphaGenre", 0.7),
    ]
    let evidence = [Self.edge("AlphaGenre", "BetaGenre", 0.5)]
    let communities = ["AlphaGenre": 1, "BetaGenre": 1]
    let model = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    #expect(model.trunks.count == 1)
    #expect(model.trunks[0].root.genre.name == "AlphaGenre")
  }

  /// Two trunks (T1, T2) connected by a chain of three middle nodes:
  /// T1 — A — B — C — T2. Each MST edge has equal weight (0.5 ⇒ cost
  /// 0.5). T1 and T2 BFS outward at the same rate; A goes to T1 (1
  /// step), C goes to T2 (1 step), B is reached at depth 2 from both
  /// — the lex-smaller trunk name (T1) wins.
  @Test
  func `bfs first claim resolves ties by lex smaller trunk name`() throws {
    let nodes = [
      Self.node("T1", 1.0),
      Self.node("A", 0.5),
      Self.node("B", 0.5),
      Self.node("C", 0.5),
      Self.node("T2", 1.0),
    ]
    let evidence = [
      Self.edge("T1", "A", 0.5),
      Self.edge("A", "B", 0.5),
      Self.edge("B", "C", 0.5),
      Self.edge("C", "T2", 0.5),
    ]
    // T1 + A in community 1, T2 + C in community 2, B placed in
    // community 1 so it doesn't become its own trunk. We're testing
    // BFS first-claim, not trunk-selection — community assignment
    // just needs to keep B from minting a third trunk.
    let communities = ["T1": 1, "A": 1, "B": 1, "C": 2, "T2": 2]
    let model = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    #expect(model.trunks.count == 2)
    let t1 = model.trunks.first { $0.root.genre.name == "T1" }
    let t2 = model.trunks.first { $0.root.genre.name == "T2" }
    #expect(t1 != nil)
    #expect(t2 != nil)
    // A is depth-1 under T1; C is depth-1 under T2; B (equidistant)
    // goes to the lex-smaller trunk T1.
    let t1Members = Self.collectGenres(from: try #require(t1?.root))
    let t2Members = Self.collectGenres(from: try #require(t2?.root))
    #expect(t1Members.contains("A"))
    #expect(t1Members.contains("B"), "equidistant B claimed by lex-smaller trunk T1")
    #expect(t2Members.contains("C"))
    #expect(!t2Members.contains("B"))
  }

  /// BFS first-claim correctness on unequal costs. Trunk T1 reaches B
  /// in 2 cheap steps (0.1 + 0.1 = 0.2); T2 reaches B in 1 expensive
  /// step (0.9). T1 wins on cumulative cost.
  @Test
  func `bfs first claim prefers cheaper cumulative cost over fewer hops`() throws {
    let nodes = [
      Self.node("T1", 1.0),
      Self.node("A", 0.5),
      Self.node("B", 0.5),
      Self.node("T2", 1.0),
    ]
    let evidence = [
      // T1 - A - B chain, cheap (high totalWeight ⇒ low cost).
      Self.edge("T1", "A", 0.9),
      Self.edge("A", "B", 0.9),
      // T2 - B direct, expensive (low totalWeight ⇒ high cost).
      Self.edge("B", "T2", 0.1),
    ]
    let communities = ["T1": 1, "A": 1, "B": 1, "T2": 2]
    let model = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    let t1 = model.trunks.first { $0.root.genre.name == "T1" }
    let t2 = model.trunks.first { $0.root.genre.name == "T2" }
    let t1Members = Self.collectGenres(from: try #require(t1?.root))
    let t2Members = Self.collectGenres(from: try #require(t2?.root))
    #expect(t1Members.contains("B"), "T1 should win B by cheaper cumulative cost (0.2 < 0.9)")
    #expect(!t2Members.contains("B"))
  }

  /// Hand-crafted fixture where the three metrics each pick a
  /// different community member as trunk.
  ///
  /// Community 1:
  ///   - "Heavy": high library weight, low transferness (no cross-community edges)
  ///   - "Bridge": low library weight, but it's the only member with
  ///     a cross-community edge (community 2 ⇒ high cross-community
  ///     fraction ⇒ high transferness).
  ///   - "Centre": mid weight, sits between Heavy and Bridge in the
  ///     induced MST ⇒ highest betweenness inside community 1.
  @Test
  func `metric variants pick different trunks on a tailored fixture`() {
    let nodes = [
      Self.node("Heavy", 0.95),
      Self.node("Centre", 0.40),
      Self.node("Bridge", 0.10),
      // Community 2 members — every metric should pick the same
      // single member (the only one) for community 2.
      Self.node("Other", 0.50),
    ]
    let evidence = [
      // Community 1 MST shape: Heavy — Centre — Bridge.
      Self.edge("Centre", "Heavy", 0.8),
      Self.edge("Bridge", "Centre", 0.8),
      // Cross-community edge: Bridge — Other.
      Self.edge("Bridge", "Other", 0.6),
    ]
    let communities: [String: Int] = [
      "Heavy": 1,
      "Centre": 1,
      "Bridge": 1,
      "Other": 2,
    ]
    let byWeight = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    let byCentrality = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestCentrality,
    )
    let byTransferness = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestTransferness,
    )

    let weightCommunity1 = Self.trunkName(in: byWeight, forCommunity: 1)
    let centralityCommunity1 = Self.trunkName(in: byCentrality, forCommunity: 1)
    let transfernessCommunity1 = Self.trunkName(in: byTransferness, forCommunity: 1)

    #expect(weightCommunity1 == "Heavy", "`.highestWeight` picks heaviest member")
    #expect(centralityCommunity1 == "Centre", "`.highestCentrality` picks induced-MST middle")
    #expect(
      transfernessCommunity1 == "Bridge",
      "`.highestTransferness` picks the cross-community member",
    )
    // The three picks really are pairwise different.
    let picks = Set([weightCommunity1, centralityCommunity1, transfernessCommunity1])
    #expect(picks.count == 3)
  }

  /// Empty input ⇒ empty model (no trunks, no orphans, no crashes).
  @Test
  func `empty input produces empty model`() {
    let model = GenreTreeBuilder.build(
      nodes: [],
      evidence: [],
      communityByGenre: [:],
      metric: .highestWeight,
    )
    #expect(model.trunks.isEmpty)
    #expect(model.orphans.isEmpty)
  }

  /// Genre exists in `nodes` but has no community assignment and no
  /// MST connection to any community member ⇒ surfaces as an orphan,
  /// not silently swallowed.
  @Test
  func `genre with no community and no MST path lands as an orphan`() {
    let nodes = [
      Self.node("A", 0.5),
      Self.node("B", 0.5),
      // Loose end with no community and no edges:
      Self.node("Loose", 0.3),
    ]
    let evidence = [Self.edge("A", "B", 0.7)]
    let communities = ["A": 1, "B": 1] // Loose deliberately omitted.
    let model = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    #expect(model.trunks.count == 1)
    #expect(model.orphans.count == 1)
    #expect(model.orphans.first?.name == "Loose")
  }

  /// Child ordering inside a trunk's subtree must be deterministic
  /// and weight-desc. Heavier branches sort first (so Phase B's
  /// radial layout fans them nearest the trunk's local "12 o'clock").
  @Test
  func `children are sorted by per genre weight descending then lex`() {
    let nodes = [
      Self.node("Trunk", 1.0),
      Self.node("Heavy", 0.9),
      Self.node("LightA", 0.2),
      Self.node("LightB", 0.2),
    ]
    let evidence = [
      Self.edge("Heavy", "Trunk", 0.7),
      Self.edge("LightA", "Trunk", 0.5),
      Self.edge("LightB", "Trunk", 0.5),
    ]
    let communities = ["Trunk": 1, "Heavy": 1, "LightA": 1, "LightB": 1]
    let model = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communities,
      metric: .highestWeight,
    )
    #expect(model.trunks.count == 1)
    let children = model.trunks[0].root.children.map(\.genre.name)
    #expect(children == ["Heavy", "LightA", "LightB"])
  }

  // MARK: Private

  /// Canonical-ordered name pair for set membership in MST assertions.
  private struct Pair: Hashable {
    init(a: String, b: String) {
      let lo = a < b ? a : b
      let hi = a < b ? b : a
      self.a = lo
      self.b = hi
    }

    var a: String
    var b: String

  }

}
