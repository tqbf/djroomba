import CoreGraphics
import Foundation

// MARK: - GenreMapDiscovery

/// Phase 5 (`plans/genre-metro-map.md`) discovery primitives. Pure
/// Swift — no DB, no async, no globals. Three responsibilities:
///
/// 1. **Selection state model.** A small value type the panel binds to
///    that distinguishes "hovering a genre" (cosmetic only, must not
///    trigger any heavy work) from "clicked a genre" (open inspector +
///    materialise evidence) from "comparing two genres" (Yen-k path
///    search + shared evidence rollup).
/// 2. **Yen-k shortest paths** between two genres over the layout
///    graph. Edge cost = `1 − total_weight` so heavier composite
///    edges shorten the path; results are simple paths sorted by
///    cumulative cost.
/// 3. **Evidence rollup helpers.** Light-weight collectors over the
///    in-memory model: 1-hop layout-graph neighbours of a genre with
///    their composite weight, strand membership lookups, transfer-
///    station enumeration along a path, and the per-genre serving
///    strand list (used by hover-mode brightness rules).
///
/// Everything here is `nonisolated` static and unit-testable on a
/// fixture without touching the SwiftUI panel or `GenreMapService`.
enum GenreMapDiscovery {

  // MARK: Internal

  /// Phase 5 selection mode. Drives the inspector's section choice +
  /// the canvas's highlight/fade scheme. Set by the panel; read by the
  /// inspector + the canvas. Hovering is **not** a selection — it
  /// lives on its own `@State` in the panel (`hoveredGenre`) so that
  /// hover-over-hover-over-hover cannot churn the inspector or kick
  /// off any evidence loading.
  enum Selection: Equatable, Sendable {
    case none
    case focused(genre: String)
    case compare(a: String, b: String)
  }

  /// One result row from `kShortestPaths`. Stations are in path order
  /// (source first, target last); `edgeWeights[i]` is the composite
  /// weight on the edge from `stations[i]` to `stations[i + 1]`.
  struct Path: Equatable, Sendable {
    var stations: [String]
    var edgeWeights: [Double]

    /// Sum of `1 − weight` per edge — the graph cost the algorithm
    /// minimises. Cheaper paths are stronger paths.
    var cost: Double {
      edgeWeights.reduce(0.0) { $0 + (1.0 - $1) }
    }

    /// Cumulative composite weight along the path (sum of edge
    /// weights). Surfaced to the inspector as a "path strength" hint
    /// that grows with both length AND per-edge weight.
    var totalWeight: Double {
      edgeWeights.reduce(0.0, +)
    }
  }

  /// One row from `oneHopNeighbours`.
  struct Neighbour: Equatable, Sendable {
    var genre: String
    var weight: Double
  }

  /// Output of `transferMapPlan`. World-space `centre` + the final
  /// `scale` factor (`scale > 1` = zoomed in). The view layer applies
  /// this by setting its `offset` to centre `centre` in the viewport
  /// and its `scale` to `scale`.
  struct TransferMapPlan: Equatable, Sendable {
    var centre: CGPoint
    var scale: CGFloat
  }

  /// Edge over the layout graph (or any other display channel the
  /// caller wants to route over). The discovery module is graph-
  /// agnostic — passing a different channel's edges to `kShortestPaths`
  /// gives k-paths over that channel.
  struct Edge: Equatable, Sendable {
    var a: String
    var b: String
    var weight: Double
  }

  /// **Yen's k-shortest-paths** over the layout graph. Returns up to
  /// `k` distinct simple paths from `source` to `target` sorted by
  /// cumulative cost ascending. Edge cost is `1 − total_weight`, so
  /// heavy edges shorten the path and the strongest connection is
  /// returned first. Returns `[]` when the two nodes are disconnected.
  ///
  /// Bounded by the small layout graph (≤ a few hundred nodes / few
  /// thousand edges); `k ≤ 5` per the Phase 5 budget.
  static func kShortestPaths(
    from source: String,
    to target: String,
    edges: [Edge],
    k: Int = 5,
  ) -> [Path] {
    guard !source.isEmpty, !target.isEmpty, source != target, k > 0 else { return [] }
    let adjacency = adjacencyMap(from: edges)
    guard adjacency[source] != nil, adjacency[target] != nil else { return [] }
    guard
      let first = dijkstra(
        from: source,
        to: target,
        adjacency: adjacency,
        removedEdges: [],
        removedNodes: [],
      )
    else {
      return []
    }
    var accepted = [first]
    // Candidate pool (the "B" set in Yen). We keep it sorted-by-cost
    // and dedupe by path identity.
    var candidates = [Path]()

    while accepted.count < k {
      let last = accepted[accepted.count - 1]
      // For each "spur" node i along the last accepted path, attempt a
      // detour from that point onward.
      let stations = last.stations
      let upperBound = stations.count - 1
      for i in 0..<upperBound {
        let spurNode = stations[i]
        let rootPath = Array(stations[0...i])
        let rootEdges = Array(last.edgeWeights[0..<i])

        // Block edges that would re-trace an already-accepted path
        // that shares this root prefix.
        var removedEdges = Set<EdgeKey>()
        for accept in accepted where Array(accept.stations.prefix(i + 1)) == rootPath {
          if i < accept.stations.count - 1 {
            let key = EdgeKey(
              a: min(accept.stations[i], accept.stations[i + 1]),
              b: max(accept.stations[i], accept.stations[i + 1]),
            )
            removedEdges.insert(key)
          }
        }
        // Block every node on the root path except the spur node so
        // the spur path cannot loop through them.
        let removedNodes = Set(rootPath.dropLast())

        guard
          let spurPath = dijkstra(
            from: spurNode,
            to: target,
            adjacency: adjacency,
            removedEdges: removedEdges,
            removedNodes: removedNodes,
          )
        else { continue }

        // Stitch root + spur (skip the duplicate spur node).
        let stationsCombined = rootPath + Array(spurPath.stations.dropFirst())
        let edgesCombined = rootEdges + spurPath.edgeWeights
        let combined = Path(
          stations: stationsCombined,
          edgeWeights: edgesCombined,
        )
        // De-dupe against accepted + existing candidates.
        if accepted.contains(combined) || candidates.contains(combined) { continue }
        candidates.append(combined)
      }
      guard !candidates.isEmpty else { break }
      candidates.sort { lhs, rhs in
        if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
        // Stable, deterministic tie-break by path identity.
        return lhs.stations.joined(separator: ",") < rhs.stations.joined(separator: ",")
      }
      let best = candidates.removeFirst()
      accepted.append(best)
    }
    return accepted
  }

  /// One-hop layout-graph neighbours of `genre` with the composite
  /// edge weight. Used by hover-mode (which neighbours to brighten)
  /// + the ordinary-genre inspector's ego network section.
  static func oneHopNeighbours(
    of genre: String,
    edges: [Edge],
  ) -> [Neighbour] {
    var rows = [Neighbour]()
    for edge in edges {
      if edge.a == genre {
        rows.append(Neighbour(genre: edge.b, weight: edge.weight))
      } else if edge.b == genre {
        rows.append(Neighbour(genre: edge.a, weight: edge.weight))
      }
    }
    return rows.sorted { lhs, rhs in
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      return lhs.genre < rhs.genre
    }
  }

  /// Set of strands whose `memberGenres` include `genre`. Returned as
  /// strand ids so callers can resolve back to the strand record. Used
  /// by hover-brightness ("brighten strands that pass through this
  /// pill") and the transfer-map mode ("which strands does this
  /// transfer station serve").
  static func servingStrandIDs(
    of genre: String,
    strands: [GenreMapStrandInference.Strand],
  ) -> Set<Int> {
    var ids = Set<Int>()
    for strand in strands where strand.memberGenres.contains(genre) {
      // For a branch, the user-facing identity is the parent strand
      // (the colour fans out from the parent). The transfer-map mode
      // wants the LIST of serving corridors; branches share the parent
      // corridor, so we collapse to the parent.
      if strand.isBranch, let parent = strand.parentStrandID {
        ids.insert(parent)
      } else {
        ids.insert(strand.id)
      }
    }
    return ids
  }

  /// Transfer stations along a path — the genres on `path.stations`
  /// whose `nodeKind == .transferStation`. Used by the compare-genres
  /// inspector section to highlight "you pass through these transfer
  /// stations".
  static func transferStations(
    along path: Path,
    nodesByGenre: [String: GenreMapNode],
  ) -> [String] {
    path.stations.compactMap { name in
      guard let node = nodesByGenre[name] else { return nil }
      return node.nodeKind == .transferStation ? name : nil
    }
  }

  /// Strand ids whose `pathStations` overlap the given path by ≥ 1
  /// edge (consecutive station pair). Used by the compare-genres
  /// inspector to surface "this comparison crosses these corridors".
  static func strandsOverlappingPath(
    path: Path,
    strands: [GenreMapStrandInference.Strand],
  ) -> Set<Int> {
    guard path.stations.count >= 2 else { return [] }
    var pathEdges = Set<EdgeKey>()
    for index in 0..<(path.stations.count - 1) {
      let lhs = path.stations[index]
      let rhs = path.stations[index + 1]
      pathEdges.insert(EdgeKey(a: min(lhs, rhs), b: max(lhs, rhs)))
    }
    var ids = Set<Int>()
    for strand in strands {
      let stations = strand.pathStations
      guard stations.count >= 2 else { continue }
      for index in 0..<(stations.count - 1) {
        let lhs = stations[index]
        let rhs = stations[index + 1]
        let key = EdgeKey(a: min(lhs, rhs), b: max(lhs, rhs))
        if pathEdges.contains(key) {
          // Collapse branches to their parent corridor for the visual
          // bundle the user sees as "one strand".
          if strand.isBranch, let parent = strand.parentStrandID {
            ids.insert(parent)
          } else {
            ids.insert(strand.id)
          }
          break
        }
      }
    }
    return ids
  }

  /// Transfer-station "centre and zoom" plan — the deterministic
  /// numeric output that the view layer animates the viewport to. The
  /// algorithm here is unit-testable; the actual viewport animation
  /// lives in `GenreMapPanel`.
  ///
  /// Computes a zoom level that lands the bounding box of the
  /// transfer station + its one-hop layout-graph neighbours snugly
  /// inside `viewport`, with a comfortable padding inset. Returns
  /// `nil` when the input is degenerate (no neighbours, zero
  /// viewport, etc.).
  static func transferMapPlan(
    centreGenre: String,
    nodesByGenre: [String: GenreMapNode],
    edges: [Edge],
    viewport: CGSize,
    padding: CGFloat = 100,
    minScale: CGFloat = 0.4,
    maxScale: CGFloat = 2.4,
  ) -> TransferMapPlan? {
    guard let centreNode = nodesByGenre[centreGenre] else { return nil }
    guard viewport.width > 0, viewport.height > 0 else { return nil }
    let neighbours = oneHopNeighbours(of: centreGenre, edges: edges)
      .compactMap { nodesByGenre[$0.genre] }
    var points: [CGPoint] = [centreNode.position]
    points.append(contentsOf: neighbours.map(\.position))
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity
    for point in points {
      minX = min(minX, point.x)
      minY = min(minY, point.y)
      maxX = max(maxX, point.x)
      maxY = max(maxY, point.y)
    }
    let width = max(1, maxX - minX)
    let height = max(1, maxY - minY)
    let availableWidth = max(1, viewport.width - 2 * padding)
    let availableHeight = max(1, viewport.height - 2 * padding)
    let raw = min(availableWidth / width, availableHeight / height)
    let scale = max(minScale, min(maxScale, raw))
    return TransferMapPlan(
      centre: centreNode.position,
      scale: scale,
    )
  }

  // MARK: Private

  private struct EdgeKey: Hashable {
    var a: String
    var b: String
  }

  /// Adjacency map from the canonical-half edge list. Edges are sorted
  /// descending by weight then ascending by neighbour name for
  /// deterministic traversal.
  private static func adjacencyMap(
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

  /// Dijkstra over `1 − weight`, with edge + node removals supplied so
  /// the Yen-k outer loop can block previously-used spur edges + root
  /// path nodes. Returns the shortest single path or `nil` when
  /// disconnected. Pure, deterministic.
  private static func dijkstra(
    from source: String,
    to target: String,
    adjacency: [String: [(other: String, weight: Double)]],
    removedEdges: Set<EdgeKey>,
    removedNodes: Set<String>,
  ) -> Path? {
    guard adjacency[source] != nil, adjacency[target] != nil else { return nil }
    var distance = [String: Double]()
    var parent = [String: (parent: String, weight: Double)]()
    var pending = Set<String>()
    for node in adjacency.keys {
      if removedNodes.contains(node), node != source { continue }
      distance[node] = .infinity
      pending.insert(node)
    }
    distance[source] = 0
    while !pending.isEmpty {
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
        let key = EdgeKey(a: min(here, other), b: max(here, other))
        if removedEdges.contains(key) { continue }
        let edgeCost = 1.0 - weight
        let alt = bestDistance + edgeCost
        if alt < (distance[other] ?? .infinity) {
          distance[other] = alt
          parent[other] = (here, weight)
        }
      }
    }
    guard (distance[target] ?? .infinity).isFinite else { return nil }
    var revStations = [target]
    var revWeights = [Double]()
    var current = target
    while let parentEdge = parent[current] {
      revWeights.append(parentEdge.weight)
      revStations.append(parentEdge.parent)
      current = parentEdge.parent
      if current == source { break }
    }
    guard revStations.last == source else { return nil }
    return Path(
      stations: Array(revStations.reversed()),
      edgeWeights: Array(revWeights.reversed()),
    )
  }
}
