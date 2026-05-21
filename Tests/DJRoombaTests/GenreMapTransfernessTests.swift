import Foundation
import Testing
@testable import DJRoomba

/// Pure-logic tests for `GenreMapTransferness`
/// (`plans/genre-metro-map.md` Phase 2). Every test runs on a hand-built
/// fixture small enough to compute by hand — that's the plan's explicit
/// ask in Phase 2's success criteria.
struct GenreMapTransfernessTests {

  /// On a path graph `A — B — C — D — E`, the middle node `C` is on
  /// every shortest path that crosses the middle ⇒ maximum betweenness.
  @Test
  func `Brandes on a path graph: centre node has the maximum betweenness`() {
    let nodes = ["A", "B", "C", "D", "E"]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "B", b: "C", weight: 1.0),
      (a: "C", b: "D", weight: 1.0),
      (a: "D", b: "E", weight: 1.0),
    ]
    let result = GenreMapTransferness.normalisedBetweenness(nodes: nodes, edges: edges)
    let centre = result["C"] ?? 0
    for name in ["A", "B", "D", "E"] {
      let other = result[name] ?? 0
      #expect(centre >= other, "centre \(centre) < \(name)=\(other)")
    }
    #expect((result["A"] ?? -1) == 0)
    #expect((result["E"] ?? -1) == 0)
  }

  /// Barbell graph: two cliques joined by a single bridge edge. The
  /// bridge endpoints have the highest betweenness (every cross-clique
  /// shortest path must go through them).
  @Test
  func `Brandes on a barbell graph: bridge endpoints have the maximum betweenness`() {
    // Clique 1: A,B,C ; Clique 2: D,E,F ; Bridge: C — D
    let nodes = ["A", "B", "C", "D", "E", "F"]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "A", b: "C", weight: 1.0),
      (a: "B", b: "C", weight: 1.0),
      (a: "C", b: "D", weight: 1.0),
      (a: "D", b: "E", weight: 1.0),
      (a: "D", b: "F", weight: 1.0),
      (a: "E", b: "F", weight: 1.0),
    ]
    let result = GenreMapTransferness.normalisedBetweenness(nodes: nodes, edges: edges)
    let bridge = (result["C"] ?? 0, result["D"] ?? 0)
    for name in ["A", "B", "E", "F"] {
      let leaf = result[name] ?? 0
      #expect(bridge.0 >= leaf)
      #expect(bridge.1 >= leaf)
    }
    // Bridge endpoints share the max (symmetric graph).
    let maxOnLeaves = ["A", "B", "E", "F"].map { result[$0] ?? 0 }.max() ?? 0
    #expect(bridge.0 > maxOnLeaves)
    #expect(bridge.1 > maxOnLeaves)
  }

  /// Star graph: one hub `H` connected to leaves `L1..L4`. Hub is on
  /// every leaf-to-leaf shortest path ⇒ maximum betweenness; leaves
  /// score 0.
  @Test
  func `Brandes on a star graph: hub has the maximum betweenness, leaves score zero`() {
    let nodes = ["H", "L1", "L2", "L3", "L4"]
    let edges = [
      (a: "H", b: "L1", weight: 1.0),
      (a: "H", b: "L2", weight: 1.0),
      (a: "H", b: "L3", weight: 1.0),
      (a: "H", b: "L4", weight: 1.0),
    ]
    let result = GenreMapTransferness.normalisedBetweenness(nodes: nodes, edges: edges)
    #expect((result["H"] ?? 0) == 1.0) // stretched to [0,1]; hub is the max
    for leaf in ["L1", "L2", "L3", "L4"] {
      #expect((result[leaf] ?? -1) == 0)
    }
  }

  /// All neighbours sit in the same community ⇒ entropy 0.
  @Test
  func `neighbour entropy: all neighbours in the same community gives zero`() {
    let nodes = ["A", "B", "C", "D"]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "A", b: "C", weight: 1.0),
      (a: "A", b: "D", weight: 1.0),
    ]
    let communities = ["A": 0, "B": 1, "C": 1, "D": 1]
    let entropy = GenreMapTransferness.neighbourCommunityEntropy(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    #expect((entropy["A"] ?? -1) == 0)
  }

  /// Two-class half-and-half neighbours ⇒ entropy = ln 2 / ln K.
  /// Three communities (K=3) total ⇒ normalised entropy = ln 2 / ln 3.
  @Test
  func `neighbour entropy: half-and-half two-class neighbours equals ln2 over lnK`() {
    let nodes = ["A", "B", "C", "D", "E"]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "A", b: "C", weight: 1.0),
      (a: "A", b: "D", weight: 1.0),
      (a: "A", b: "E", weight: 1.0),
    ]
    // K = 3 distinct communities ⇒ logK = ln(3).
    let communities = [
      "A": 0,
      "B": 1,
      "C": 1,
      "D": 2,
      "E": 2,
    ]
    let entropy = GenreMapTransferness.neighbourCommunityEntropy(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    let expected = log(2.0) / log(3.0)
    let actual = entropy["A"] ?? -1
    #expect(abs(actual - expected) < 1.0e-9, "expected \(expected), got \(actual)")
  }

  /// Maximally diverse neighbours (one per community, K=4) ⇒ normalised
  /// entropy approaches 1 (ln K / ln K).
  @Test
  func `neighbour entropy: uniform across all communities approaches one`() {
    let nodes = ["A", "B", "C", "D", "E"]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "A", b: "C", weight: 1.0),
      (a: "A", b: "D", weight: 1.0),
      (a: "A", b: "E", weight: 1.0),
    ]
    let communities = ["A": 0, "B": 1, "C": 2, "D": 3, "E": 4]
    let entropy = GenreMapTransferness.neighbourCommunityEntropy(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    let normalised = entropy["A"] ?? 0
    // 4 neighbours in 4 distinct communities (excluding A's community 0)
    // ⇒ p = 0.25 each ⇒ entropy = ln 4. K = 5 distinct ids total
    // ⇒ logK = ln 5. expected = ln 4 / ln 5 ≈ 0.861.
    let expected = log(4.0) / log(5.0)
    #expect(abs(normalised - expected) < 1.0e-9)
  }

  /// Half the incident edge weight crosses the community boundary ⇒
  /// fraction = 0.5.
  @Test
  func `cross-community fraction: half-outside neighbours gives one half`() {
    let nodes = ["A", "B", "C", "D"]
    let edges = [
      (a: "A", b: "B", weight: 1.0), // same community
      (a: "A", b: "C", weight: 1.0), // crosses
    ]
    let communities = ["A": 0, "B": 0, "C": 1, "D": 1]
    let fraction = GenreMapTransferness.crossCommunityFraction(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    #expect(abs((fraction["A"] ?? -1) - 0.5) < 1.0e-9)
  }

  /// Every incident edge crosses ⇒ fraction = 1.
  @Test
  func `cross-community fraction: fully bridging gives one`() {
    let nodes = ["A", "B", "C"]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "A", b: "C", weight: 1.0),
    ]
    let communities = ["A": 0, "B": 1, "C": 2]
    let fraction = GenreMapTransferness.crossCommunityFraction(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    #expect((fraction["A"] ?? -1) == 1.0)
  }

  /// No incident edges ⇒ fraction = 0 (isolated node, neither bridging
  /// nor parochial; betweenness already says "irrelevant").
  @Test
  func `cross-community fraction: isolated node scores zero`() {
    let nodes = ["A", "B", "C"]
    let edges = [
      (a: "B", b: "C", weight: 1.0)
    ]
    let communities = ["A": 0, "B": 1, "C": 1]
    let fraction = GenreMapTransferness.crossCommunityFraction(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    #expect((fraction["A"] ?? -1) == 0)
  }

  /// With `strandCountByNode = [:]` (Phase 2's default) the strand slot
  /// contributes zero — the inputs report 0, and the composite collapses
  /// onto the betweenness / entropy / cross-fraction sum at their spec
  /// weights.
  @Test
  func `composite: empty strand-count map keeps the strand slot at zero`() {
    let nodes = [
      (genre: "A", weight: 0.10),
      (genre: "B", weight: 0.10),
      (genre: "C", weight: 0.10),
      (genre: "D", weight: 0.10),
      (genre: "E", weight: 0.10),
    ]
    let edges = [
      (a: "A", b: "B", weight: 1.0),
      (a: "B", b: "C", weight: 1.0),
      (a: "C", b: "D", weight: 1.0),
      (a: "D", b: "E", weight: 1.0),
    ]
    let communities = ["A": 0, "B": 0, "C": 1, "D": 1, "E": 2]
    let result = GenreMapTransferness.score(
      nodes: nodes,
      edges: edges,
      communities: communities,
      strandCountByNode: [:],
    )
    for inputs in result.inputsByNode.values {
      #expect(inputs.strandCount == 0)
    }
  }

  /// **The plan's explicit perceptual ask** — a high-library-weight
  /// genre whose entire neighbourhood sits in its own community must
  /// NOT classify as a transfer station purely for being big and
  /// well-connected. This is the "Rock", "Pop", "Folk", "Country"
  /// guard, pinned in a test.
  ///
  /// Construct a star: `Rock` (weight 1.0) at the centre, connected to
  /// 6 small same-community neighbours; the neighbours' single edges
  /// are all in-community. Without dampening, `Rock`'s betweenness is
  /// the absolute maximum on this graph (1.0 normalised), neighbour
  /// entropy 0 (everyone same community), cross fraction 0 ⇒ composite
  /// = 0.30. With dampening, the broad-but-parochial guard pulls it
  /// further down. Either way the classification must be `ordinary`,
  /// not `transferStation`.
  @Test
  func `giant generic genre is not a fake transfer station`() {
    let neighbourCount = 6
    var nodes = [(genre: "Rock", weight: 1.0)]
    var edges = [(a: String, b: String, weight: Double)]()
    var communities = ["Rock": 0]
    for index in 0 ..< neighbourCount {
      let name = "Rock\(index)"
      nodes.append((genre: name, weight: 0.10))
      edges.append((a: "Rock", b: name, weight: 1.0))
      communities[name] = 0
    }
    let result = GenreMapTransferness.score(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    let kind = result.kindByNode["Rock"] ?? .transferStation
    #expect(
      kind == .ordinary,
      "giant in-community genre classified as \(kind), expected .ordinary",
    )
    let composite = result.compositeByNode["Rock"] ?? 1.0
    #expect(composite < GenreMapTransferness.transferStationThreshold)
    // Dampening must have engaged.
    let dampening = result.inputsByNode["Rock"]?.dampening ?? 1.0
    #expect(
      dampening < 1.0,
      "dampening did not engage (=\(dampening)); guard is not working",
    )
  }

  /// The dual: a genuinely bridging high-weight genre — high library
  /// weight AND high cross-community fraction — must NOT be dampened
  /// into oblivion. The guard is "broad AND parochial", not "broad
  /// alone".
  @Test
  func `dampening leaves a genuinely bridging high-weight genre alone`() {
    var nodes = [(genre: "Hub", weight: 1.0)]
    var edges = [(a: String, b: String, weight: Double)]()
    var communities = ["Hub": 0]
    for index in 0 ..< 4 {
      let name = "Other\(index)"
      nodes.append((genre: name, weight: 0.10))
      edges.append((a: "Hub", b: name, weight: 1.0))
      communities[name] = index + 1 // each neighbour in its own community
    }
    let result = GenreMapTransferness.score(
      nodes: nodes,
      edges: edges,
      communities: communities,
    )
    // The genuinely-bridging hub should NOT be dampened.
    let dampening = result.inputsByNode["Hub"]?.dampening ?? 0
    #expect(dampening == 1.0)
  }

  /// Phase 2 thresholds are 0.20 / 0.45 (recalibrated from the plan's
  /// headline 0.35 / 0.65 because the strand-count slot contributes 0
  /// until Phase 3 ⇒ the composite ceiling is 0.75 instead of 1.0).
  /// Phase 3 will revisit upward once the strand signal lights up.
  @Test
  func `classification: thresholds land at junction and transferStation cuts`() {
    #expect(GenreMapTransferness.classify(composite: 0.0) == .ordinary)
    #expect(GenreMapTransferness.classify(composite: GenreMapTransferness.junctionThreshold - 0.01) == .ordinary)
    #expect(GenreMapTransferness.classify(composite: GenreMapTransferness.junctionThreshold) == .junction)
    #expect(GenreMapTransferness.classify(composite: GenreMapTransferness.transferStationThreshold - 0.01) == .junction)
    #expect(GenreMapTransferness.classify(composite: GenreMapTransferness.transferStationThreshold) == .transferStation)
    #expect(GenreMapTransferness.classify(composite: 1.0) == .transferStation)
  }
}
