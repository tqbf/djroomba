import Foundation

// MARK: - GenreTreeBuilder

/// Pure pipeline that turns the `v7` genre substrate (`genre_node` +
/// `genre_edge_evidence`) + the medium-resolution Louvain partition
/// (γ = 0.85, from the existing builder's substrate) into a `GenreTreeModel`
/// — the trunk-tree the new view binds to (`plans/son-of-genre-map.md`
/// Phase A).
///
/// Phases, in order:
///
/// 1. **Kruskal MST** over `genre_edge_evidence` with edge cost
///    `1 − total_weight` (heavier composite edges shorten the path,
///    same cost function the previous plan's `GenreMapRouting` used for
///    in-graph paths). Reuses the project-local `UnionFind` from
///    `GenreMapLayoutGraph`.
/// 2. **Trunk selection.** One representative per medium-resolution
///    community; cap at k ≤ 7. When the library has > 7 communities,
///    pick the 7 with the largest total community weight (sum of
///    per-genre `weight` of members) — that's the cross-community
///    tie-break. *Within* a community, the per-variant
///    `TrunkSelectionMetric` decides which member wins the trunk slot.
/// 3. **BFS tree from each trunk.** Each non-trunk genre is claimed by
///    the trunk whose MST traversal reaches it first; ties broken by
///    lowest cumulative MST cost from trunk to genre, ultimate
///    tie-break is lexicographic on the trunk genre name (for
///    determinism). The result is a forest of k ≤ 7 trees covering
///    every genre that's MST-reachable from any selected trunk.
///
/// Orphans (genres with no MST path to any selected trunk) shouldn't
/// happen on a connected real-world library — every genre with at
/// least one `genre_edge_evidence` row participates in the MST, and
/// every MST component contributes its own trunk (or a community
/// representative). They're surfaced on the model defensively so the
/// view can render them in a footer if they ever appear.
///
/// Everything is `nonisolated` static + free of mutable globals:
/// deterministic given identical inputs, unit-testable on a fixture
/// without touching SwiftUI, GRDB, or MusicKit.
enum GenreTreeBuilder {

  /// Internal claim state used by the BFS forest. Held in
  /// `claimByGenre[genre]`; the trunk + parent + cost together let the
  /// final pass reconstruct the path back to the trunk and the
  /// subtree shape.
  struct Claim: Equatable, Sendable {
    var trunk: String
    var parent: String?
    var cost: Double
  }

  /// Cap on the number of trunks rendered (`plans/son-of-genre-map.md`).
  /// Larger libraries with > 7 communities surrender the lowest-weight
  /// communities; their members become branches under whichever surviving
  /// trunk's MST claims them first.
  static let trunkCap = 7

  /// Build the full Phase-A pipeline.
  ///
  /// - parameters:
  ///   - nodes: every analysed genre's weight + raw counts. Same shape
  ///     the existing metro builder consumes; the tree builder reads
  ///     only `genre` + `weight`.
  ///   - evidence: canonical-half edges with composite `totalWeight`
  ///     (`0.45·artist + 0.35·album + 0.15·track + 0.05·playlist`).
  ///     Self-loops (`a == b`) and edges referencing genres outside
  ///     `nodes` are dropped silently.
  ///   - communityByGenre: medium-resolution Louvain partition keyed by
  ///     genre. Same `[genre: communityID]` shape the existing
  ///     `GenreMapBuilder` already computes; this builder treats it as
  ///     an input so it doesn't re-run Louvain (the substrate caller
  ///     has it from the same rebuild).
  ///   - metric: per-community trunk-selection variant.
  static func build(
    nodes: [GenreNode],
    evidence: [GenreEdgeEvidence],
    communityByGenre: [String: Int],
    metric: TrunkSelectionMetric,
  ) -> GenreTreeModel {
    guard !nodes.isEmpty else {
      return GenreTreeModel(trunks: [], orphans: [])
    }

    let nodeNames = Set(nodes.map(\.genre))
    let weightByGenre = Dictionary(
      uniqueKeysWithValues: nodes.map { ($0.genre, $0.weight) }
    )

    // 1) Kruskal MST. Edges are sorted ascending by cost (= `1 − weight`),
    // i.e. descending by composite weight, so heavier edges enter the
    // spanning tree first.
    let mstEdges = kruskalMST(
      evidence: evidence,
      nodeNames: nodeNames,
    )

    // 2) Trunk selection per community, capped at `trunkCap`.
    let trunkGenres = selectTrunks(
      nodes: nodes,
      mstEdges: mstEdges,
      communityByGenre: communityByGenre,
      metric: metric,
    )

    // 3) BFS forest. Every non-trunk genre is claimed by the trunk whose
    // MST traversal reaches it cheapest first.
    let (trunks, orphanGenres) = buildForest(
      trunkGenres: trunkGenres,
      mstEdges: mstEdges,
      nodeNames: nodeNames,
      weightByGenre: weightByGenre,
      communityByGenre: communityByGenre,
    )

    let orphans = orphanGenres
      .compactMap { genre -> Genre? in
        guard let weight = weightByGenre[genre] else { return nil }
        return Genre(name: genre, weight: weight)
      }
      .sorted { $0.name < $1.name }

    return GenreTreeModel(trunks: trunks, orphans: orphans)
  }

  /// Kruskal's algorithm over the canonical-half `genre_edge_evidence`
  /// rows. Edge cost = `1 − total_weight`; heavier composite edges sort
  /// first and enter the spanning tree first.
  ///
  /// Deterministic order: ascending cost, then `(genreA, genreB)`
  /// lexicographic. Self-loops + edges touching genres outside
  /// `nodeNames` are dropped.
  static func kruskalMST(
    evidence: [GenreEdgeEvidence],
    nodeNames: Set<String>,
  ) -> [MSTEdge] {
    guard nodeNames.count >= 2 else { return [] }

    let candidates = evidence
      .compactMap { row -> MSTEdge? in
        guard
          row.genreA != row.genreB,
          nodeNames.contains(row.genreA),
          nodeNames.contains(row.genreB)
        else {
          return nil
        }
        return MSTEdge(
          genreA: row.genreA,
          genreB: row.genreB,
          totalWeight: row.totalWeight,
        )
      }
      .sorted { lhs, rhs in
        if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
        if lhs.genreA != rhs.genreA { return lhs.genreA < rhs.genreA }
        return lhs.genreB < rhs.genreB
      }

    var uf = UnionFind(elements: nodeNames)
    var kept = [MSTEdge]()
    kept.reserveCapacity(nodeNames.count - 1)
    for candidate in candidates {
      if uf.union(candidate.genreA, candidate.genreB) {
        kept.append(candidate)
        if kept.count == nodeNames.count - 1 { break }
      }
    }
    return kept
  }

  /// Pick a trunk per community, then cap to `trunkCap` by community
  /// weight (sum of per-genre weights of members). Returns the trunk
  /// genre names in deterministic order (community weight desc, then
  /// community id asc).
  static func selectTrunks(
    nodes: [GenreNode],
    mstEdges: [MSTEdge],
    communityByGenre: [String: Int],
    metric: TrunkSelectionMetric,
  ) -> [String] {
    // Group genres by community. Genres without a community (shouldn't
    // happen on the real library, but defensive) are dropped from trunk
    // consideration; they'll surface as orphans if they're also
    // MST-disconnected from every selected trunk.
    var membersByCommunity = [Int: [String]]()
    for node in nodes {
      guard let community = communityByGenre[node.genre] else { continue }
      membersByCommunity[community, default: []].append(node.genre)
    }
    guard !membersByCommunity.isEmpty else { return [] }

    let weightByGenre = Dictionary(
      uniqueKeysWithValues: nodes.map { ($0.genre, $0.weight) }
    )
    let communityWeights: [Int: Double] = membersByCommunity.mapValues { members in
      members.reduce(0.0) { $0 + (weightByGenre[$1] ?? 0) }
    }

    // Rank communities by total weight desc; on equal weight prefer the
    // smaller community id for determinism.
    let rankedCommunities = membersByCommunity.keys
      .sorted { lhs, rhs in
        let lhsWeight = communityWeights[lhs] ?? 0
        let rhsWeight = communityWeights[rhs] ?? 0
        if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
        return lhs < rhs
      }
    let kept = rankedCommunities.prefix(trunkCap)

    // Per-community trunk pick. Precompute the inputs each metric needs.
    let centralityByGenre = inducedCentralityByCommunity(
      mstEdges: mstEdges,
      membersByCommunity: membersByCommunity,
    )
    let transfernessByGenre = communityTransferness(
      nodes: nodes,
      mstEdges: mstEdges,
      communityByGenre: communityByGenre,
    )

    var trunks = [String]()
    trunks.reserveCapacity(kept.count)
    for community in kept {
      guard let members = membersByCommunity[community], !members.isEmpty else {
        continue
      }
      let trunk = pickTrunk(
        members: members,
        metric: metric,
        weightByGenre: weightByGenre,
        centralityByGenre: centralityByGenre,
        transfernessByGenre: transfernessByGenre,
      )
      trunks.append(trunk)
    }
    return trunks
  }

  /// Pick the trunk inside one community per the chosen metric. Each
  /// branch reads from the right precomputed map; tie-break is always
  /// **lex on genre name** so callers can rely on determinism across
  /// runs even when two members score identically.
  static func pickTrunk(
    members: [String],
    metric: TrunkSelectionMetric,
    weightByGenre: [String: Double],
    centralityByGenre: [String: Double],
    transfernessByGenre: [String: Double],
  ) -> String {
    let scoreByGenre: [String: Double] =
      switch metric {
      case .highestWeight: weightByGenre
      case .highestCentrality: centralityByGenre
      case .highestTransferness: transfernessByGenre
      }

    // Argmax with lexicographic tie-break.
    var best = members[0]
    var bestScore = scoreByGenre[best] ?? 0
    for genre in members.dropFirst() {
      let score = scoreByGenre[genre] ?? 0
      if score > bestScore {
        best = genre
        bestScore = score
      } else if score == bestScore, genre < best {
        best = genre
      }
    }
    return best
  }

  /// Normalised betweenness centrality inside each community's
  /// MST-induced subgraph. Reuses
  /// `GenreMapTransferness.normalisedBetweenness` (Brandes' algorithm),
  /// scoped to MST edges whose endpoints both lie in the community.
  /// Genres in singleton communities score 0 (no induced edges).
  static func inducedCentralityByCommunity(
    mstEdges: [MSTEdge],
    membersByCommunity: [Int: [String]],
  ) -> [String: Double] {
    var out = [String: Double]()
    for (_, members) in membersByCommunity {
      let memberSet = Set(members)
      let inducedEdges = mstEdges
        .filter { memberSet.contains($0.genreA) && memberSet.contains($0.genreB) }
        .map { (a: $0.genreA, b: $0.genreB, weight: $0.totalWeight) }
      let centrality = GenreMapTransferness.normalisedBetweenness(
        nodes: members,
        edges: inducedEdges,
      )
      for (genre, score) in centrality {
        out[genre] = score
      }
    }
    return out
  }

  /// Per-genre transferness score over the *MST* (not the full layout
  /// graph). The metric should still favour members that bridge their
  /// community to others; computing it over MST edges keeps the
  /// builder substrate-self-contained.
  ///
  /// Strand count is intentionally zero (strands retire in this plan);
  /// membership entropy stays zero too (soft community detection still
  /// deferred). The remaining slots (betweenness + neighbour entropy +
  /// cross-community fraction) plus generic-giant dampening do the
  /// work.
  static func communityTransferness(
    nodes: [GenreNode],
    mstEdges: [MSTEdge],
    communityByGenre: [String: Int],
  ) -> [String: Double] {
    let scored = GenreMapTransferness.score(
      nodes: nodes.map { (genre: $0.genre, weight: $0.weight) },
      edges: mstEdges.map { (a: $0.genreA, b: $0.genreB, weight: $0.totalWeight) },
      communities: communityByGenre,
    )
    return scored.compositeByNode
  }

  /// BFS outward from every trunk through the MST. Each non-trunk genre
  /// is claimed by the trunk whose traversal reaches it cheapest first.
  ///
  /// The traversal uses MST cost (`1 − totalWeight`) as the per-edge
  /// step cost; cumulative cost from trunk-to-genre breaks "first
  /// claim" ties. Ultimate tie-break across trunks is lex on the trunk
  /// genre name so the forest is deterministic on hand-crafted
  /// fixtures.
  static func buildForest(
    trunkGenres: [String],
    mstEdges: [MSTEdge],
    nodeNames: Set<String>,
    weightByGenre: [String: Double],
    communityByGenre: [String: Int],
  ) -> (trunks: [GenreTreeTrunk], orphans: [String]) {
    guard !trunkGenres.isEmpty else {
      return ([], Array(nodeNames))
    }

    // MST adjacency: each genre → list of (neighbour, edgeCost).
    var adjacency = [String: [(neighbour: String, cost: Double)]]()
    for edge in mstEdges {
      adjacency[edge.genreA, default: []]
        .append((neighbour: edge.genreB, cost: edge.cost))
      adjacency[edge.genreB, default: []]
        .append((neighbour: edge.genreA, cost: edge.cost))
    }

    // For each genre, hold the best (lowest-cumulative-cost) trunk
    // claim discovered so far + its parent on the path back to that
    // trunk. The BFS layer is the "first claim" round-robin: every
    // trunk explores its depth-d layer before any trunk explores
    // depth-(d+1), so a tie at the same depth genuinely goes to the
    // trunk that *reached* the genre first in BFS order, with
    // cumulative-cost as the secondary tie-break and trunk name as the
    // ultimate tie-break.
    var claimByGenre = [String: Claim]()
    let trunkOrder = trunkGenres.sorted() // lex for tie-break determinism.
    for trunk in trunkOrder {
      claimByGenre[trunk] = Claim(trunk: trunk, parent: nil, cost: 0)
    }

    // Round-robin BFS frontiers, one per trunk.
    var frontiers: [String: [String]] = Dictionary(
      uniqueKeysWithValues: trunkOrder.map { ($0, [$0]) }
    )
    while frontiers.values.contains(where: { !$0.isEmpty }) {
      // Snapshot ordering: process trunks in lex order this step.
      var nextFrontiers = [String: [String]](
        uniqueKeysWithValues: trunkOrder.map { ($0, [String]()) }
      )
      for trunk in trunkOrder {
        guard let layer = frontiers[trunk], !layer.isEmpty else { continue }
        for genre in layer {
          guard
            let parentClaim = claimByGenre[genre],
            parentClaim.trunk == trunk
          else {
            // The genre's claim was rewritten by another trunk that
            // reached it cheaper at the same BFS depth; skip
            // exploring from a now-orphaned claim.
            continue
          }
          let neighbours = adjacency[genre] ?? []
          for step in neighbours {
            let candidateCost = parentClaim.cost + step.cost
            if let existing = claimByGenre[step.neighbour] {
              if
                shouldOverwrite(
                  existing: existing,
                  candidateCost: candidateCost,
                  candidateTrunk: trunk,
                )
              {
                claimByGenre[step.neighbour] = Claim(
                  trunk: trunk,
                  parent: genre,
                  cost: candidateCost,
                )
                nextFrontiers[trunk, default: []].append(step.neighbour)
              }
            } else {
              claimByGenre[step.neighbour] = Claim(
                trunk: trunk,
                parent: genre,
                cost: candidateCost,
              )
              nextFrontiers[trunk, default: []].append(step.neighbour)
            }
          }
        }
      }
      frontiers = nextFrontiers
    }

    // Materialise the forest. Each trunk gets its claimed genres + the
    // parent/child links from `claimByGenre`.
    var childrenByParent = [String: [String]]()
    for (genre, claim) in claimByGenre {
      guard let parent = claim.parent else { continue }
      childrenByParent[parent, default: []].append(genre)
    }
    // Deterministic child order: by per-genre weight desc (heavier first
    // = the heaviest branch fans nearest to the trunk's local "12
    // o'clock"), then lex on genre name.
    for key in childrenByParent.keys {
      childrenByParent[key]?.sort { lhs, rhs in
        let lhsWeight = weightByGenre[lhs] ?? 0
        let rhsWeight = weightByGenre[rhs] ?? 0
        if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
        return lhs < rhs
      }
    }

    var trunks = [GenreTreeTrunk]()
    trunks.reserveCapacity(trunkOrder.count)
    // Surface trunks in trunk-genre-name lex order; the view layer can
    // re-sort by community weight if it wants — the builder commits to
    // a single deterministic order.
    for trunkGenre in trunkOrder {
      guard let trunkWeight = weightByGenre[trunkGenre] else { continue }
      let rootCommunity = communityByGenre[trunkGenre] ?? -1
      let rootGenre = Genre(name: trunkGenre, weight: trunkWeight)
      let root = buildSubtree(
        genre: rootGenre,
        depth: 0,
        childrenByParent: childrenByParent,
        weightByGenre: weightByGenre,
      )
      trunks.append(GenreTreeTrunk(
        root: root,
        communityID: rootCommunity,
      ))
    }

    // Orphans: genres in `nodeNames` with no claim at all (no MST path
    // to any selected trunk — shouldn't happen on a connected library).
    let claimedGenres = Set(claimByGenre.keys)
    let orphanNames = nodeNames.subtracting(claimedGenres).sorted()
    return (trunks, Array(orphanNames))
  }

  /// Recursive subtree assembly. `depth` is surfaced for downstream
  /// consumers (the layout pass uses it to narrow arc width per
  /// recursion level).
  static func buildSubtree(
    genre: Genre,
    depth: Int,
    childrenByParent: [String: [String]],
    weightByGenre: [String: Double],
  ) -> GenreTreeNode {
    let childNames = childrenByParent[genre.name] ?? []
    let children = childNames.compactMap { name -> GenreTreeNode? in
      guard let weight = weightByGenre[name] else { return nil }
      return buildSubtree(
        genre: Genre(name: name, weight: weight),
        depth: depth + 1,
        childrenByParent: childrenByParent,
        weightByGenre: weightByGenre,
      )
    }
    return GenreTreeNode(genre: genre, depth: depth, children: children)
  }

  /// Tie-break policy for "trunk B wants to claim a genre already
  /// claimed by trunk A":
  ///
  /// 1. Cheaper cumulative cost wins outright.
  /// 2. On equal cost, the *trunk that ran first this round* keeps the
  ///    claim (`existing` is the incumbent; the candidate is later in
  ///    lex order ⇒ never wins ties at equal cost). This is encoded
  ///    by `candidateTrunk >= existing.trunk` ⇒ keep.
  ///
  /// Returning `true` means the candidate overwrites; `false` means
  /// the existing claim survives.
  static func shouldOverwrite(
    existing: Claim,
    candidateCost: Double,
    candidateTrunk: String,
  ) -> Bool {
    if candidateCost < existing.cost { return true }
    if candidateCost > existing.cost { return false }
    // Equal cost: lex-smaller trunk name keeps the claim. The trunks
    // are processed in lex order per BFS step, so the existing claim
    // (if it was set this same step) is lex ≤ candidate; never
    // overwrite on equal cost.
    return candidateTrunk < existing.trunk
  }

}
