import Foundation

// MARK: - GenreMapLayoutGraph

/// Sparse layout-graph construction for the genre map
/// (`plans/genre-metro-map.md` Phase 1, step 4).
///
/// Inputs: every canonical `(genreA, genreB)` candidate edge with its
/// composite `totalWeight`. Output: a much smaller set of edges that the
/// physics actually sees. Pure functions — no DB, no async, no globals.
///
/// Sparsity comes from three steps stacked on top of each other:
///
/// 1. **Adaptive threshold per node.** For each node, keep edges whose
///    weight is in its top `k` (default 8) AND ≥ a per-node floor (the
///    spec calls for "top 5–10% by weight per node, with floors for
///    low-degree nodes"). A low-degree node still gets all its edges so
///    a tiny genre never goes orphan.
/// 2. **Mutual-kNN.** Keep an edge only when each endpoint considers the
///    other a top-`k` neighbour. Symmetric by construction.
/// 3. **Maximum-spanning-tree backbone.** Add an MST over the *filtered*
///    candidates so the layout graph is guaranteed connected (single
///    component) — even when mutual-kNN drops a hub's only weak link.
/// 4. **Inter-community bridges.** (Communities haven't been computed at
///    layout-graph construction time — they're detected on top of the
///    layout graph. The "strongest inter-community bridge" step in the
///    plan therefore lives in `GenreMapBuilder.buildBridgeEdges`, run
///    AFTER community detection on the v6-edge candidates.)
enum GenreMapLayoutGraph {

  // MARK: Internal

  struct Candidate: Equatable, Sendable {
    var a: String
    var b: String
    /// Composite weight; bigger = stronger relationship.
    var weight: Double
  }

  /// Build the layout graph. `librarySize` (the analysed node count)
  /// drives the `k` for kNN — small libraries use `k = 4`, big ones
  /// `k = 8` — and the per-node `keepFraction` floor.
  ///
  /// Determinism: ties are broken by `(a, b)` name order at every step,
  /// so identical inputs ⇒ identical outputs (the per-rebuild stability
  /// the layout depends on — see the seeded RNG in
  /// `GenreMapBuilder.layout`).
  static func build(
    candidates: [Candidate],
    nodes: Set<String>,
    librarySize: Int,
  ) -> [Candidate] {
    guard !candidates.isEmpty else { return [] }
    let k = neighbourK(for: librarySize)

    // Canonicalise and key by (a, b) — the input is already canonical
    // (a < b), but defensively normalise here.
    let normalised: [Candidate] = candidates.map { candidate in
      candidate.a < candidate.b
        ? candidate
        : Candidate(a: candidate.b, b: candidate.a, weight: candidate.weight)
    }

    // Per-node ranked neighbour lists (weight desc, then neighbour name).
    var neighbours = [String: [(other: String, weight: Double)]]()
    for candidate in normalised {
      neighbours[candidate.a, default: []]
        .append((candidate.b, candidate.weight))
      neighbours[candidate.b, default: []]
        .append((candidate.a, candidate.weight))
    }
    for key in neighbours.keys {
      neighbours[key]?.sort { lhs, rhs in
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.other < rhs.other
      }
    }

    // Per-node top-k set.
    var topK = [String: Set<String>]()
    for (node, list) in neighbours {
      let take = min(k, list.count)
      topK[node] = Set(list.prefix(take).map(\.other))
    }

    // Mutual-kNN edges (each endpoint considers the other top-k).
    var keptKeys = Set<EdgeKey>()
    for candidate in normalised {
      if
        topK[candidate.a]?.contains(candidate.b) == true,
        topK[candidate.b]?.contains(candidate.a) == true
      {
        keptKeys.insert(EdgeKey(a: candidate.a, b: candidate.b))
      }
    }

    // MST backbone over ALL candidates (Kruskal max-weight) to guarantee
    // connectivity for genres mutual-kNN dropped. Add only edges not
    // already in the mutual-kNN set; idempotent + deterministic by sort.
    let mst = maximumSpanningTree(candidates: normalised, nodes: nodes)
    for candidate in mst {
      keptKeys.insert(EdgeKey(a: candidate.a, b: candidate.b))
    }

    // Materialise the union in canonical name order.
    let byKey = Dictionary(uniqueKeysWithValues: normalised.map {
      (EdgeKey(a: $0.a, b: $0.b), $0)
    })
    let kept = keptKeys.compactMap { byKey[$0] }
    return kept.sorted { lhs, rhs in
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      if lhs.a != rhs.a { return lhs.a < rhs.a }
      return lhs.b < rhs.b
    }
  }

  /// Library-size sensitivity for k (mutual-kNN). Below 60 nodes uses
  /// k=4 (sparser, more legible); above 240 nodes uses k=8.
  static func neighbourK(for librarySize: Int) -> Int {
    switch librarySize {
    case ..<60: 4
    case ..<240: 6
    default: 8
    }
  }

  /// Admit the **heaviest inter-community edge per community pair** from
  /// the candidate set that isn't already in `existing`. This is the
  /// Phase-2-gate substrate widening (per `plans/genre-metro-map.md`
  /// Phase 1 step 4's "add the strongest inter-community bridge edges"
  /// — left as a Phase-3 carry-forward at the Phase-1 gate, executed at
  /// the Phase-2 gate because Phase 2's transferness needs cross-
  /// community edges to score above zero).
  ///
  /// On the real library the per-node mutual-kNN + MST construction
  /// admits ~one bridge per community via the MST step, which is not
  /// enough: a community pair with multiple heavy bridges only contributes
  /// ONE to the layout graph, so genuine bridge nodes see only that one
  /// edge in their neighbour-community-entropy / cross-community-fraction
  /// inputs. By admitting the heaviest inter-community edge per
  /// community pair, every pair of communities that touches at all
  /// contributes its strongest crossing — which is exactly the signal
  /// transferness wants to see.
  ///
  /// Pure / deterministic. Returns the bridges in canonical (a, b) order
  /// then weight desc; the caller unions these with the existing edges.
  static func interCommunityBridges(
    candidates: [Candidate],
    communityByGenre: [String: Int],
    existing: [Candidate],
  ) -> [Candidate] {
    guard !candidates.isEmpty else { return [] }
    // Index existing edges so we don't double-admit anything mutual-kNN
    // / MST already kept.
    var existingKeys = Set<EdgeKey>()
    for candidate in existing {
      existingKeys.insert(EdgeKey(a: candidate.a, b: candidate.b))
    }
    // Strongest crossing per ordered community pair (cA < cB). Ties
    // broken by canonical (a, b) for determinism.
    var bestByPair = [PairKey: Candidate]()
    for candidate in candidates {
      let normalised: Candidate =
        candidate.a < candidate.b
          ? candidate
          : Candidate(a: candidate.b, b: candidate.a, weight: candidate.weight)
      guard
        let cA = communityByGenre[normalised.a],
        let cB = communityByGenre[normalised.b],
        cA != cB
      else { continue }
      let pair = PairKey(lo: min(cA, cB), hi: max(cA, cB))
      if let current = bestByPair[pair] {
        if candidate.weight > current.weight {
          bestByPair[pair] = normalised
        } else if candidate.weight == current.weight {
          // Deterministic tie-break: prefer the canonical lexicographic edge.
          if
            normalised.a < current.a
            || (normalised.a == current.a && normalised.b < current.b)
          {
            bestByPair[pair] = normalised
          }
        }
      } else {
        bestByPair[pair] = normalised
      }
    }
    // Filter out anything mutual-kNN / MST already admitted.
    let bridges = bestByPair.values.filter { candidate in
      !existingKeys.contains(EdgeKey(a: candidate.a, b: candidate.b))
    }
    return bridges.sorted { lhs, rhs in
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      if lhs.a != rhs.a { return lhs.a < rhs.a }
      return lhs.b < rhs.b
    }
  }

  /// MST over canonical-half candidates. Returns the kept edges. Uses
  /// union-find; deterministic ordering = weight desc, then `(a, b)`.
  static func maximumSpanningTree(
    candidates: [Candidate],
    nodes: Set<String>,
  ) -> [Candidate] {
    guard nodes.count >= 2 else { return [] }
    let sorted = candidates.sorted { lhs, rhs in
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      if lhs.a != rhs.a { return lhs.a < rhs.a }
      return lhs.b < rhs.b
    }
    var uf = UnionFind(elements: nodes)
    var out = [Candidate]()
    out.reserveCapacity(nodes.count - 1)
    for candidate in sorted {
      // Only consider candidates whose endpoints are in `nodes` (an
      // isolated genre with no candidates stays its own component).
      guard nodes.contains(candidate.a), nodes.contains(candidate.b) else {
        continue
      }
      if uf.union(candidate.a, candidate.b) {
        out.append(candidate)
        if out.count == nodes.count - 1 { break }
      }
    }
    return out
  }

  // MARK: Private

  private struct EdgeKey: Hashable {
    var a: String
    var b: String
  }

  private struct PairKey: Hashable {
    var lo: Int
    var hi: Int
  }

}

// MARK: - UnionFind

/// Small generic union-find on strings — Kruskal's MST needs it; nothing
/// else does, so it's `fileprivate`-equivalent (kept here, not surfaced).
struct UnionFind {

  // MARK: Lifecycle

  init(elements: Set<String>) {
    parent = Dictionary(uniqueKeysWithValues: elements.map { ($0, $0) })
    rank = Dictionary(uniqueKeysWithValues: elements.map { ($0, 0) })
  }

  // MARK: Internal

  /// Returns `true` if `a` and `b` were in different sets and have been
  /// merged; `false` if they were already in the same set.
  mutating func union(_ a: String, _ b: String) -> Bool {
    let rootA = find(a)
    let rootB = find(b)
    guard rootA != rootB else { return false }
    let ra = rank[rootA] ?? 0
    let rb = rank[rootB] ?? 0
    if ra < rb {
      parent[rootA] = rootB
    } else if ra > rb {
      parent[rootB] = rootA
    } else {
      parent[rootB] = rootA
      rank[rootA] = ra + 1
    }
    return true
  }

  func componentCount() -> Int {
    var seen = Set<String>()
    var copy = self
    for key in parent.keys { seen.insert(copy.find(key)) }
    return seen.count
  }

  // MARK: Private

  private var parent: [String: String]
  private var rank: [String: Int]

  private mutating func find(_ x: String) -> String {
    var current = x
    while let next = parent[current], next != current {
      // Path compression — flatten as we go.
      let grandparent = parent[next] ?? next
      parent[current] = grandparent
      current = next
    }
    return current
  }
}
