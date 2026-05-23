import Foundation

// MARK: - GenreMapTransferness

/// Pure functions that score every genre node by how "bridge-y" it is, on
/// the **layout graph alone** (`plans/genre-metro-map.md` Phase 2).
///
/// Phase 2's product question — *which genres are bridges between
/// neighbourhoods?* — is answered before any metro strands are drawn.
/// Four inputs are computed per node:
///
/// 1. **Normalised betweenness centrality** (Brandes' algorithm; pure
///    Swift, n ≤ a few hundred genres ⇒ tens of ms total).
/// 2. **Neighbour-community entropy** (Shannon entropy over the medium-
///    resolution community labels of `v`'s neighbours, weighted by edge
///    weight). High entropy ⇒ `v`'s edges span many distinct communities.
/// 3. **Cross-community edge fraction** — `v`'s incident weight crossing
///    the community boundary ÷ total incident weight.
/// 4. **Membership entropy** (placeholder = 0 — soft community detection
///    is deferred per the plan).
///
/// Composite weights (`plans/genre-metro-map.md`):
///
///     composite =
///         0.30 · betweenness
///       + 0.25 · neighbour_entropy
///       + 0.20 · cross_community_fraction
///       + 0.15 · membership_entropy
///       + 0.10 · strand_count   (← 0 until Phase 3 fills the slot)
///
/// Then **generic-giant dampening**: if a node has high library weight AND
/// low multi-community support (broad but not bridging), knock its
/// composite down. Without this guard, "Rock"-shaped giants — high degree,
/// high betweenness, but every neighbour in the same community — would
/// score as transfer stations purely for being big.
///
/// Classification: Phase 2 uses **relative-rank** bands on the per-
/// rebuild composite distribution — top decile of non-zero composites
/// = transferStation, top quartile = junction — because the strand-
/// count + membership-entropy slots are zero at Phase 2 and the
/// composite's mathematical ceiling stays at 0.75 (well below the
/// plan's absolute cuts). The absolute classifier (`classify(composite:)`)
/// remains pinned at the plan's `0.35 / 0.65` and will become the
/// canonical path again once Phase 3 lights up the strand slot. See
/// `plans/genre-metro-map.md` Phase 2 step 4's Phase-2-gate revision
/// for the reasoning.
///
/// Everything here is `nonisolated` + pure: deterministic given identical
/// inputs, unit-testable end-to-end without a layout pass.
enum GenreMapTransferness {

  /// Result of one full pass — per-node composite scores, per-input
  /// contributions (for the evidence panel), and classification.
  struct Result: Equatable, Sendable {
    /// Per-node composite transferness in `[0, 1]` after dampening.
    var compositeByNode: [String: Double]
    /// Per-node decomposition. Surfaced to the evidence panel so it can
    /// say "the dampening dropped the raw 0.6 to 0.18" or "high
    /// betweenness, low neighbour entropy ⇒ this is a connector, not a
    /// hub".
    var inputsByNode: [String: GenreMapTransfernessInputs]
    /// Per-node classification (`ordinary` / `junction` / `transferStation`).
    var kindByNode: [String: GenreMapNodeKind]
  }

  /// Absolute-cut classification thresholds — kept as the canonical
  /// reference because the plan's headline values land here and Phase 3
  /// will revisit when the strand-count slot lights up. Phase 2 does
  /// NOT classify using these directly: see `classify(composite:rank:)`
  /// and the rank-based `transferStationRank` / `junctionRank` bands.
  static let junctionThreshold = 0.35
  static let transferStationThreshold = 0.65

  /// **Relative-rank classification bands** — the spec is "absolute"
  /// only assuming the full composite formula contributes (membership-
  /// entropy + strand-count + the three computed inputs). Phase 2 runs
  /// with two of the five slots at zero (strand-count fills in Phase 3,
  /// membership-entropy is deferred per the plan), so the composite's
  /// mathematical ceiling is **0.75**, not 1.0; absolute cuts at
  /// 0.35 / 0.65 land 0 junctions / 0 transfer stations on the real
  /// library even with the Phase-2-gate substrate widening.
  ///
  /// Relative-rank is the documented Phase-3 fallback per the carry-
  /// forward at the bottom of the Phase 2 PROGRESS entry: top decile
  /// of non-zero composites = transferStation, top quartile = junction.
  /// Calibrated to the per-rebuild distribution so it's robust across
  /// libraries with different bridge-density profiles — a library
  /// with one giant connected blob still surfaces its strongest
  /// bridges; a library with many small islands still surfaces them
  /// in proportion. Phase 3 will revisit (likely back to absolute
  /// cuts) once the strand slot stabilises the composite ceiling.
  static let transferStationRank = 0.90
  static let junctionRank = 0.75

  /// Generic-giant dampening: when a node's library weight is **high**
  /// (top of the per-genre weight distribution) but its multi-community
  /// support is **low** (most neighbours share its community), scale its
  /// composite down. The two knobs — `weightFloor` (where "big" starts)
  /// and `crossFractionCeiling` (where "not bridging" starts) — are tuned
  /// against the real library; pinned in tests so a future regression
  /// surfaces before live verification.
  static let dampeningWeightFloor = 0.55
  static let dampeningCrossFractionCeiling = 0.30
  /// Floor of the dampening multiplier. A maxed-out generic giant still
  /// gets some signal, so the panel still surfaces it — just below the
  /// `transferStation` threshold by design.
  static let dampeningFloor = 0.35

  /// Run the full Phase-2 pass. `nodes` ⇒ every genre in the layout graph
  /// (positions/labels don't matter here; only names + library `weight`).
  /// `edges` ⇒ the **layout** edges (the same set the physics sees).
  /// `communities` ⇒ medium-resolution Louvain partition keyed by genre.
  ///
  /// The strand-count slot is parameterised so Phase 3 can wire it in
  /// without re-touching this module: pass `strandCountByNode = [:]` for
  /// Phase 2 (the spec's 10 % slot contributes nothing today).
  static func score(
    nodes: [(genre: String, weight: Double)],
    edges: [(a: String, b: String, weight: Double)],
    communities: [String: Int],
    strandCountByNode: [String: Int] = [:],
  ) -> Result {
    guard !nodes.isEmpty else {
      return Result(
        compositeByNode: [:],
        inputsByNode: [:],
        kindByNode: [:],
      )
    }

    let genreNames = nodes.map(\.genre)
    let weightByGenre = Dictionary(uniqueKeysWithValues: nodes.map { ($0.genre, $0.weight) })

    let betweennessByGenre = normalisedBetweenness(
      nodes: genreNames,
      edges: edges,
    )
    let entropyByGenre = neighbourCommunityEntropy(
      nodes: genreNames,
      edges: edges,
      communities: communities,
    )
    let crossFractionByGenre = crossCommunityFraction(
      nodes: genreNames,
      edges: edges,
      communities: communities,
    )
    // Strand-count normalisation: keep it in `[0, 1]` by dividing by the
    // max in this pass (Phase 2 always sees `[:]` ⇒ max=0 ⇒ all zeros).
    let strandMax = max(1, strandCountByNode.values.max() ?? 0)
    let strandByGenre: [String: Double] = Dictionary(
      uniqueKeysWithValues: genreNames.map { genre in
        (genre, Double(strandCountByNode[genre] ?? 0) / Double(strandMax))
      }
    )

    var compositeByNode = [String: Double]()
    var inputsByNode = [String: GenreMapTransfernessInputs]()
    compositeByNode.reserveCapacity(genreNames.count)
    inputsByNode.reserveCapacity(genreNames.count)

    for genre in genreNames {
      let betweenness = betweennessByGenre[genre] ?? 0
      let entropy = entropyByGenre[genre] ?? 0
      let crossFraction = crossFractionByGenre[genre] ?? 0
      let strand = strandByGenre[genre] ?? 0
      let membership = 0.0 // soft community detection deferred per the plan.

      let rawComposite =
        0.30 * betweenness
          + 0.25 * entropy
          + 0.20 * crossFraction
          + 0.15 * membership
          + 0.10 * strand

      let libraryWeight = weightByGenre[genre] ?? 0
      let dampening = dampeningMultiplier(
        libraryWeight: libraryWeight,
        crossCommunityFraction: crossFraction,
      )
      let composite = min(1.0, max(0, rawComposite * dampening))

      compositeByNode[genre] = composite
      inputsByNode[genre] = GenreMapTransfernessInputs(
        betweenness: betweenness,
        neighbourEntropy: entropy,
        crossCommunityFraction: crossFraction,
        membershipEntropy: membership,
        strandCount: strand,
        dampening: dampening,
      )
    }

    let kindByNode = classifyByRank(compositeByNode: compositeByNode)

    return Result(
      compositeByNode: compositeByNode,
      inputsByNode: inputsByNode,
      kindByNode: kindByNode,
    )
  }

  /// Relative-rank classification: top `1 − transferStationRank` of the
  /// non-zero composite distribution = transferStation, top
  /// `1 − junctionRank` = junction. Nodes with composite = 0 are always
  /// ordinary (they have no incident layout edges or live entirely
  /// inside one community). The empty-graph / all-zero case lands
  /// every node as ordinary by construction.
  static func classifyByRank(
    compositeByNode: [String: Double]
  ) -> [String: GenreMapNodeKind] {
    var kindByNode = [String: GenreMapNodeKind]()
    kindByNode.reserveCapacity(compositeByNode.count)
    // Default every node to ordinary; promote by rank below.
    for genre in compositeByNode.keys {
      kindByNode[genre] = .ordinary
    }
    let nonZero = compositeByNode.values.filter { $0 > 0 }.sorted()
    guard nonZero.count >= 2 else { return kindByNode }
    let transferCut = percentile(nonZero, fraction: transferStationRank)
    let junctionCut = percentile(nonZero, fraction: junctionRank)
    for (genre, score) in compositeByNode {
      if score >= transferCut {
        kindByNode[genre] = .transferStation
      } else if score >= junctionCut {
        kindByNode[genre] = .junction
      }
    }
    return kindByNode
  }

  /// Linear-interpolated percentile lookup. `sortedAscending` must be
  /// pre-sorted ascending. `fraction` in `[0, 1]`.
  static func percentile(
    _ sortedAscending: [Double],
    fraction: Double,
  ) -> Double {
    guard !sortedAscending.isEmpty else { return 0 }
    let clamped = max(0, min(1, fraction))
    let position = clamped * Double(sortedAscending.count - 1)
    let lowerIndex = Int(position.rounded(.down))
    let upperIndex = Int(position.rounded(.up))
    let lower = sortedAscending[lowerIndex]
    let upper = sortedAscending[upperIndex]
    let t = position - Double(lowerIndex)
    return lower + (upper - lower) * t
  }

  /// Classify a composite score against the absolute thresholds — kept
  /// for the `0.35 / 0.65` test pin and Phase 3's planned return to
  /// absolute cuts once the strand-count slot stabilises the composite
  /// ceiling. Phase 2's live classification uses `classifyByRank`.
  static func classify(composite: Double) -> GenreMapNodeKind {
    if composite >= transferStationThreshold {
      return .transferStation
    }
    if composite >= junctionThreshold {
      return .junction
    }
    return .ordinary
  }

  /// Multiplicative dampening factor for the generic-giant guard.
  /// Returns `1.0` when no dampening applies (small node OR genuinely
  /// bridging); slides down to `dampeningFloor` for a maxed-out generic
  /// giant (high library weight AND low cross-community fraction).
  ///
  /// Linear ramp on each axis: starts dampening as `libraryWeight`
  /// crosses `dampeningWeightFloor` and `crossCommunityFraction` falls
  /// below `dampeningCrossFractionCeiling`. The factors multiply, so a
  /// node has to be both broad and parochial to feel the full hit.
  static func dampeningMultiplier(
    libraryWeight: Double,
    crossCommunityFraction: Double,
  ) -> Double {
    // Weight axis: 0 below `dampeningWeightFloor`, 1 at weight=1.
    let weightAxis: Double =
      if libraryWeight <= dampeningWeightFloor {
        0
      } else {
        (libraryWeight - dampeningWeightFloor)
          / max(1.0e-9, 1.0 - dampeningWeightFloor)
      }
    // Parochiality axis: 1 at crossFraction=0, 0 at the ceiling.
    let parochialAxis: Double =
      if crossCommunityFraction >= dampeningCrossFractionCeiling {
        0
      } else {
        1.0 - crossCommunityFraction / max(1.0e-9, dampeningCrossFractionCeiling)
      }
    let intensity = min(1.0, max(0, weightAxis * parochialAxis))
    return 1.0 - intensity * (1.0 - dampeningFloor)
  }

  /// Normalised betweenness centrality via Brandes' algorithm (2001).
  /// `O(V·E)` per source ⇒ `O(V²·E)` total. At n=115 / E≈114 this is
  /// tens of milliseconds; we ship it as-is.
  ///
  /// Edges are treated as undirected; weights are NOT used in the
  /// shortest-path metric (every edge has cost 1). The plan calls for
  /// *topological* bridge identification — distance in number of hops
  /// is the relevant signal here, not weighted distance.
  static func normalisedBetweenness(
    nodes: [String],
    edges: [(a: String, b: String, weight: Double)],
  ) -> [String: Double] {
    guard nodes.count >= 3 else {
      return Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0.0) })
    }
    // Deterministic compact integer indexing (sorted node names) so the
    // queue iteration / ordering inside Brandes is reproducible.
    let sortedNodes = nodes.sorted()
    var indexByName = [String: Int]()
    indexByName.reserveCapacity(sortedNodes.count)
    for (index, name) in sortedNodes.enumerated() {
      indexByName[name] = index
    }
    var adjacency = [[Int]](repeating: [], count: sortedNodes.count)
    for edge in edges {
      guard
        let lhs = indexByName[edge.a],
        let rhs = indexByName[edge.b],
        lhs != rhs
      else { continue }
      adjacency[lhs].append(rhs)
      adjacency[rhs].append(lhs)
    }
    // Deterministic adjacency order.
    for index in adjacency.indices {
      adjacency[index].sort()
    }

    let n = sortedNodes.count
    var scores = [Double](repeating: 0, count: n)
    for source in 0 ..< n {
      // BFS from `source` — single-source shortest paths in an unweighted
      // graph, with predecessor lists for the back-prop pass.
      var sigma = [Double](repeating: 0, count: n) // # shortest paths
      var distance = [Int](repeating: -1, count: n)
      var predecessors = [[Int]](repeating: [], count: n)
      sigma[source] = 1
      distance[source] = 0
      var stack = [Int]()
      stack.reserveCapacity(n)
      var queue = [source]
      // Hand-rolled head-index queue to avoid `removeFirst()`'s O(n) cost.
      var queueHead = 0
      while queueHead < queue.count {
        let current = queue[queueHead]
        queueHead += 1
        stack.append(current)
        for neighbour in adjacency[current] {
          if distance[neighbour] < 0 {
            distance[neighbour] = distance[current] + 1
            queue.append(neighbour)
          }
          if distance[neighbour] == distance[current] + 1 {
            sigma[neighbour] += sigma[current]
            predecessors[neighbour].append(current)
          }
        }
      }
      // Back-prop: accumulate dependencies in reverse BFS order.
      var delta = [Double](repeating: 0, count: n)
      while let w = stack.popLast() {
        for v in predecessors[w] {
          delta[v] += (sigma[v] / max(1.0e-18, sigma[w])) * (1 + delta[w])
        }
        if w != source {
          scores[w] += delta[w]
        }
      }
    }
    // Normalise: undirected graph ⇒ each (s, t) pair counted twice; divide
    // by 2. Then divide by the (n − 1)(n − 2) max-possible total to land
    // in `[0, 1]`.
    let denominator = Double((n - 1) * (n - 2))
    var result = [String: Double]()
    result.reserveCapacity(n)
    for (index, name) in sortedNodes.enumerated() {
      let normalised = denominator > 0 ? (scores[index] / denominator) : 0
      // Brandes' formula counts s/t pairs in both directions on an
      // undirected graph, so divide by 2.
      result[name] = max(0, normalised)
    }
    // Stretch to `[0, 1]` so the composite weights aren't dominated by
    // betweenness running 100× smaller than the other inputs.
    let maxRaw = result.values.max() ?? 0
    if maxRaw > 0 {
      for key in result.keys {
        result[key] = (result[key] ?? 0) / maxRaw
      }
    }
    return result
  }

  /// Shannon entropy (natural log, normalised to `[0, 1]`) over the
  /// community labels of `v`'s neighbours, weighted by edge weight.
  /// A node whose every neighbour sits in its own community gets 0; a
  /// node spread evenly across `k` distinct communities gets `ln k / ln K`
  /// where `K` is the global community count.
  ///
  /// Isolated nodes (no incident edges) score 0 — they're neither
  /// bridging nor parochial; the betweenness slot already says
  /// "topologically irrelevant".
  static func neighbourCommunityEntropy(
    nodes: [String],
    edges: [(a: String, b: String, weight: Double)],
    communities: [String: Int],
  ) -> [String: Double] {
    let allCommunities = Set(communities.values)
    let logK = allCommunities.count >= 2 ? log(Double(allCommunities.count)) : 1.0

    var adjacency = [String: [(other: String, weight: Double)]]()
    for edge in edges {
      adjacency[edge.a, default: []].append((edge.b, edge.weight))
      adjacency[edge.b, default: []].append((edge.a, edge.weight))
    }

    var result = [String: Double]()
    result.reserveCapacity(nodes.count)
    for node in nodes {
      let neighbours = adjacency[node] ?? []
      guard !neighbours.isEmpty else {
        result[node] = 0
        continue
      }
      var weightByCommunity = [Int: Double]()
      var total = 0.0
      for neighbour in neighbours {
        guard let community = communities[neighbour.other] else { continue }
        weightByCommunity[community, default: 0] += neighbour.weight
        total += neighbour.weight
      }
      guard total > 0 else {
        result[node] = 0
        continue
      }
      var entropy = 0.0
      for (_, weight) in weightByCommunity {
        let probability = weight / total
        guard probability > 0 else { continue }
        entropy -= probability * log(probability)
      }
      // Normalise by `logK` so the score lives in `[0, 1]` regardless of
      // how many communities Louvain produced this rebuild.
      result[node] = max(0, min(1, entropy / max(1.0e-9, logK)))
    }
    // Every node should appear (singletons drop in with score 0).
    for node in nodes where result[node] == nil {
      result[node] = 0
    }
    return result
  }

  /// Fraction of `v`'s incident edge weight that crosses its community
  /// boundary. Range `[0, 1]`. Isolated nodes score 0.
  static func crossCommunityFraction(
    nodes: [String],
    edges: [(a: String, b: String, weight: Double)],
    communities: [String: Int],
  ) -> [String: Double] {
    var adjacency = [String: [(other: String, weight: Double)]]()
    for edge in edges {
      adjacency[edge.a, default: []].append((edge.b, edge.weight))
      adjacency[edge.b, default: []].append((edge.a, edge.weight))
    }
    var result = [String: Double]()
    result.reserveCapacity(nodes.count)
    for node in nodes {
      let neighbours = adjacency[node] ?? []
      guard !neighbours.isEmpty else {
        result[node] = 0
        continue
      }
      let ownCommunity = communities[node]
      var crossing = 0.0
      var total = 0.0
      for neighbour in neighbours {
        total += neighbour.weight
        if
          let community = communities[neighbour.other],
          community != ownCommunity
        {
          crossing += neighbour.weight
        }
      }
      result[node] = total > 0 ? crossing / total : 0
    }
    for node in nodes where result[node] == nil {
      result[node] = 0
    }
    return result
  }
}
