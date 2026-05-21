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

  /// Build result — the renderable model PLUS Phase-6 persistence
  /// payload (the rows the store writes back to `genre_map_state` +
  /// `genre_map_strand`). The model is the same shape Phase 1–5 produced;
  /// the persistence payload is new and consumed only by the service's
  /// post-build write. Tests that don't care about persistence read
  /// `.model` and ignore the rest.
  struct BuildResult: Sendable {
    var model: GenreMapModel
    var stateRows: [GenreMapStateRow]
    var strandRows: [GenreMapStrandRow]
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
    buildWithPersistence(
      nodes: nodes,
      evidence: evidence,
      previousState: nil,
      configuration: configuration,
      measureLabel: measureLabel,
    ).model
  }

  /// Phase 6 (`plans/genre-metro-map.md`): builder entrypoint that
  /// accepts the persisted state from the previous rebuild + emits
  /// fresh state rows alongside the model. When `previousState` is
  /// `nil` this behaves like `build` (random scatter, fresh
  /// algorithmic ids).
  ///
  /// - Initialises force-layout positions from `previousState.positions`
  ///   when present (no random reseed on re-import).
  /// - Adds a per-node stability force `μ · (previous − current)` on
  ///   existing nodes only.
  /// - Matches new communities to old at three resolutions (coarse,
  ///   medium, fine). Matched communities reuse the predecessor id; new
  ///   communities mint a fresh `new-N` id.
  /// - Matches new strands to old via member-Jaccard + path-similarity.
  ///   Matched strands reuse the predecessor's `colourID` + label
  ///   tokens; new strands mint fresh entries.
  /// - Bumps revision: `previousState?.revision ?? 0 + 1` is the
  ///   revision stamped on every output row.
  static func buildWithPersistence(
    nodes: [GenreNode],
    evidence: [GenreEdgeEvidence],
    previousState: GenreMapPersistedState?,
    configuration: Configuration = Configuration(),
    measureLabel: (_ text: String, _ fontSize: CGFloat, _ kind: GenreMapNodeKind) -> CGSize,
  ) -> BuildResult {
    let nextRevision = (previousState?.revision ?? 0) + 1
    guard !nodes.isEmpty else {
      return BuildResult(
        model: GenreMapModel(
          nodes: [],
          layoutEdges: [],
          communities: [],
          worldBounds: .zero,
          defaultCentre: .zero,
        ),
        stateRows: [],
        strandRows: [],
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
    // so we hand it the full layout-graph input set in one shot. Phase
    // 6: pipe persisted positions through so the layout seeds from
    // them (no random reseed on re-import) and applies the stability
    // force to existing nodes.
    var layoutConfiguration = configuration.layout
    if let previousState, !previousState.positions.isEmpty {
      layoutConfiguration.previousPositions = previousState.positions
    } else {
      // Spec: stability force only applies when state was loaded; a
      // first-time rebuild settles freely.
      layoutConfiguration.stabilityForce = 0
    }
    let layout = GenreMapForceLayout.layout(
      nodes: inputs,
      edges: layoutEdges,
      configuration: layoutConfiguration,
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

    // Phase-3-gate 2026-05-20: pick the **heaviest community** as the
    // default viewport centre. "Heaviest" = the community with the
    // largest summed member weight; deterministic tie-break by id.
    // This is the recognisable-neighbourhood the panel opens on, *not*
    // the world centroid. Empty communities (membership lost to the
    // long tail) are excluded.
    let weightByGenre = Dictionary(uniqueKeysWithValues: mapNodes.map {
      ($0.genre, $0.weight)
    })
    let heaviestCommunity = communities
      .filter { !$0.members.isEmpty }
      .max { lhs, rhs in
        let lhsWeight = lhs.members.reduce(0.0) { $0 + (weightByGenre[$1] ?? 0) }
        let rhsWeight = rhs.members.reduce(0.0) { $0 + (weightByGenre[$1] ?? 0) }
        if lhsWeight != rhsWeight { return lhsWeight < rhsWeight }
        return lhs.id > rhs.id
      }
    let defaultCentre = heaviestCommunity?.centroid ?? CGPoint(
      x: bounds.midX,
      y: bounds.midY,
    )

    // Phase 6: strand-id + colour matching. Re-key every output strand's
    // `colourID` (and label / tokens, if not algorithmically generated
    // this pass) to the predecessor's stable identity when the strand
    // matches a persisted predecessor at composite-Jaccard ≥ 0.5.
    let strandMatching = matchStrandsToPrevious(
      strands: strands,
      previousState: previousState,
    )
    let recolouredStrands = applyStrandMatching(
      strands: strands,
      matching: strandMatching,
    )

    let model = GenreMapModel(
      nodes: mapNodes,
      layoutEdges: layoutEdges,
      communities: communities,
      worldBounds: bounds,
      defaultCentre: defaultCentre,
      strands: recolouredStrands,
      routedStrands: [:],
      // Bump on every fresh build — the routing actor invalidates its
      // cache when `model.layoutRevision` changes, so a re-Analyze
      // forces a routing recompute even if the strand set happens to
      // be byte-identical. Phase 6: also stamp the persisted revision
      // forward (the bumped revision is what the next loaded state
      // reads back).
      layoutRevision: nextRevision,
    )

    // Phase 6: community-id matching across three resolutions. For
    // matched communities the new small-int id is mapped back to the
    // predecessor's stringified id; new communities mint a `new-N`
    // id off the new partition's algorithmic small-int. Runs Louvain
    // a second + third time over the SAME layout edges at γ=0.4
    // (coarse) and γ=1.8 (fine); the medium pass is the partition
    // the main pipeline already computed.
    let communityMatching = matchCommunitiesAtAllResolutions(
      nodes: nodes,
      mediumPartition: partition,
      layoutEdges: layoutEdges,
      previousState: previousState,
    )

    let stateRows = makeStateRows(
      nodes: mapNodes,
      strandsByGenre: strandIDsByGenre(recolouredStrands),
      communityMatching: communityMatching,
      revision: nextRevision,
    )
    let strandRows = makeStrandRows(
      strands: recolouredStrands,
      matching: strandMatching,
      revision: nextRevision,
    )

    return BuildResult(
      model: model,
      stateRows: stateRows,
      strandRows: strandRows,
    )
  }

  /// Run the Phase-6 community-matching pass at all three resolutions.
  /// Returns, per genre, the stringified community ids the persisted
  /// state should record. Matched ids inherit the predecessor's string;
  /// new ids carry a `new-N` prefix so they're visibly disjoint.
  static func matchCommunitiesAtAllResolutions(
    nodes: [GenreNode],
    mediumPartition: [String: Int],
    layoutEdges: [GenreMapEdge],
    previousState: GenreMapPersistedState?,
  ) -> [String: GenreMapPersistedCommunityTriple] {
    let nodeNames = Set(nodes.map(\.genre))
    let louvainEdges = layoutEdges.map {
      GenreMapLouvain.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let coarse = GenreMapLouvain.detect(
      nodes: Array(nodeNames),
      edges: louvainEdges,
      gamma: 0.4,
    )
    let fine = GenreMapLouvain.detect(
      nodes: Array(nodeNames),
      edges: louvainEdges,
      gamma: 1.8,
    )

    let coarseIDs = matchOneResolution(
      newPartition: coarse,
      keyPath: \.coarse,
      previousState: previousState,
    )
    let mediumIDs = matchOneResolution(
      newPartition: mediumPartition,
      keyPath: \.medium,
      previousState: previousState,
    )
    let fineIDs = matchOneResolution(
      newPartition: fine,
      keyPath: \.fine,
      previousState: previousState,
    )

    var triples = [String: GenreMapPersistedCommunityTriple](
      minimumCapacity: nodes.count
    )
    for node in nodes {
      triples[node.genre] = GenreMapPersistedCommunityTriple(
        coarse: coarseIDs[node.genre] ?? "new-\(coarse[node.genre] ?? 0)",
        medium: mediumIDs[node.genre] ?? "new-\(mediumPartition[node.genre] ?? 0)",
        fine: fineIDs[node.genre] ?? "new-\(fine[node.genre] ?? 0)",
      )
    }
    return triples
  }

  /// Match each new strand to its best predecessor (or `nil` ⇒ mint
  /// fresh). Returns a `newStrandID -> persistedStrandID` map.
  static func matchStrandsToPrevious(
    strands: [GenreMapStrandInference.Strand],
    previousState: GenreMapPersistedState?,
  ) -> [Int: String] {
    guard
      let previousState,
      !previousState.strandRowByID.isEmpty
    else {
      return [:]
    }
    // The "old strand member set" for matching is the union of every
    // genre that recorded this strand id in its persisted `strand_ids`.
    // The "path pairs" are NOT persisted in v9 (paths are large and
    // re-derived on every rebuild) — so we fall back to member-Jaccard
    // alone for matching at this scale. The composite score reduces
    // to `0.6 · member-Jaccard` when path pairs are unknown; the
    // threshold 0.5 is therefore tighter (matches require a ~85 %
    // member overlap). That is the conservative direction; the spec
    // tolerates "below threshold → mint a new id".
    var oldMembers = [String: Set<String>]()
    for (genre, strandIDs) in previousState.strandIDsByGenre {
      for id in strandIDs {
        oldMembers["\(id)", default: []].insert(genre)
      }
    }
    let oldEntries = previousState.strandRowByID.keys.map { strandID in
      (
        id: strandID,
        members: oldMembers[strandID] ?? [],
        pathPairs: Set<GenreMapPersistence.PathPair>(),
      )
    }
    let newEntries = strands.map { strand in
      (
        id: strand.id,
        members: Set(strand.memberGenres),
        pathPairs: GenreMapPersistence.consecutivePairs(strand.pathStations),
      )
    }
    return GenreMapPersistence.matchStrands(
      newStrands: newEntries,
      oldStrands: oldEntries,
    )
  }

  /// Apply the matching: every matched strand inherits the
  /// predecessor's persisted `colourID` (recovered from the saved
  /// palette index — see `stockPalette` ↔ renderer palette mapping).
  /// Branches continue to mirror their parent's colour.
  static func applyStrandMatching(
    strands: [GenreMapStrandInference.Strand],
    matching: [Int: String],
  ) -> [GenreMapStrandInference.Strand] {
    guard !matching.isEmpty else { return strands }
    // Resolve matched parents first so a branch can read the colour
    // its (possibly-recoloured) parent now sports.
    var byID = Dictionary(uniqueKeysWithValues: strands.map { ($0.id, $0) })
    for strand in strands {
      guard let predecessor = matching[strand.id] else { continue }
      // The persisted "colour" id is just `Int(predecessor)` when the
      // predecessor was minted from the small-int palette in a prior
      // run; the renderer palette has 12 slots so we modulo for safety.
      if let colourID = Int(predecessor) {
        byID[strand.id]?.colourID = colourID
      }
    }
    // Pass 2: branches mirror their parent's (possibly-shifted) colour.
    for strand in strands where strand.isBranch {
      if
        let parent = strand.parentStrandID,
        let parentColour = byID[parent]?.colourID
      {
        byID[strand.id]?.colourID = parentColour
      }
    }
    return strands.map { byID[$0.id] ?? $0 }
  }

  /// Phase 6 state-row construction. Emits one row per genre (the
  /// `genre_node` cardinality), strand membership rendered as the
  /// JSON-array string the v9 column expects.
  static func makeStateRows(
    nodes: [GenreMapNode],
    strandsByGenre: [String: [Int]],
    communityMatching: [String: GenreMapPersistedCommunityTriple],
    revision: Int,
  ) -> [GenreMapStateRow] {
    let now = Int64(Date.now.timeIntervalSince1970)
    return nodes.map { node in
      GenreMapStateRow(
        genre: node.genre,
        x: Double(node.position.x),
        y: Double(node.position.y),
        communityCoarse: communityMatching[node.genre]?.coarse
          ?? "new-\(node.communityID)",
        communityMedium: communityMatching[node.genre]?.medium
          ?? "new-\(node.communityID)",
        communityFine: communityMatching[node.genre]?.fine
          ?? "new-\(node.communityID)",
        strandIds: GenreMapPersistence.encodeStrandIDs(
          strandsByGenre[node.genre] ?? []
        ),
        updatedAt: now,
        revision: revision,
      )
    }
  }

  /// Phase 6 strand-row construction. One row per *main* strand (no
  /// branches — branches inherit their parent's persisted appearance
  /// at render time via `parentStrandID`).
  static func makeStrandRows(
    strands: [GenreMapStrandInference.Strand],
    matching: [Int: String],
    revision: Int,
  ) -> [GenreMapStrandRow] {
    strands
      .filter { !$0.isBranch }
      .map { strand in
        // Persist the (possibly-inherited) palette slot as the
        // "colour" integer. The spec calls it ARGB-packed, but the
        // renderer's source of truth is the palette index; storing
        // that index satisfies the "stable colour" invariant directly.
        let strandID = matching[strand.id] ?? "\(strand.id)"
        return GenreMapStrandRow(
          strandID: strandID,
          colour: Int64(strand.colourID),
          labelTokens: GenreMapPersistence.encodeLabelTokens(strand.tokens),
          revision: revision,
        )
      }
  }

  /// Strand membership inverted to `genre -> [strand_id]`. Branches
  /// are folded into their parent so the persisted state records the
  /// canonical (parent) ids on each member genre.
  static func strandIDsByGenre(
    _ strands: [GenreMapStrandInference.Strand]
  ) -> [String: [Int]] {
    var byGenre = [String: Set<Int>]()
    for strand in strands {
      let recordedID = strand.isBranch
        ? (strand.parentStrandID ?? strand.id)
        : strand.id
      for member in strand.memberGenres {
        byGenre[member, default: []].insert(recordedID)
      }
    }
    return byGenre.mapValues { $0.sorted() }
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

  /// Match a single resolution's new partition (small-int ids → member
  /// sets) against the persisted state at the same resolution.
  /// Returns `genre -> matchedPredecessorID`; unmatched genres are
  /// absent, so the caller mints a fresh `new-N` id for them.
  private static func matchOneResolution(
    newPartition: [String: Int],
    keyPath: KeyPath<GenreMapPersistedCommunityTriple, String>,
    previousState: GenreMapPersistedState?,
  ) -> [String: String] {
    guard
      let previousState,
      !previousState.communitiesByGenre.isEmpty
    else {
      return [:]
    }
    var newCommunityMembers = [Int: Set<String>]()
    for (genre, id) in newPartition {
      newCommunityMembers[id, default: []].insert(genre)
    }
    var oldCommunityMembers = [String: Set<String>]()
    for (genre, triple) in previousState.communitiesByGenre {
      let id = triple[keyPath: keyPath]
      oldCommunityMembers[id, default: []].insert(genre)
    }
    let matching = GenreMapPersistence.matchCommunities(
      newPartition: newCommunityMembers,
      oldPartition: oldCommunityMembers,
    )
    var byGenre = [String: String]()
    for (genre, newID) in newPartition {
      if let predecessor = matching[newID] {
        byGenre[genre] = predecessor
      }
    }
    return byGenre
  }

}
