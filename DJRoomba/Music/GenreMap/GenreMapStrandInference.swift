import Foundation

// MARK: - GenreMapStrandInference

/// Algorithmic metro-strand extraction from the layout graph
/// (`plans/genre-metro-map.md` Phase 3). Pure Swift — no DB, no async,
/// no globals; deterministic given identical inputs.
///
/// Pipeline (each step is its own static function so tests can pin it
/// in isolation):
///
/// 1. **Per-community strands.** For each medium-resolution community,
///    build the induced subgraph, take its maximum spanning tree, and
///    extract **heavy paths** (`length ≥ 3` and per-edge mean weight
///    above an adaptive threshold τ, defined as the overall median
///    edge weight across the layout graph). Side branches off the heavy
///    path are promoted as **branch strands** (same parent id; rendered
///    later as branches). Bounded to 2–4 strands per community by rank.
/// 2. **Cross-community bridge strands.** Build the community graph
///    (one super-edge per community pair, weighted by the heaviest
///    crossing edge between the two communities). The strongest inter-
///    community pairs become bridge strands; the path is recovered via
///    weighted shortest path through the original layout graph with the
///    cost function `1 − total_weight`.
/// 3. **Rank + cull.** Score every strand by
///    `node-weight-sum + length + edge-support + transfer-station count`;
///    keep the top 5–12. Cull strand pairs with member-Jaccard ≥ 0.6;
///    the survivor absorbs the loser as a branch (`isBranch=true`,
///    `parentStrandID` set).
/// 4. **Labels.** Tokenise member-genre names, drop junk tokens
///    (`misc`, `other`, `genre`, …), TF-IDF across all strands; pick top
///    2–4 tokens. Also surface 1–2 representative high-centrality genre
///    names (highest `weight × transferness`-derived score).
///
/// Everything is `nonisolated` + pure: deterministic, unit-testable
/// end-to-end on a fixture without a layout pass.
enum GenreMapStrandInference {

  // MARK: Internal

  struct Edge: Equatable, Sendable {
    var a: String
    var b: String
    var weight: Double
  }

  struct InputNode: Equatable, Sendable {
    var genre: String
    /// Library weight (`[0, 1]`). Drives strand rank + the
    /// "representative genre" surface in `Strand.representativeGenres`.
    var weight: Double
    /// Composite transferness (`[0, 1]`). Used to bias representative-
    /// genre selection toward genuinely-bridging members.
    var transferness: Double
    var communityID: Int
  }

  /// Output: every strand the renderer should draw.
  struct Strand: Equatable, Sendable, Identifiable {
    /// Small stable integer (post rank + cull). Branches share the
    /// parent strand's id surface visually but have their own row here.
    var id: Int
    /// TF-IDF placename ⇒ "Acoustic · Folk · Roots" style. Default
    /// render does not show this — surface on hover only.
    var label: String
    /// The top-k TF-IDF tokens, in rank order.
    var tokens: [String]
    /// 1–2 high-centrality member genre names (verbatim, not tokens).
    var representativeGenres: [String]
    /// Sorted member genre names — the strand's full station set.
    var memberGenres: [String]
    /// The ordered path through the layout graph the renderer draws as
    /// a spline. For a community heavy-path: the main heavy path. For a
    /// branch: the branch's own short path (parent + branch nodes).
    /// For a bridge: the weighted shortest path between two communities.
    var pathStations: [String]
    /// Palette colour index — modulo a small distinguishable hue set.
    var colourID: Int
    /// `true` ⇒ this strand was either promoted from a side branch of a
    /// parent heavy path, or culled-in to a survivor at rank time. The
    /// renderer can fade branches or draw them at a slimmer weight.
    var isBranch: Bool
    /// Parent strand id when `isBranch == true`; `nil` for main strands.
    var parentStrandID: Int?
  }

  /// One full pass — communities → strands. `transfernessByNode` is
  /// optional: when present, transfer-station counts contribute to the
  /// strand rank and the rep-genre surfacing prefers genuine bridges.
  struct Configuration: Sendable {
    /// Heavy-path length floor — paths shorter than this aren't strands
    /// (the spec's `length ≥ 3`). Lower bound is 3 stations end-to-end.
    var minPathLength = 3
    /// Per-community cap on main strands (the spec's "bounded 2–4").
    var maxStrandsPerCommunity = 4
    /// Total strand-count cap after rank-and-cull (the spec's
    /// "5–12 at default zoom"). With the user's "scrolling is fine"
    /// directive the upper bound is honoured; we cap at 12.
    var maxStrandsAfterCull = 12
    /// Member-Jaccard ≥ this ⇒ cull (loser absorbed as a branch).
    var cullJaccard = 0.6
    /// Top-k TF-IDF tokens kept per strand (the spec's "top 2–4").
    var maxLabelTokens = 4
    /// Min `length + 1` of a branch path (a branch must have at least
    /// one off-spine station; lower = noisy).
    var minBranchLength = 2
    /// Branch promotion ceiling per community heavy path.
    var maxBranchesPerStrand = 2
  }

  struct HeavyPath: Equatable {
    var path: [String]
    var edgeWeights: [Double]
  }

  struct Branch: Equatable {
    var path: [String]
    var edgeWeights: [Double]
  }

  /// Pre-rank strand candidate (collected from per-community and bridge
  /// passes); the rank+cull step folds these into final `Strand`s.
  struct Candidate: Equatable, Sendable {
    var memberGenres: [String]
    var pathStations: [String]
    var isBranch: Bool
    var parentPath: [String]?
    var communityID: Int
    var edgeWeights: [Double]
  }

  /// **Junk-token blacklist** (lowercased; deliberately small so a tag
  /// like `Indie` survives and informs the TF-IDF). Matches the plan's
  /// "drop `misc`, `other`, `genre`, `music`, …".
  static let junkTokens: Set = [
    "misc",
    "other",
    "genre",
    "music",
    "various",
    "general",
    "etc",
    "unknown",
    "untitled",
    "alt",
    "rock",
    "pop",
    "the",
    "and",
    "of",
    "a",
    "&",
    "/",
    "-",
  ]

  /// Run the full Phase-3 pass.
  static func infer(
    nodes: [InputNode],
    edges: [Edge],
    configuration: Configuration = Configuration(),
  ) -> [Strand] {
    guard !nodes.isEmpty, !edges.isEmpty else { return [] }

    // Index by name + community for cheap lookups.
    let nodeByGenre = Dictionary(uniqueKeysWithValues: nodes.map { ($0.genre, $0) })
    var nodesByCommunity = [Int: [InputNode]]()
    for node in nodes {
      nodesByCommunity[node.communityID, default: []].append(node)
    }

    // Adjacency over the full layout graph (used by both per-community
    // heavy-path extraction and the cross-community bridge path).
    let adjacency = adjacency(from: edges)

    // Adaptive τ: overall median edge weight. A heavy path's per-edge
    // mean weight must clear τ to be kept. Cheap O(E log E).
    let weights = edges.map(\.weight).sorted()
    let tau = weights.isEmpty ? 0 : weights[weights.count / 2]

    // 1) Per-community strands.
    var rawStrands = [Candidate]()
    for communityID in nodesByCommunity.keys.sorted() {
      let members = (nodesByCommunity[communityID] ?? [])
        .sorted { lhs, rhs in
          if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
          return lhs.genre < rhs.genre
        }
      let memberNames = Set(members.map(\.genre))
      guard memberNames.count >= configuration.minPathLength else { continue }
      let inducedEdges = edges.filter {
        memberNames.contains($0.a) && memberNames.contains($0.b)
      }
      guard !inducedEdges.isEmpty else { continue }
      // Induced MST (max spanning tree) over the community.
      let mst = maximumSpanningTree(nodes: memberNames, edges: inducedEdges)
      // Extract heavy paths (length ≥ minPathLength, mean weight ≥ τ).
      let heavyPaths = heavyPathsInTree(
        tree: mst,
        nodes: memberNames,
        minLength: configuration.minPathLength,
        meanWeightFloor: tau,
        cap: configuration.maxStrandsPerCommunity,
      )
      for heavy in heavyPaths {
        rawStrands.append(Candidate(
          memberGenres: heavy.path,
          pathStations: heavy.path,
          isBranch: false,
          parentPath: nil,
          communityID: communityID,
          edgeWeights: heavy.edgeWeights,
        ))
        // Promote up to N side branches off this heavy path.
        let branches = sideBranches(
          tree: mst,
          spine: heavy.path,
          memberNames: memberNames,
          minLength: configuration.minBranchLength,
          cap: configuration.maxBranchesPerStrand,
        )
        for branch in branches {
          rawStrands.append(Candidate(
            memberGenres: branch.path,
            pathStations: branch.path,
            isBranch: true,
            parentPath: heavy.path,
            communityID: communityID,
            edgeWeights: branch.edgeWeights,
          ))
        }
      }
    }

    // 2) Cross-community bridge strands. Build the community super-graph
    // weighted by the heaviest crossing edge per community pair; recover
    // each strong pair's strongest path through the original layout
    // graph (weighted shortest path with cost `1 − weight`).
    let bridgeCandidates = bridgeStrands(
      nodes: nodes,
      edges: edges,
      adjacency: adjacency,
      configuration: configuration,
    )
    rawStrands.append(contentsOf: bridgeCandidates)

    // 3) Rank + cull. Score is
    //   node-weight-sum + length + edge-support + transfer-station count.
    let scoredAll = rawStrands.map { candidate in
      ScoredCandidate(
        candidate: candidate,
        score: rankScore(candidate: candidate, nodeByGenre: nodeByGenre),
      )
    }
    .sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      // Deterministic tie-break by joined member name.
      return lhs.candidate.memberGenres.joined(separator: ",")
        < rhs.candidate.memberGenres.joined(separator: ",")
    }
    // Member-Jaccard cull: walk in score order, keep a candidate when
    // its member set's Jaccard against every already-kept candidate is
    // below `cullJaccard`. Otherwise absorb as a branch under the
    // strongest already-kept survivor.
    var survivors = [ScoredCandidate]()
    var absorbedAsBranchOf = [Int: Int]() // raw index ⇒ survivor index
    for (rawIndex, scored) in scoredAll.enumerated() {
      let here = Set(scored.candidate.memberGenres)
      var swallowed: Int?
      for (survivorIndex, survivor) in survivors.enumerated() {
        let other = Set(survivor.candidate.memberGenres)
        let jaccard = memberJaccard(here, other)
        if jaccard >= configuration.cullJaccard {
          swallowed = survivorIndex
          break
        }
      }
      if let swallowed {
        absorbedAsBranchOf[rawIndex] = swallowed
      } else {
        if survivors.count < configuration.maxStrandsAfterCull {
          survivors.append(scored)
        } else {
          // Past the cap — only kept survivors persist; the rest fall.
        }
      }
    }
    // 4) Assemble final strands (main + promoted branches), assigning
    // ids 0… and a palette colour per main strand. Branches inherit the
    // parent's id surface via `parentStrandID`.
    var strands = [Strand]()
    var idByCandidateIndex = [Int: Int]()
    for (survivorIndex, scored) in survivors.enumerated() {
      let id = survivorIndex
      idByCandidateIndex[survivorIndex] = id
      let label = "" // backfilled below by TF-IDF after every survivor is known
      let candidate = scored.candidate
      strands.append(Strand(
        id: id,
        label: label,
        tokens: [],
        representativeGenres: representativeGenres(
          members: candidate.memberGenres,
          nodeByGenre: nodeByGenre,
        ),
        memberGenres: candidate.memberGenres.sorted(),
        pathStations: candidate.pathStations,
        colourID: id,
        isBranch: false,
        parentStrandID: nil,
      ))
    }
    // Promoted branches (from sideBranches at extraction time) — every
    // raw candidate that is `isBranch=true` AND survived (wasn't culled)
    // belongs in the output as a branch strand of its in-rank survivor.
    // Note: a side-branch only enters survivors if its score made the
    // top-N AND it didn't culp-absorb to a non-parent survivor. The
    // simpler shape Phase 3 ships: side-branches that survive the cull
    // become branch strands of the survivor that absorbed them.
    for (rawIndex, swallowedSurvivorIndex) in absorbedAsBranchOf {
      let candidate = scoredAll[rawIndex].candidate
      // Only emit if this raw candidate carries genuine extra stations
      // (i.e. it has at least one member the survivor doesn't). Pure
      // duplicates (Jaccard=1.0) are silently dropped — adding them as
      // branches would render an identical spline on top.
      let survivorMembers = Set(survivors[swallowedSurvivorIndex].candidate.memberGenres)
      let extras = candidate.memberGenres.filter { !survivorMembers.contains($0) }
      guard !extras.isEmpty else { continue }
      let branchID = strands.count
      strands.append(Strand(
        id: branchID,
        label: "",
        tokens: [],
        representativeGenres: representativeGenres(
          members: candidate.memberGenres,
          nodeByGenre: nodeByGenre,
        ),
        memberGenres: candidate.memberGenres.sorted(),
        pathStations: candidate.pathStations,
        colourID: swallowedSurvivorIndex, // share the parent's hue
        isBranch: true,
        parentStrandID: swallowedSurvivorIndex,
      ))
    }

    // 5) TF-IDF labels across the strand set (main strands form the
    // corpus; branches inherit their parent's label).
    let labels = tfidfLabels(
      strands: strands,
      maxTokens: configuration.maxLabelTokens,
    )
    for index in strands.indices {
      if let label = labels[strands[index].id] {
        strands[index].label = label.0
        strands[index].tokens = label.1
      } else if
        let parent = strands[index].parentStrandID,
        let parentLabel = labels[parent]
      {
        strands[index].label = parentLabel.0
        strands[index].tokens = parentLabel.1
      }
    }
    return strands
  }

  /// Phase 3 step 5: how many strands serve each genre? Used by the
  /// transferness recompute (the 10 % `strand_count` slot).
  /// Branches contribute too — a genre on a branch is still "served".
  static func strandCountByNode(
    strands: [Strand]
  ) -> [String: Int] {
    var counts = [String: Int]()
    for strand in strands {
      // De-dupe inside one strand (a strand member is counted once per
      // strand even if its station appears twice in the path — defensive;
      // the path shouldn't repeat in practice).
      let seen = Set(strand.memberGenres)
      for member in seen {
        counts[member, default: 0] += 1
      }
    }
    return counts
  }

  /// Maximum spanning tree (Kruskal, max weight) over the candidates.
  /// `nodes` ⇒ membership set; only edges with both endpoints inside
  /// are considered. Deterministic tie-break by `(a, b)` name order.
  static func maximumSpanningTree(
    nodes: Set<String>,
    edges: [Edge],
  ) -> [Edge] {
    guard nodes.count >= 2 else { return [] }
    let sorted = edges.sorted { lhs, rhs in
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      if lhs.a != rhs.a { return lhs.a < rhs.a }
      return lhs.b < rhs.b
    }
    var uf = UnionFind(elements: nodes)
    var out = [Edge]()
    out.reserveCapacity(nodes.count - 1)
    for edge in sorted {
      guard nodes.contains(edge.a), nodes.contains(edge.b) else { continue }
      if uf.union(edge.a, edge.b) {
        out.append(edge)
        if out.count == nodes.count - 1 { break }
      }
    }
    return out
  }

  /// Extract up to `cap` heavy paths from a tree (max-weight spanning
  /// tree of one community). A path is "heavy" when:
  /// - length (# stations) ≥ `minLength`,
  /// - per-edge mean weight ≥ `meanWeightFloor`,
  /// - the path is a maximal heavy chain — extending in either direction
  ///   would force a station already on another extracted path.
  ///
  /// Strategy: iterate; each iteration find the heaviest leaf-to-leaf
  /// path in the remaining (unconsumed) tree edges (the tree diameter
  /// by weight), accept it if it qualifies, then remove its edges from
  /// consideration. Repeat until no qualifying path remains or cap hit.
  static func heavyPathsInTree(
    tree: [Edge],
    nodes: Set<String>,
    minLength: Int,
    meanWeightFloor: Double,
    cap: Int,
  ) -> [HeavyPath] {
    guard cap > 0, tree.count >= minLength - 1 else { return [] }
    var remaining = tree
    var out = [HeavyPath]()
    while out.count < cap, !remaining.isEmpty {
      let diameter = weightedDiameter(nodes: nodes, edges: remaining)
      guard !diameter.path.isEmpty else { break }
      let mean = diameter.edgeWeights.isEmpty
        ? 0
        : diameter.edgeWeights.reduce(0, +) / Double(diameter.edgeWeights.count)
      let isQualifying = diameter.path.count >= minLength && mean >= meanWeightFloor
      guard isQualifying else { break }
      out.append(diameter)
      // Remove the consumed edges from `remaining` so the next iteration
      // doesn't overlap this heavy path.
      let consumed = Set(diameter.edgeWeights.indices.compactMap { index -> EdgeKey? in
        let lhs = diameter.path[index]
        let rhs = diameter.path[index + 1]
        return EdgeKey(a: min(lhs, rhs), b: max(lhs, rhs))
      })
      remaining = remaining.filter {
        let key = EdgeKey(a: min($0.a, $0.b), b: max($0.a, $0.b))
        return !consumed.contains(key)
      }
    }
    return out
  }

  /// Weighted diameter of a tree: the longest leaf-to-leaf path by edge
  /// weight sum. Two BFS-style passes (standard tree-diameter trick),
  /// but ranking by **summed weight** instead of hop count. Heavy paths
  /// in a Kruskal-max-weight tree are the visually-coherent corridors
  /// the plan calls "strands".
  static func weightedDiameter(
    nodes: Set<String>,
    edges: [Edge],
  ) -> HeavyPath {
    guard !nodes.isEmpty, !edges.isEmpty else {
      return HeavyPath(path: [], edgeWeights: [])
    }
    var adjacency = [String: [(other: String, weight: Double)]]()
    for edge in edges {
      adjacency[edge.a, default: []].append((edge.b, edge.weight))
      adjacency[edge.b, default: []].append((edge.a, edge.weight))
    }
    for key in adjacency.keys {
      adjacency[key]?.sort { lhs, rhs in
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.other < rhs.other
      }
    }
    // Start from any node in the largest connected component of `edges`
    // (deterministic pick = the alphabetically-first node with edges).
    guard let start = adjacency.keys.sorted().first else {
      return HeavyPath(path: [], edgeWeights: [])
    }
    let (farFromStart, _) = bfsFarthest(from: start, adjacency: adjacency)
    let (farFromFar, parents) = bfsFarthest(from: farFromStart, adjacency: adjacency)
    // Reconstruct the path. `parents[here]` is `Optional<(parent, weight)>?`
    // — flatten the double-optional with `flatMap { $0 }`.
    var pathRev = [String]()
    var weightRev = [Double]()
    var current: String? = farFromFar
    while let here = current {
      pathRev.append(here)
      if let parentEdge = parents[here].flatMap({ $0 }) {
        weightRev.append(parentEdge.weight)
        current = parentEdge.parent
      } else {
        current = nil
      }
    }
    let path = Array(pathRev.reversed())
    let weights = Array(weightRev.reversed())
    return HeavyPath(path: path, edgeWeights: weights)
  }

  /// Side branches off a heavy-path spine. Each branch is a maximal
  /// chain of tree edges that *starts at a spine node* and walks off
  /// the spine. Branches are returned sorted by total weight desc; up
  /// to `cap` are kept. Branches stay short (the spec frames them as
  /// "branches from the main path", not parallel strands).
  static func sideBranches(
    tree: [Edge],
    spine: [String],
    memberNames: Set<String>,
    minLength: Int,
    cap: Int,
  ) -> [Branch] {
    guard cap > 0, spine.count >= 2 else { return [] }
    let spineSet = Set(spine)
    // Adjacency over the tree.
    var adjacency = [String: [(other: String, weight: Double)]]()
    for edge in tree {
      adjacency[edge.a, default: []].append((edge.b, edge.weight))
      adjacency[edge.b, default: []].append((edge.a, edge.weight))
    }
    for key in adjacency.keys {
      adjacency[key]?.sort { lhs, rhs in
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.other < rhs.other
      }
    }
    // For every spine node, BFS into off-spine neighbours; the result is
    // the heaviest path walking away from the spine through tree edges
    // that don't touch the spine again.
    var branches = [Branch]()
    for anchor in spine {
      let neighbours = adjacency[anchor] ?? []
      for (next, weight) in neighbours where !spineSet.contains(next) {
        // BFS from `next`, restricted to non-spine + member nodes,
        // tracking the heaviest leaf-to-anchor chain.
        var visited: Set<String> = [next]
        var frontier: [(node: String, parent: String?, weight: Double?)] = [
          (next, nil, nil)
        ]
        var parents = [String: (parent: String, weight: Double)]()
        var farthest = next
        var farthestSum = 0.0
        var cumulative: [String: Double] = [next: 0]
        while let (node, _, _) = frontier.first {
          frontier.removeFirst()
          for (other, edgeWeight) in adjacency[node] ?? []
            where !spineSet.contains(other) && !visited.contains(other)
            && memberNames.contains(other)
          {
            visited.insert(other)
            parents[other] = (node, edgeWeight)
            let summed = (cumulative[node] ?? 0) + edgeWeight
            cumulative[other] = summed
            frontier.append((other, node, edgeWeight))
            if summed > farthestSum {
              farthestSum = summed
              farthest = other
            }
          }
        }
        // Build the path: anchor → next → … → farthest.
        var revNodes = [farthest]
        var revWeights = [Double]()
        var current = farthest
        while let prev = parents[current] {
          revNodes.append(prev.parent)
          revWeights.append(prev.weight)
          current = prev.parent
        }
        // Add the anchor edge.
        revNodes.append(anchor)
        revWeights.append(weight)
        let nodesOrdered = Array(revNodes.reversed())
        let weightsOrdered = Array(revWeights.reversed())
        // `length = # stations`. Anchor + next is length 2 ⇒ minBranch=2.
        if nodesOrdered.count >= minLength {
          branches.append(Branch(path: nodesOrdered, edgeWeights: weightsOrdered))
        }
      }
    }
    // Rank by total branch weight desc; deterministic tie-break by
    // joined node names.
    let ranked = branches.sorted { lhs, rhs in
      let lhsWeight = lhs.edgeWeights.reduce(0, +)
      let rhsWeight = rhs.edgeWeights.reduce(0, +)
      if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
      return lhs.path.joined(separator: ",") < rhs.path.joined(separator: ",")
    }
    return Array(ranked.prefix(cap))
  }

  /// Cross-community bridge strands. Build the community super-graph
  /// keyed by the heaviest inter-community edge per pair (the substrate
  /// widening already admitted these into the layout graph at the
  /// Phase-2 gate; here we treat them as the seeds for bridge paths).
  /// Rank pairs by their heaviest edge weight; for each top pair,
  /// recover the weighted shortest path through the original layout
  /// graph via Dijkstra with cost `1 − weight` (so heavier real edges
  /// shorten the path).
  static func bridgeStrands(
    nodes: [InputNode],
    edges: [Edge],
    adjacency: [String: [(other: String, weight: Double)]],
    configuration: Configuration,
  ) -> [Candidate] {
    let communityByGenre = Dictionary(uniqueKeysWithValues: nodes.map { ($0.genre, $0.communityID) })
    // Strongest crossing per community pair.
    var bestByPair = [PairKey: Edge]()
    for edge in edges {
      guard
        let cA = communityByGenre[edge.a],
        let cB = communityByGenre[edge.b],
        cA != cB
      else { continue }
      let key = PairKey(lo: min(cA, cB), hi: max(cA, cB))
      if let current = bestByPair[key], edge.weight <= current.weight { continue }
      bestByPair[key] = edge
    }
    let topPairs = bestByPair.values
      .sorted { lhs, rhs in
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        if lhs.a != rhs.a { return lhs.a < rhs.a }
        return lhs.b < rhs.b
      }
      // Allow more bridge candidates than the global cap so rank+cull
      // can choose freely after main per-community strands compete.
      .prefix(configuration.maxStrandsAfterCull * 2)
    var out = [Candidate]()
    for seed in topPairs {
      // Path from `seed.a` to `seed.b` minimising sum(1 − weight) so
      // heavy edges shorten the path. Length must be ≥ minPathLength.
      guard
        let path = weightedShortestPath(
          from: seed.a,
          to: seed.b,
          adjacency: adjacency,
        ), path.nodes.count >= configuration.minPathLength
      else { continue }
      out.append(Candidate(
        memberGenres: path.nodes,
        pathStations: path.nodes,
        isBranch: false,
        parentPath: nil,
        communityID: -1, // marker: bridge strand spans communities
        edgeWeights: path.edgeWeights,
      ))
    }
    return out
  }

  /// Weighted shortest path with cost `1 − weight` per edge; resolves
  /// to the strongest path between endpoints under that cost. Returns
  /// `nil` when disconnected.
  static func weightedShortestPath(
    from source: String,
    to target: String,
    adjacency: [String: [(other: String, weight: Double)]],
  ) -> (nodes: [String], edgeWeights: [Double])? {
    guard adjacency[source] != nil, adjacency[target] != nil else { return nil }
    // Dijkstra over `1 − weight`. Weights are in [0, 1] so all costs are
    // non-negative. Bounded scale (V≤a few hundred) ⇒ a simple priority
    // queue via repeated linear scan is fine.
    var distance = [String: Double]()
    var parent = [String: (parent: String, weight: Double)]()
    var pending = Set<String>()
    for node in adjacency.keys {
      distance[node] = .infinity
      pending.insert(node)
    }
    distance[source] = 0
    while !pending.isEmpty {
      // Pick the pending node with the smallest distance.
      var current: String?
      var bestDistance = Double.infinity
      for candidate in pending {
        let here = distance[candidate] ?? .infinity
        if here < bestDistance {
          bestDistance = here
          current = candidate
        } else if here == bestDistance, let pick = current, candidate < pick {
          current = candidate
        }
      }
      guard let here = current else { break }
      if here == target { break }
      pending.remove(here)
      if bestDistance.isInfinite { break }
      for (other, weight) in adjacency[here] ?? [] where pending.contains(other) {
        let edgeCost = 1.0 - weight
        let alt = bestDistance + edgeCost
        if alt < (distance[other] ?? .infinity) {
          distance[other] = alt
          parent[other] = (here, weight)
        }
      }
    }
    guard (distance[target] ?? .infinity) < .infinity else { return nil }
    // Reconstruct.
    var revNodes = [target]
    var revWeights = [Double]()
    var current = target
    while let parentEdge = parent[current] {
      revWeights.append(parentEdge.weight)
      revNodes.append(parentEdge.parent)
      current = parentEdge.parent
      if current == source { break }
    }
    guard revNodes.last == source else { return nil }
    return (Array(revNodes.reversed()), Array(revWeights.reversed()))
  }

  /// Member-set Jaccard. Identical sets ⇒ 1.0; disjoint ⇒ 0.0.
  static func memberJaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
    if lhs.isEmpty, rhs.isEmpty { return 1.0 }
    let intersection = lhs.intersection(rhs).count
    let union = lhs.union(rhs).count
    return union > 0 ? Double(intersection) / Double(union) : 0
  }

  /// Tokenise + TF-IDF a corpus of strands. Returns
  /// `[strand.id: (label, tokens)]`. Tokens come from member-genre
  /// names, lowercased, split on whitespace + slashes + dashes, with
  /// the junk blacklist filtered out. Stable across rebuilds for
  /// identical inputs (Swift `Dictionary` iteration is not stable, so
  /// the function sorts the strand ids before iterating).
  static func tfidfLabels(
    strands: [Strand],
    maxTokens: Int,
  ) -> [Int: (String, [String])] {
    // Tokenise per strand (de-dupe inside a strand).
    var tokensByStrand = [Int: [String]]()
    var documentFrequency = [String: Int]()
    let mains = strands.filter { !$0.isBranch }
    for strand in mains.sorted(by: { $0.id < $1.id }) {
      var seen = Set<String>()
      for member in strand.memberGenres {
        for token in tokenise(member) {
          if seen.insert(token).inserted {
            documentFrequency[token, default: 0] += 1
          }
        }
      }
      tokensByStrand[strand.id] = Array(seen).sorted()
    }
    // TF-IDF + top-k. With small corpora (a handful of strands), the
    // "log(N/df)" denominator dominates; a token unique to one strand
    // gets the strongest score. Stable; deterministic.
    let documentCount = max(1, mains.count)
    var labels = [Int: (String, [String])]()
    for (strandID, tokens) in tokensByStrand {
      let strand = mains.first { $0.id == strandID }
      let totalWords = strand?.memberGenres
        .flatMap { tokenise($0) }
        .count ?? 0
      // Per-token raw term frequency across the strand's member names.
      var termFrequency = [String: Int]()
      for member in strand?.memberGenres ?? [] {
        for token in tokenise(member) {
          termFrequency[token, default: 0] += 1
        }
      }
      let scored = tokens.map { token -> (token: String, score: Double) in
        let tf = totalWords > 0
          ? Double(termFrequency[token] ?? 0) / Double(totalWords)
          : 0
        let df = max(1, documentFrequency[token] ?? 0)
        let idf = log(Double(documentCount + 1) / Double(df))
        return (token, tf * idf)
      }
      let topTokens = scored
        .sorted { lhs, rhs in
          if lhs.score != rhs.score { return lhs.score > rhs.score }
          return lhs.token < rhs.token
        }
        .prefix(maxTokens)
        .map(\.token)
      let label = topTokens
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " · ")
      labels[strandID] = (label, Array(topTokens))
    }
    return labels
  }

  /// Lowercase + split on whitespace / `-` / `/` / `&` / `,`; drop
  /// junk tokens; drop tokens of length 1 (a stray glyph). Stable.
  static func tokenise(_ text: String) -> [String] {
    let separators = CharacterSet(charactersIn: " /-&,")
    return text
      .lowercased()
      .components(separatedBy: separators)
      .compactMap { raw -> String? in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
          !trimmed.isEmpty,
          trimmed.count >= 2,
          !junkTokens.contains(trimmed)
        else { return nil }
        return trimmed
      }
  }

  // MARK: Private

  private struct ScoredCandidate {
    var candidate: Candidate
    var score: Double
  }

  private struct EdgeKey: Hashable {
    var a: String
    var b: String
  }

  private struct PairKey: Hashable {
    var lo: Int
    var hi: Int
  }

  /// Adjacency map from edges; values sorted desc by weight then by
  /// neighbour name for deterministic traversal.
  private static func adjacency(
    from edges: [Edge]
  ) -> [String: [(other: String, weight: Double)]] {
    var adjacency = [String: [(other: String, weight: Double)]]()
    for edge in edges {
      adjacency[edge.a, default: []].append((edge.b, edge.weight))
      adjacency[edge.b, default: []].append((edge.a, edge.weight))
    }
    for key in adjacency.keys {
      adjacency[key]?.sort { lhs, rhs in
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.other < rhs.other
      }
    }
    return adjacency
  }

  /// BFS from `source`; returns `(farthestNode, parents)` where the
  /// farthest is by **summed edge weight**, not hop count. Used by the
  /// weighted tree-diameter pass.
  private static func bfsFarthest(
    from source: String,
    adjacency: [String: [(other: String, weight: Double)]],
  ) -> (String, [String: (parent: String, weight: Double)?]) {
    var visited: Set<String> = [source]
    var parents = [String: (parent: String, weight: Double)?]()
    parents[source] = nil
    var cumulative = [String: Double]()
    cumulative[source] = 0
    var queue = [source]
    var queueHead = 0
    var farthest = source
    var farthestWeight = 0.0
    while queueHead < queue.count {
      let here = queue[queueHead]
      queueHead += 1
      for (other, weight) in adjacency[here] ?? [] where !visited.contains(other) {
        visited.insert(other)
        parents[other] = (here, weight)
        let summed = (cumulative[here] ?? 0) + weight
        cumulative[other] = summed
        queue.append(other)
        if summed > farthestWeight {
          farthestWeight = summed
          farthest = other
        }
      }
    }
    return (farthest, parents)
  }

  /// Score a strand candidate for rank+cull:
  ///   `node-weight-sum + length-normalised + edge-support + transfer-stations`.
  /// Branches lose a little so heavy mains outrank them.
  private static func rankScore(
    candidate: Candidate,
    nodeByGenre: [String: InputNode],
  ) -> Double {
    let nodeWeightSum = candidate.memberGenres
      .reduce(0.0) { $0 + (nodeByGenre[$1]?.weight ?? 0) }
    let lengthScore = Double(candidate.memberGenres.count)
    let edgeSupport = candidate.edgeWeights.reduce(0, +)
    // Transfer-station count along the path — proxied by transferness ≥
    // the rank classifier's lower bound (junctionRank). Pure read; no
    // store coupling.
    let transferStationCount = candidate.memberGenres
      .compactMap { nodeByGenre[$0]?.transferness }
      .count(where: { $0 >= 0.5 }) // soft floor; the live classifier is per-rebuild

    let branchPenalty = candidate.isBranch ? 0.5 : 1.0
    return (nodeWeightSum + 0.5 * lengthScore + edgeSupport + Double(transferStationCount))
      * branchPenalty
  }

  /// Pick 1–2 high-centrality representative genres: the highest
  /// `weight + 0.5·transferness`-scored members. Deterministic
  /// tie-break by name.
  private static func representativeGenres(
    members: [String],
    nodeByGenre: [String: InputNode],
  ) -> [String] {
    let scored = members.compactMap { genre -> (String, Double)? in
      guard let node = nodeByGenre[genre] else { return nil }
      return (genre, node.weight + 0.5 * node.transferness)
    }
    .sorted { lhs, rhs in
      if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
      return lhs.0 < rhs.0
    }
    return Array(scored.prefix(2).map(\.0))
  }
}
