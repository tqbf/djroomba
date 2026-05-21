import CoreGraphics
import Foundation

// MARK: - GenreMapBuilder

/// Pure pipeline that turns the persisted v7 `genre_node` +
/// `genre_edge_evidence` rows into a `GenreMapModel` the tree view
/// substrate consumes (`plans/son-of-genre-map.md` Phase E).
///
/// The metro-era responsibilities that retired in Phase E:
///
/// - **Force layout** — replaced by `GenreTreeLayout`'s deterministic
///   geometric placement. `GenreMapNode.position` is left at `.zero`
///   here; the tree layout writes the real coordinates onto
///   `GenreTreeLayout.PlacedNode` instead.
/// - **Strand inference** — the metro grammar retires entirely.
/// - **Strand persistence matching** — community matching survives
///   (preserves trunk identity across re-import); strand matching
///   retires with the strands.
///
/// What survives is the **substrate** the tree view reads:
///
/// 1. Candidate filtering + mutual-kNN ∪ MST ∪ inter-community bridges
///    (`GenreMapLayoutGraph`).
/// 2. Multi-resolution Louvain community detection (`GenreMapLouvain`).
///    Medium resolution (γ=0.85) is the trunk-selection key; coarse +
///    fine resolutions are still computed for persistence continuity.
/// 3. Transferness scoring (`GenreMapTransferness`) — feeds the
///    `.highestTransferness` trunk metric.
/// 4. Community-id matching against the previous persisted state
///    (`GenreMapPersistence.matchCommunities`).
///
/// Everything is `nonisolated` + free of mutable globals.
enum GenreMapBuilder {

  // MARK: Internal

  struct Configuration: Sendable {
    /// Edge composite-weight floor below which a candidate is discarded
    /// before mutual-kNN.
    var minEdgeWeight = 0.0001
    /// Per-node top fraction of edges to keep when filtering candidates
    /// before mutual-kNN. Low-degree nodes always keep their full set.
    var topFractionPerNode = 0.50
    /// Minimum kept candidates per node, regardless of `topFractionPerNode`.
    var minPerNodeFloor = 6
    /// Louvain resolution for the medium-resolution community pass
    /// (γ=0.85). Trunks key off this resolution.
    var mediumGamma = 0.85
  }

  /// Build result — the substrate model PLUS the Phase-6 persistence
  /// state-row payload (one row per genre). Positions on the rows are
  /// `.zero` here; `GenreTreeService` overrides each row's `(x, y)`
  /// with the tree-layout placement before writing to SQLite (Phase E
  /// repurpose of `v9.genreMapState.x` / `.y` from force-layout
  /// semantics to tree-layout semantics).
  ///
  /// The retired strand-matching pass leaves no strand rows behind —
  /// callers write `strands: []` when persisting (additive deprecation
  /// of `genre_map_strand` per `plans/son-of-genre-map.md` Phase E).
  struct BuildResult: Sendable {
    var model: GenreMapModel
    var stateRows: [GenreMapStateRow]
  }

  /// Build the substrate model from pure inputs. Phase E retains the
  /// `previousState` parameter so the community-Jaccard matching pass
  /// can preserve trunk identity across re-import.
  static func build(
    nodes: [GenreNode],
    evidence: [GenreEdgeEvidence],
    previousState: GenreMapPersistedState? = nil,
    configuration: Configuration = Configuration(),
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
          layoutRevision: nextRevision,
        ),
        stateRows: [],
      )
    }

    // 1) Filter candidate edges (adaptive per-node top-fraction).
    let nodeNames = Set(nodes.map(\.genre))
    let layoutCandidates = filterCandidates(
      evidence: evidence,
      nodeNames: nodeNames,
      configuration: configuration,
    )

    // 2) Initial layout graph (mutual-kNN ∪ MST).
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

    // 3) Detect initial communities on mutual-kNN ∪ MST to admit
    // inter-community bridge edges.
    let initialLouvainEdges = initialLayoutCandidates.map {
      GenreMapLouvain.Edge(a: $0.a, b: $0.b, weight: $0.weight)
    }
    let initialPartition = GenreMapLouvain.detect(
      nodes: Array(nodeNames),
      edges: initialLouvainEdges,
      gamma: configuration.mediumGamma,
    )

    // 3a) Admit the strongest inter-community edges that aren't
    // already in the mutual-kNN ∪ MST set.
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

    // 3b) Re-run Louvain on the widened graph; that's the partition
    // hulls / transferness / the tree view's trunk selection all read.
    let louvainEdges = layoutEdges.map {
      GenreMapLouvain.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let partition = GenreMapLouvain.detect(
      nodes: Array(nodeNames),
      edges: louvainEdges,
      gamma: configuration.mediumGamma,
    )

    // 4) Transferness (Phase 2) — feeds the `.highestTransferness`
    // trunk metric + the inspector's transferness% display. Phase E
    // retires the `strandCount` channel; the composite sums to less
    // than 1.0 by 10 %, so `GenreMapTransferness` renormalises.
    let transferEdges = layoutEdges.map {
      (a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let transfernessResult = GenreMapTransferness.score(
      nodes: nodes.map { (genre: $0.genre, weight: $0.weight) },
      edges: transferEdges,
      communities: partition,
    )

    // 5) Assemble nodes — positions left at `.zero`; the tree layout
    // overrides. Label-size fields are zero too; only the metro
    // renderer cared, and it's gone.
    var mapNodes = [GenreMapNode]()
    mapNodes.reserveCapacity(nodes.count)
    for node in nodes {
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
        position: .zero,
        labelSize: .zero,
        transferness: composite,
        nodeKind: kind,
        transfernessInputs: inputs,
      ))
    }

    // 6) Communities (deterministic sort of members).
    var membersByCommunity = [Int: [String]]()
    for node in nodes {
      let id = partition[node.genre] ?? 0
      membersByCommunity[id, default: []].append(node.genre)
    }
    let communities = membersByCommunity.keys.sorted().map { id -> GenreMapCommunity in
      let members = membersByCommunity[id]?.sorted() ?? []
      return GenreMapCommunity(id: id, members: members, centroid: .zero)
    }

    // 7) Phase 6 community-id matching at three resolutions.
    let communityMatching = matchCommunitiesAtAllResolutions(
      nodes: nodes,
      mediumPartition: partition,
      layoutEdges: layoutEdges,
      previousState: previousState,
    )

    // 8) State rows for persistence — positions are `.zero` at this
    // layer; `GenreTreeService` overwrites them with the tree layout
    // coordinates before writing. Strand columns retire (additive
    // deprecation): we emit an empty JSON array.
    let stateRows = makeStateRows(
      nodes: mapNodes,
      communityMatching: communityMatching,
      revision: nextRevision,
    )

    let model = GenreMapModel(
      nodes: mapNodes,
      layoutEdges: layoutEdges,
      communities: communities,
      worldBounds: .zero,
      defaultCentre: .zero,
      layoutRevision: nextRevision,
    )

    return BuildResult(model: model, stateRows: stateRows)
  }

  /// Phase 6 community-matching at all three Louvain resolutions —
  /// coarse (γ=0.4), medium (γ=0.85, already computed), fine (γ=1.8).
  /// Matched ids inherit the predecessor's string; unmatched genres
  /// mint a fresh `new-N` id.
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

  /// Phase 6 state-row construction. One row per genre. Strand ids
  /// retire under Phase E of `plans/son-of-genre-map.md`; the column
  /// is left in place (additive deprecation) with an empty JSON array
  /// payload.
  static func makeStateRows(
    nodes: [GenreMapNode],
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
        strandIds: GenreMapPersistence.encodeStrandIDs([]),
        updatedAt: now,
        revision: revision,
      )
    }
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
