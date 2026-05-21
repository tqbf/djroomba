import Foundation

// MARK: - GenreMapLouvain

/// In-tree Louvain community detection with a configurable resolution γ
/// (`plans/genre-metro-map.md` Phase 1, step 5). Pure Swift — no GCD, no
/// dep, no globals. Deterministic node-iteration order so identical inputs
/// produce identical partitions (a layout stability requirement).
///
/// Louvain (Blondel et al. 2008) repeatedly:
///
/// 1. **Local move.** For each node, in deterministic order, compute the
///    modularity gain of moving it into each neighbour's community at the
///    given γ; pick the best (strictly positive) gain. Iterate until a
///    full pass produces no moves.
/// 2. **Aggregate.** Collapse each community into a single super-node;
///    sum the inter-community edge weights into super-edges; rerun the
///    local-move pass on the aggregate graph.
///
/// Step 1 alone is sufficient for Phase 1's needs (medium-resolution
/// partition over <300 genres at the real-library scale). The aggregate
/// pass is included anyway — Louvain is cheap and the aggregation step is
/// the canonical fixture for the multi-resolution macro-region anchors.
///
/// **Resolution.** Modularity here is the Reichardt–Bornholdt generalised
/// form: `Q = Σ_c (e_c − γ · (k_c² / (2m)))` where `e_c` is the inter-edge
/// weight inside community `c` (counted twice — the standard Louvain
/// convention) and `k_c` is the total weighted degree of community `c`.
/// `γ < 1` ⇒ fewer, bigger communities (continents); `γ = 1` ⇒ default;
/// `γ > 1` ⇒ many small communities (blocks).
enum GenreMapLouvain {

  // MARK: Internal

  struct Edge: Equatable, Sendable {
    var a: String
    var b: String
    var weight: Double
  }

  /// Map of node → community id (a small integer; ids are stable within
  /// this call only — not across calls or rebuilds).
  typealias Partition = [String: Int]

  /// Compute communities for `nodes` over `edges` at resolution `gamma`.
  /// `nodes` may include isolated genres (no incident edges); each such
  /// genre becomes its own singleton community.
  static func detect(
    nodes: [String],
    edges: [Edge],
    gamma: Double,
  ) -> Partition {
    guard !nodes.isEmpty else { return [:] }

    // Compact node → index for tight arrays.
    let sortedNodes = nodes.sorted()
    var indexByName = [String: Int]()
    indexByName.reserveCapacity(sortedNodes.count)
    for (index, name) in sortedNodes.enumerated() {
      indexByName[name] = index
    }

    // Adjacency: per node, [(neighbour index, weight)].
    var adjacency = [[(Int, Double)]](
      repeating: [],
      count: sortedNodes.count,
    )
    var degree = [Double](repeating: 0, count: sortedNodes.count)
    var twoM = 0.0
    for edge in edges {
      guard
        let lhs = indexByName[edge.a],
        let rhs = indexByName[edge.b],
        lhs != rhs,
        edge.weight > 0
      else { continue }
      adjacency[lhs].append((rhs, edge.weight))
      adjacency[rhs].append((lhs, edge.weight))
      degree[lhs] += edge.weight
      degree[rhs] += edge.weight
      twoM += 2 * edge.weight
    }
    // Singleton-only graph (no edges) ⇒ every node its own community.
    guard twoM > 0 else {
      return Dictionary(
        uniqueKeysWithValues: sortedNodes.enumerated().map { ($1, $0) }
      )
    }

    // Initial partition: each node its own community.
    var community = Array(0 ..< sortedNodes.count)
    var communityDegree = degree // running total per community

    var moved = true
    var passes = 0
    let maxPasses = 16
    while moved, passes < maxPasses {
      moved = false
      passes += 1
      for node in 0 ..< sortedNodes.count {
        let currentCommunity = community[node]
        // Aggregate incident weights per neighbour community.
        var weightToCommunity = [Int: Double]()
        for (other, weight) in adjacency[node] {
          weightToCommunity[community[other], default: 0] += weight
        }
        // Remove this node from its current community for the trial.
        communityDegree[currentCommunity] -= degree[node]
        let selfWeightInCurrent = weightToCommunity[currentCommunity] ?? 0

        var best = currentCommunity
        var bestGain = 0.0
        // Iterate candidate communities in a deterministic order
        // (smallest community id first) so ties resolve identically.
        for candidate in weightToCommunity.keys.sorted() {
          let k_in = weightToCommunity[candidate] ?? 0
          let totDegree = communityDegree[candidate]
          // ΔQ ∝ k_in − γ · (k_node · totDegree / m)
          let gain = k_in - gamma * (degree[node] * totDegree) / (twoM / 2)
          if gain > bestGain + 1.0e-12 {
            bestGain = gain
            best = candidate
          } else if abs(gain - bestGain) < 1.0e-12, candidate < best {
            // Tie-break by smaller community id (determinism).
            best = candidate
          }
        }
        // Re-evaluate the do-nothing case explicitly so the original
        // community wins on a true zero gain (avoids pointless churn).
        let stayGain = selfWeightInCurrent
          - gamma * (degree[node] * communityDegree[currentCommunity]) / (twoM / 2)
        if stayGain >= bestGain {
          best = currentCommunity
        }

        communityDegree[best] += degree[node]
        if best != currentCommunity {
          community[node] = best
          moved = true
        }
      }
    }

    // Optional aggregation pass: collapse + rerun. Only re-runs local
    // moves on the aggregate; for libraries the size of djroomba's
    // realistic corpus it converges in 1–2 outer iterations.
    let aggregated = aggregateAndRefine(
      community: community,
      sortedNodes: sortedNodes,
      adjacency: adjacency,
      gamma: gamma,
      twoM: twoM,
      degree: degree,
    )

    // Compact community ids to 0...n-1 in first-seen sorted-name order
    // (the deterministic output the rest of the pipeline depends on).
    return compactIDs(community: aggregated, sortedNodes: sortedNodes)
  }

  // MARK: Private

  private static func aggregateAndRefine(
    community: [Int],
    sortedNodes: [String],
    adjacency: [[(Int, Double)]],
    gamma: Double,
    twoM: Double,
    degree _: [Double],
  ) -> [Int] {
    // Map original community ids to compact `[0, c)` super-node indices.
    let originalIDs = Set(community).sorted()
    var superIndex = [Int: Int]()
    for (index, id) in originalIDs.enumerated() {
      superIndex[id] = index
    }
    let superCount = originalIDs.count
    guard superCount > 1 else { return community }

    // Build super-graph adjacency by summing inter-community edges.
    var superAdj = [[Int: Double]](repeating: [:], count: superCount)
    var superDegree = [Double](repeating: 0, count: superCount)
    for node in 0 ..< sortedNodes.count {
      let lhs = superIndex[community[node]] ?? 0
      for (other, weight) in adjacency[node] where other > node {
        let rhs = superIndex[community[other]] ?? 0
        if lhs == rhs {
          superAdj[lhs][lhs, default: 0] += weight
          // Self-loop on the supernode: contributes 2·weight to its
          // degree (matches the original-graph degree contribution).
          superDegree[lhs] += 2 * weight
        } else {
          superAdj[lhs][rhs, default: 0] += weight
          superAdj[rhs][lhs, default: 0] += weight
          superDegree[lhs] += weight
          superDegree[rhs] += weight
        }
      }
    }

    // Local-move pass on the super-graph. Same structure as the first
    // pass but on aggregated nodes — converges fast.
    var supCommunity = Array(0 ..< superCount)
    var supCommunityDegree = superDegree
    var moved = true
    var passes = 0
    while moved, passes < 16 {
      moved = false
      passes += 1
      for sup in 0 ..< superCount {
        let currentCommunity = supCommunity[sup]
        var weightToCommunity = [Int: Double]()
        for (other, weight) in superAdj[sup] where other != sup {
          weightToCommunity[supCommunity[other], default: 0] += weight
        }
        supCommunityDegree[currentCommunity] -= superDegree[sup]
        let selfWeightInCurrent = weightToCommunity[currentCommunity] ?? 0

        var best = currentCommunity
        var bestGain = 0.0
        for candidate in weightToCommunity.keys.sorted() {
          let k_in = weightToCommunity[candidate] ?? 0
          let totDegree = supCommunityDegree[candidate]
          let gain = k_in - gamma * (superDegree[sup] * totDegree) / (twoM / 2)
          if gain > bestGain + 1.0e-12 {
            bestGain = gain
            best = candidate
          } else if abs(gain - bestGain) < 1.0e-12, candidate < best {
            best = candidate
          }
        }
        let stayGain = selfWeightInCurrent
          - gamma * (superDegree[sup] * supCommunityDegree[currentCommunity]) / (twoM / 2)
        if stayGain >= bestGain {
          best = currentCommunity
        }

        supCommunityDegree[best] += superDegree[sup]
        if best != currentCommunity {
          supCommunity[sup] = best
          moved = true
        }
      }
    }

    // Map each original node back through the super-community.
    var refined = community
    for node in 0 ..< sortedNodes.count {
      let sup = superIndex[community[node]] ?? 0
      refined[node] = supCommunity[sup]
    }
    return refined
  }

  private static func compactIDs(
    community: [Int],
    sortedNodes: [String],
  ) -> Partition {
    var mapping = [Int: Int]()
    var next = 0
    var result = Partition()
    result.reserveCapacity(sortedNodes.count)
    for (index, name) in sortedNodes.enumerated() {
      let raw = community[index]
      if mapping[raw] == nil {
        mapping[raw] = next
        next += 1
      }
      result[name] = mapping[raw] ?? 0
    }
    return result
  }
}
