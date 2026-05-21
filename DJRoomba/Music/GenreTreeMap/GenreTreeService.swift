import CoreGraphics
import Foundation
import Observation

// MARK: - GenreTreeService

/// The trunk-tree view's binding target (`plans/son-of-genre-map.md`
/// Phase B). A thin `@MainActor @Observable` that:
///
/// 1. Reads `genre_node` + `genre_edge_evidence` (via `LibraryStore`).
/// 2. Pulls the medium-resolution Louvain partition out of an
///    in-memory `GenreMapModel` (the metro substrate already builds
///    it). When the metro service hasn't been built yet, this service
///    asks it to load first — community detection still lives in the
///    metro builder so we don't run Louvain twice.
/// 3. Runs the pure `GenreTreeBuilder` ⇒ trunk + BFS forest.
/// 4. Runs the pure `GenreTreeLayout` ⇒ world-space positions + curves.
/// 5. Surfaces a `GenreTreeRenderModel` the panel binds to.
///
/// **No schema change**, reads only. **No background actor** — the
/// pure pipeline is O(n + e) and finishes in tens of milliseconds on
/// the real library. The main thread handles it.
///
/// `metric` is published so the Debug menu's "Trunk Selection Metric"
/// toggle can flip it live; the view-layer re-runs the Phase A
/// builder + Phase B layout on each change without touching SQLite.
@MainActor
@Observable
final class GenreTreeService {

  // MARK: Lifecycle

  init(store: LibraryStore, mapService: GenreMapService) {
    self.store = store
    self.mapService = mapService
  }

  // MARK: Internal

  /// Default trunk-selection metric (`.highestTransferness`). Picks
  /// the most-connective member of each community as its trunk; the
  /// plan documents this as the most-defensible visual anchor
  /// (bridges, not generic giants). User flips via the Debug menu;
  /// after live verification the user names the eventual default.
  static let defaultMetric = TrunkSelectionMetric.highestTransferness

  /// True while the layout pipeline is running. Coalesces re-entrancy
  /// (the metric toggle, a re-analyze, a config tweak — a second
  /// `build()` during one in flight is a no-op).
  private(set) var isBuilding = false
  /// Last error, or `nil`. Surfaced to the panel as a fail-soft chip.
  private(set) var lastError: String?

  /// The render model the panel binds to. `nil` ⇒ "not built yet"
  /// (panel shows an empty state with an Analyze CTA).
  private(set) var renderModel: GenreTreeRenderModel?

  /// User-flipped trunk-selection metric. Bound through `Bindable` in
  /// the Debug menu; `didSet` re-runs the pipeline so the flip is
  /// visible immediately without a re-import / re-analyze.
  var metric: TrunkSelectionMetric = GenreTreeService.defaultMetric {
    didSet { Task { await rebuild() } }
  }

  /// Pure Phase A + Phase B compose. Extracted as a `nonisolated`
  /// static so the metric-toggle hot path can rerun without touching
  /// `store` again — just re-derive against the existing
  /// `mapService.model`. Tests can call this on fixtures with no
  /// LibraryStore in sight.
  nonisolated static func assembleRenderModel(
    nodes: [GenreNode],
    evidence: [GenreEdgeEvidence],
    communityByGenre: [String: Int],
    metric: TrunkSelectionMetric,
    layoutConfiguration: GenreTreeLayout.Configuration = GenreTreeLayout.Configuration(),
  ) -> GenreTreeRenderModel {
    let topology = GenreTreeBuilder.build(
      nodes: nodes,
      evidence: evidence,
      communityByGenre: communityByGenre,
      metric: metric,
    )
    let layout = GenreTreeLayout.layout(
      model: topology,
      configuration: layoutConfiguration,
    )
    let backEdges = Self.computeBackEdges(
      evidence: evidence,
      topology: topology,
      layout: layout,
    )
    return GenreTreeRenderModel(
      topology: topology,
      layout: layout,
      backEdges: backEdges,
    )
  }

  /// Every `genre_edge_evidence` edge that the MST dropped, projected
  /// to world coordinates. The renderer draws these as `~6 %`-opacity
  /// straight lines. Endpoint positions come from the placed-node
  /// map; edges whose endpoints aren't placed (orphans) are dropped.
  nonisolated static func computeBackEdges(
    evidence: [GenreEdgeEvidence],
    topology _: GenreTreeModel,
    layout: GenreTreeLayout.Output,
  ) -> [BackEdgeLayer.BackEdgeSegment] {
    let placedByGenre = Dictionary(
      uniqueKeysWithValues: layout.placedNodes.map { ($0.genre.name, $0.position) }
    )
    // MST edges = the canonical-half edges kept by Kruskal. The tree
    // pipeline doesn't surface those raw, but every parent→child
    // relationship in the placed forest is exactly an MST edge. We
    // build the kept set from `placedNodes[*].parentGenre` ↔ self.
    var keptEdges = Set<EdgeKey>()
    for placed in layout.placedNodes {
      guard let parent = placed.parentGenre else { continue }
      keptEdges.insert(EdgeKey(a: min(parent, placed.genre.name), b: max(parent, placed.genre.name)))
    }
    var segments = [BackEdgeLayer.BackEdgeSegment]()
    segments.reserveCapacity(evidence.count)
    for row in evidence {
      let key = EdgeKey(a: min(row.genreA, row.genreB), b: max(row.genreA, row.genreB))
      if keptEdges.contains(key) { continue }
      guard
        let start = placedByGenre[row.genreA],
        let end = placedByGenre[row.genreB]
      else { continue }
      segments.append(BackEdgeLayer.BackEdgeSegment(
        start: start,
        end: end,
        totalWeight: row.totalWeight,
      ))
    }
    return segments
  }

  /// Build the tree from scratch — reads `genre_node` +
  /// `genre_edge_evidence`, runs Phase A + Phase B, surfaces the
  /// render model. Idempotent under concurrent triggers.
  func build() async {
    guard !isBuilding else { return }
    isBuilding = true
    lastError = nil
    defer { isBuilding = false }
    do {
      // Reuse the metro service's load path so community detection
      // doesn't run twice. If the metro hasn't been built yet (first
      // launch on a fresh DB), load it — that's a single SQL read +
      // Louvain pass, the same cost the metro panel would pay.
      if mapService.model == nil {
        await mapService.load(measureLabel: GenreMapService.defaultMeasureLabel)
      }
      guard let mapModel = mapService.model else {
        // No substrate yet — empty state. Not an error.
        renderModel = nil
        return
      }
      let nodes = try await store.genreMapNodes()
      let evidence = try await store.genreMapEvidence()
      let communityByGenre = mapModel.nodes.reduce(into: [String: Int]()) { out, node in
        out[node.genre] = node.communityID
      }
      renderModel = Self.assembleRenderModel(
        nodes: nodes,
        evidence: evidence,
        communityByGenre: communityByGenre,
        metric: metric,
      )
    } catch {
      lastError = error.localizedDescription
    }
  }

  // MARK: Private

  /// Internal canonical-half edge key for back-edge bookkeeping.
  private struct EdgeKey: Hashable {
    var a: String
    var b: String
  }

  @ObservationIgnored private let store: LibraryStore
  @ObservationIgnored private let mapService: GenreMapService

  /// Re-run the Phase A + Phase B pipeline against the existing
  /// `mapService.model` (no SQL hit). Used by the metric `didSet`.
  /// Falls back to a full `build()` if the substrate isn't loaded
  /// yet.
  private func rebuild() async {
    guard let mapModel = mapService.model else {
      await build()
      return
    }
    guard !isBuilding else { return }
    isBuilding = true
    lastError = nil
    defer { isBuilding = false }
    do {
      let nodes = try await store.genreMapNodes()
      let evidence = try await store.genreMapEvidence()
      let communityByGenre = mapModel.nodes.reduce(into: [String: Int]()) { out, node in
        out[node.genre] = node.communityID
      }
      renderModel = Self.assembleRenderModel(
        nodes: nodes,
        evidence: evidence,
        communityByGenre: communityByGenre,
        metric: metric,
      )
    } catch {
      lastError = error.localizedDescription
    }
  }

}

// MARK: - GenreTreeRenderModel

/// The bundled view-binding payload. Topology + geometric layout +
/// the back-edge list — everything the panel needs in one struct so
/// the view's body can be a pure projection.
struct GenreTreeRenderModel: Equatable, Sendable {
  var topology: GenreTreeModel
  var layout: GenreTreeLayout.Output
  var backEdges: [BackEdgeLayer.BackEdgeSegment]
}
