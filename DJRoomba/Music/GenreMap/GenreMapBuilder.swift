import CoreGraphics
import Foundation

// MARK: - GenreMapBuilder

/// The pure pipeline that turns the persisted v7 `genre_node` +
/// `genre_edge_evidence` rows into a renderable `GenreMapModel`
/// (`plans/genre-metro-map.md` Phase 1).
///
/// Phases, in order:
///
/// 1. Filter the edge candidates by support + adaptive per-node weight.
/// 2. Build the **layout** graph (mutual-kNN ∪ MST ∪ inter-community
///    bridges).
/// 3. Detect medium-resolution communities (`γ = 1.0`) on the layout
///    graph using `GenreMapLouvain`.
/// 4. Compute label rectangle sizes from per-genre weight (label-aware
///    repulsion needs the AABB) and seed initial positions from a
///    macro-layout pass over community supernodes.
/// 5. Run the constrained force layout. Settle, then return positions.
///
/// Everything is `nonisolated` + free of mutable globals: build a model
/// from any combination of persisted rows on any actor, deterministic
/// given identical inputs, fully unit-testable end-to-end on a fixture.
enum GenreMapBuilder {

  // MARK: Internal

  struct Configuration: Sendable {
    /// Edge composite-weight floor below which a candidate is discarded
    /// before mutual-kNN. This is the adaptive-threshold "floor" — the
    /// per-node `top 5–10 %` cut is in `topFractionPerNode`. Lowered
    /// from 0.05 to 0.015 after the first live verification on the real
    /// library showed too few layout edges (14/115 nodes ⇒ Louvain
    /// produced 112 singleton communities). The support floor at SQL
    /// write time (`shared_* >= 2`) is already the noise-floor; this
    /// threshold is just an extra precaution.
    var minEdgeWeight = 0.015
    /// Per-node top fraction of edges to keep when filtering candidates
    /// before mutual-kNN. Low-degree nodes always keep their full set.
    /// Bumped from 0.10 to 0.25 for the same reason as `minEdgeWeight`.
    var topFractionPerNode = 0.25
    /// Minimum kept candidates per node, regardless of `topFractionPerNode`.
    var minPerNodeFloor = 6
    /// Louvain resolution for the medium-resolution community pass.
    /// Phase 1's hulls + community gravity bind to this resolution.
    var mediumGamma = 1.0
    /// Pixels per unit of `weight` for the label font sizing — keeps
    /// pills proportional without ever shrinking below `minLabelFont`.
    var labelFontMin: CGFloat = 11
    var labelFontMax: CGFloat = 24
    var layout = GenreMapForceLayout.Configuration()
  }

  /// One-shot build: pure inputs → fully laid out model. The label-size
  /// function is provided because the panel — not the builder — knows
  /// SwiftUI text metrics; the builder consumes a closure so the
  /// pipeline stays Foundation-only and unit-testable on a stub.
  static func build(
    nodes: [GenreNode],
    evidence: [GenreEdgeEvidence],
    configuration: Configuration = Configuration(),
    measureLabel: (_ text: String, _ fontSize: CGFloat) -> CGSize,
  ) -> GenreMapModel {
    guard !nodes.isEmpty else {
      return GenreMapModel(
        nodes: [],
        layoutEdges: [],
        communities: [],
        worldBounds: .zero,
      )
    }

    // 1) Filter candidate edges (the spec's adaptive threshold +
    // per-node top-fraction). Support floor is already enforced at SQL
    // write time; this is the secondary signal cut.
    let nodeNames = Set(nodes.map(\.genre))
    let layoutCandidates = filterCandidates(
      evidence: evidence,
      nodeNames: nodeNames,
      configuration: configuration,
    )

    // 2) Construct the layout graph.
    let layoutCandidatesAsLG = layoutCandidates.map { evidence in
      GenreMapLayoutGraph.Candidate(
        a: evidence.genreA,
        b: evidence.genreB,
        weight: evidence.totalWeight,
      )
    }
    let layoutEdges = GenreMapLayoutGraph.build(
      candidates: layoutCandidatesAsLG,
      nodes: nodeNames,
      librarySize: nodes.count,
    ).map { candidate in
      GenreMapEdge(
        genreA: candidate.a,
        genreB: candidate.b,
        totalWeight: candidate.weight,
      )
    }

    // 3) Communities at the medium resolution.
    let louvainEdges = layoutEdges.map {
      GenreMapLouvain.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let partition = GenreMapLouvain.detect(
      nodes: Array(nodeNames),
      edges: louvainEdges,
      gamma: configuration.mediumGamma,
    )

    // 4) Per-node label rectangle sizes (the headline correctness item:
    // repulsion is label-first, not radius-first).
    var inputs = [GenreMapForceLayout.InputNode]()
    inputs.reserveCapacity(nodes.count)
    for node in nodes {
      let fontSize = configuration.labelFontMin
        + CGFloat(node.weight) * (configuration.labelFontMax - configuration.labelFontMin)
      let size = measureLabel(node.genre, fontSize)
      inputs.append(GenreMapForceLayout.InputNode(
        id: node.genre,
        weight: node.weight,
        labelSize: size,
        communityID: partition[node.genre] ?? 0,
      ))
    }

    // 5) Layout. The kernel handles the macro anchor pass internally,
    // so we hand it the full layout-graph input set in one shot.
    let layout = GenreMapForceLayout.layout(
      nodes: inputs,
      edges: layoutEdges,
      configuration: configuration.layout,
    )

    // Assemble the model. Community membership rebuilt deterministically
    // here too (sorted member names within each community).
    var membersByCommunity = [Int: [String]]()
    for node in nodes {
      let id = partition[node.genre] ?? 0
      membersByCommunity[id, default: []].append(node.genre)
    }

    var mapNodes = [GenreMapNode]()
    mapNodes.reserveCapacity(nodes.count)
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity
    for node in nodes {
      let position = layout.positions[node.genre] ?? .zero
      mapNodes.append(GenreMapNode(
        genre: node.genre,
        weight: node.weight,
        trackCount: node.trackCount,
        albumCount: node.albumCount,
        artistCount: node.artistCount,
        communityID: partition[node.genre] ?? 0,
        position: position,
      ))
      minX = min(minX, position.x)
      minY = min(minY, position.y)
      maxX = max(maxX, position.x)
      maxY = max(maxY, position.y)
    }
    if !minX.isFinite { minX = 0
      maxX = 0
      minY = 0
      maxY = 0
    }

    let communities = membersByCommunity.keys.sorted().map { id -> GenreMapCommunity in
      let members = membersByCommunity[id]?.sorted() ?? []
      var centroid = CGPoint.zero
      var count = 0
      for memberName in members {
        if let position = layout.positions[memberName] {
          centroid.x += position.x
          centroid.y += position.y
          count += 1
        }
      }
      if count > 0 {
        centroid.x /= CGFloat(count)
        centroid.y /= CGFloat(count)
      }
      return GenreMapCommunity(id: id, members: members, centroid: centroid)
    }

    let bounds = CGRect(
      x: minX,
      y: minY,
      width: max(1, maxX - minX),
      height: max(1, maxY - minY),
    )

    return GenreMapModel(
      nodes: mapNodes,
      layoutEdges: layoutEdges,
      communities: communities,
      worldBounds: bounds,
    )
  }

  static func filterCandidates(
    evidence: [GenreEdgeEvidence],
    nodeNames: Set<String>,
    configuration: Configuration,
  ) -> [GenreEdgeEvidence] {
    let baseFiltered = evidence.filter { row in
      row.totalWeight >= configuration.minEdgeWeight
        && nodeNames.contains(row.genreA)
        && nodeNames.contains(row.genreB)
    }

    // Per-node top-fraction filter — keep only edges in each node's top
    // `topFractionPerNode` by weight (or `minPerNodeFloor`, whichever is
    // bigger). An edge survives if EITHER endpoint considers it top-N.
    // That's the "union of top-N per node" heuristic the plan calls
    // for: a small genre keeps its strongest links even when those
    // links sit deep in a giant's tail.
    var perNodeEdges = [String: [GenreEdgeEvidence]]()
    for row in baseFiltered {
      perNodeEdges[row.genreA, default: []].append(row)
      perNodeEdges[row.genreB, default: []].append(row)
    }
    var allowedKeys = Set<EdgeKey>()
    for (_, rows) in perNodeEdges {
      let sorted = rows.sorted { $0.totalWeight > $1.totalWeight }
      let keep = max(
        configuration.minPerNodeFloor,
        Int((Double(sorted.count) * configuration.topFractionPerNode).rounded(.up)),
      )
      for row in sorted.prefix(keep) {
        allowedKeys.insert(EdgeKey(a: row.genreA, b: row.genreB))
      }
    }
    return baseFiltered.filter {
      allowedKeys.contains(EdgeKey(a: $0.genreA, b: $0.genreB))
    }
  }

  // MARK: Private

  private struct EdgeKey: Hashable {
    var a: String
    var b: String
  }

}
