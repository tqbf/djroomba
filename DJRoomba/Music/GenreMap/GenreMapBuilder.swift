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
    /// before mutual-kNN. Effectively disabled (0.0001) at the Phase-1
    /// gate: the structural floor already lives in SQL (`(a_n + b_n +
    /// t_n) >= 2`), and the per-node top-N filter (`topFractionPerNode`
    /// + `minPerNodeFloor`) is what actually shapes the sparse layout
    /// graph. The original 0.05 / 0.015 / 0.004 weight floors all
    /// pre-filtered the long tail so aggressively that the per-node
    /// top-N filter was working off a depleted candidate pool (the
    /// real library has so many small-Jaccard pairs that even 0.004
    /// dropped Louvain into 93 fragments). Letting the per-node filter
    /// see the full SQL-floor-respecting set lifts the real library
    /// from 41 → 100+ layout edges and Louvain from 93 → ~20
    /// communities.
    var minEdgeWeight = 0.0001
    /// Per-node top fraction of edges to keep when filtering candidates
    /// before mutual-kNN. Low-degree nodes always keep their full set.
    /// Bumped 0.10 → 0.25 → 0.35 → 0.50 across successive gate passes:
    /// for the long-tailed real-library shape, halving each node's
    /// candidate set lets enough edges survive the kNN intersection.
    var topFractionPerNode = 0.50
    /// Minimum kept candidates per node, regardless of `topFractionPerNode`.
    var minPerNodeFloor = 6
    /// Louvain resolution for the medium-resolution community pass.
    /// Phase 1's hulls + community gravity bind to this resolution; Phase
    /// 2's transferness (neighbour-community entropy + cross-community
    /// fraction) keys off the same partition.
    ///
    /// Lowered from 1.0 → 0.85 at the Phase-2 first-task pass: γ=1.0 on
    /// the real 115-genre library produced 44 communities, still too
    /// fragmented for Phase 2's perceptual bar (the gate review aimed at
    /// ~20). γ=0.85 is the Reichardt–Bornholdt "slightly continent-
    /// biased" sweet spot — it preserves the visible neighbourhoods from
    /// Phase 1 (Alt-Indie cluster, Hip-Hop/Rap cluster, Latin cluster,
    /// Country cluster) but folds the long-tailed singletons into their
    /// nearest meaningful neighbour. **Do not** raise this back without
    /// re-running the live-library count; the perceptual cost of over-
    /// fragmentation is higher than the cost of slightly-too-coarse
    /// communities at Phase 2's transferness scale.
    var mediumGamma = 0.85
    /// Pixels per unit of `weight` for the label font sizing — keeps
    /// pills proportional without ever shrinking below `minLabelFont`.
    /// Matches `StationLabel.minFontSize`/`maxFontSize` at the Phase-1
    /// gate so the pipeline's measured label rectangle matches the
    /// rendered pill exactly.
    var labelFontMin: CGFloat = 12
    var labelFontMax: CGFloat = 26
    var layout = GenreMapForceLayout.Configuration()
  }

  /// One-shot build: pure inputs → fully laid out model. The label-size
  /// function is provided because the panel — not the builder — knows
  /// SwiftUI text metrics; the builder consumes a closure so the
  /// pipeline stays Foundation-only and unit-testable on a stub.
  ///
  /// `measureLabel` is called once per node with the node's text, font
  /// size, and `nodeKind` — junctions and transfer stations render a
  /// leading SF Symbol inside the pill, so their AABB is wider than an
  /// ordinary pill at the same font size. The builder hands the panel-
  /// provided closure the kind so the same measurement function shapes
  /// both the layout's repulsion AABB and the rendered pill.
  static func build(
    nodes: [GenreNode],
    evidence: [GenreEdgeEvidence],
    configuration: Configuration = Configuration(),
    measureLabel: (_ text: String, _ fontSize: CGFloat, _ kind: GenreMapNodeKind) -> CGSize,
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

    // 2) Construct the initial layout graph (mutual-kNN ∪ MST).
    let layoutCandidatesAsLG = layoutCandidates.map { evidence in
      GenreMapLayoutGraph.Candidate(
        a: evidence.genreA,
        b: evidence.genreB,
        weight: evidence.totalWeight,
      )
    }
    let initialLayoutCandidates = GenreMapLayoutGraph.build(
      candidates: layoutCandidatesAsLG,
      nodes: nodeNames,
      librarySize: nodes.count,
    )

    // 3) Detect initial communities on the mutual-kNN ∪ MST substrate.
    // We use this partition to admit the heaviest inter-community edge
    // per community pair (Phase-2-gate substrate widening — see
    // `plans/genre-metro-map.md` Phase 1 step 4's "add the strongest
    // inter-community bridge edges"). Without this step transferness
    // can't see meaningful cross-community signal: every community pair
    // contributes at most one MST edge today, so an Alt/Indie that
    // visibly bridges five neighbourhoods on the screen had three
    // connected community neighbours in the layout-graph view and its
    // composite stalled below the transfer-station bar.
    let initialLouvainEdges = initialLayoutCandidates.map {
      GenreMapLouvain.Edge(a: $0.a, b: $0.b, weight: $0.weight)
    }
    let initialPartition = GenreMapLouvain.detect(
      nodes: Array(nodeNames),
      edges: initialLouvainEdges,
      gamma: configuration.mediumGamma,
    )

    // 3a) Admit the heaviest inter-community edge per community pair
    // from the full candidate set that isn't already in the mutual-kNN ∪
    // MST graph. Widens the layout substrate without losing the kNN/MST
    // sparsity (one extra edge per community-pair, capped at the count
    // of touching community pairs).
    let bridgeCandidates = GenreMapLayoutGraph.interCommunityBridges(
      candidates: layoutCandidatesAsLG,
      communityByGenre: initialPartition,
      existing: initialLayoutCandidates,
    )
    let widenedLayoutCandidates = initialLayoutCandidates + bridgeCandidates
    let layoutEdges = widenedLayoutCandidates.map { candidate in
      GenreMapEdge(
        genreA: candidate.a,
        genreB: candidate.b,
        totalWeight: candidate.weight,
      )
    }

    // 3b) Re-run Louvain on the widened layout graph. The bridges merge
    // previously-fragmented communities — the final partition is what
    // transferness, hulls, and community gravity all read.
    let louvainEdges = layoutEdges.map {
      GenreMapLouvain.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let partition = GenreMapLouvain.detect(
      nodes: Array(nodeNames),
      edges: louvainEdges,
      gamma: configuration.mediumGamma,
    )

    // 3a) Transferness (Phase 2). Runs after community detection and
    // before layout — so a future iteration can let `kind` shape the
    // layout (e.g. transfer-stations as soft anchors) and, more
    // importantly, the result is part of the cached `GenreMapModel`. The
    // drag affordance does NOT recompute this; classification must stay
    // stable as the user moves a node around.
    let transferEdges = layoutEdges.map {
      (a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let initialTransferness = GenreMapTransferness.score(
      nodes: nodes.map { (genre: $0.genre, weight: $0.weight) },
      edges: transferEdges,
      communities: partition,
    )

    // 3b) Strand inference (Phase 3). Runs against the layout graph +
    // partition + initial transferness; produces algorithmic corridors
    // (per-community heavy paths + cross-community bridge paths +
    // TF-IDF labels). Strand membership feeds the next transferness
    // pass via `strand_count(v)` — the 10 % composite slot that was
    // zero in Phase 2.
    let strandInputs = nodes.map { node in
      GenreMapStrandInference.InputNode(
        genre: node.genre,
        weight: node.weight,
        transferness: initialTransferness.compositeByNode[node.genre] ?? 0,
        communityID: partition[node.genre] ?? 0,
      )
    }
    let strandEdges = layoutEdges.map {
      GenreMapStrandInference.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let strands = GenreMapStrandInference.infer(
      nodes: strandInputs,
      edges: strandEdges,
    )

    // 3c) Re-score transferness with `strand_count` populated. After
    // this, decide whether to keep the rank classifier (Phase 2 ship)
    // or flip back to the absolute `classify(composite:)` per the plan's
    // Phase-3 guidance. The decision: prefer absolute IFF it produces
    // ≥ 4 transfer stations (the live-library expectation). Otherwise
    // keep the rank classifier as a robustness fallback.
    let strandCountByNode = GenreMapStrandInference.strandCountByNode(strands: strands)
    let rescored = GenreMapTransferness.score(
      nodes: nodes.map { (genre: $0.genre, weight: $0.weight) },
      edges: transferEdges,
      communities: partition,
      strandCountByNode: strandCountByNode,
    )
    // Absolute-classifier preference rule (Phase 3): use the absolute
    // `classify(composite:)` if it surfaces ≥ 4 transfer stations on
    // this distribution; else fall back to the rank classifier.
    let absoluteKinds = Dictionary(uniqueKeysWithValues: rescored.compositeByNode.map {
      ($0.key, GenreMapTransferness.classify(composite: $0.value))
    })
    let absoluteTransferCount = absoluteKinds.values.count(where: { $0 == .transferStation })
    let transfernessResult: GenreMapTransferness.Result =
      if absoluteTransferCount >= 4 {
        GenreMapTransferness.Result(
          compositeByNode: rescored.compositeByNode,
          inputsByNode: rescored.inputsByNode,
          kindByNode: absoluteKinds,
        )
      } else {
        rescored
      }

    // 4) Per-node label rectangle sizes (the headline correctness item:
    // repulsion is label-first, not radius-first). The label closure
    // is called with the node's classification so junction / transfer-
    // station pills (which render a leading glyph) get a wider AABB —
    // the layout sees the SAME rectangle the renderer will draw.
    var inputs = [GenreMapForceLayout.InputNode]()
    inputs.reserveCapacity(nodes.count)
    for node in nodes {
      let fontSize = configuration.labelFontMin
        + CGFloat(node.weight) * (configuration.labelFontMax - configuration.labelFontMin)
      let kind = transfernessResult.kindByNode[node.genre] ?? .ordinary
      let size = measureLabel(node.genre, fontSize, kind)
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

    // Index the layout-pass inputs by id so we can carry the SAME
    // measured `labelSize` onto every emitted `GenreMapNode`. The drag
    // relaxation pass reads this field instead of re-approximating, so
    // build-time and drag-time label rectangles can't disagree.
    let inputByID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })

    var mapNodes = [GenreMapNode]()
    mapNodes.reserveCapacity(nodes.count)
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity
    for node in nodes {
      let position = layout.positions[node.genre] ?? .zero
      let labelSize = inputByID[node.genre]?.labelSize ?? .zero
      let composite = transfernessResult.compositeByNode[node.genre] ?? 0
      let inputs = transfernessResult.inputsByNode[node.genre] ?? GenreMapTransfernessInputs(
        betweenness: 0,
        neighbourEntropy: 0,
        crossCommunityFraction: 0,
        membershipEntropy: 0,
        strandCount: 0,
        dampening: 1,
      )
      let kind = transfernessResult.kindByNode[node.genre] ?? .ordinary
      mapNodes.append(GenreMapNode(
        genre: node.genre,
        weight: node.weight,
        trackCount: node.trackCount,
        albumCount: node.albumCount,
        artistCount: node.artistCount,
        communityID: partition[node.genre] ?? 0,
        position: position,
        labelSize: labelSize,
        transferness: composite,
        nodeKind: kind,
        transfernessInputs: inputs,
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
      strands: strands,
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
