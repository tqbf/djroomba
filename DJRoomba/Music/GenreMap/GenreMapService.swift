import CoreGraphics
import Foundation
import Observation

// MARK: - GenreMapService

/// The genre-metro-map analogue of `GenreGraphService`
/// (`plans/genre-metro-map.md` Phase 1). A thin `@MainActor @Observable`
/// wrapper over `LibraryStore.rebuildGenreMap` + `GenreMapBuilder`.
///
/// Sibling, NOT replacement, of `GenreGraphService`. Phase 1 ships both
/// panels; Phase 6 will consolidate. The store calls underneath are
/// completely orthogonal: the v6 `genre_edge` rebuild runs first (the
/// playlist channel here reads its weights), then this rebuilds the v7
/// substrate and folds it into a `GenreMapModel`.
///
/// Concurrency: same shape as `GenreGraphService`. `isAnalyzing` coalesces
/// triggers; failures are surfaced via `lastError`, never thrown.
@MainActor
@Observable
final class GenreMapService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  /// True while a build is in flight (covers both store SQL + the pure
  /// pipeline). Coalesces re-entrancy: a second `build()` while one is
  /// running is a no-op.
  private(set) var isAnalyzing = false
  /// Last error, or `nil`. Surfaced to UI as a fail-soft chip; rebuilds
  /// never throw into call sites.
  private(set) var lastError: String?

  /// The current model the panel binds to. `nil` ⇒ "not built yet" (the
  /// panel shows an empty state with an Analyze CTA).
  private(set) var model: GenreMapModel?

  /// System-font-ish label sizing approximation — character count × an
  /// average glyph advance for the font size, plus pill padding. Real
  /// rendering uses SwiftUI's `Text` so the label is pixel-perfect; the
  /// layout pipeline only needs an *approximate* AABB for repulsion, and
  /// approximation lets the rebuild stay pure / off-main / unit-testable
  /// without round-tripping to `NSAttributedString.size()` on the main
  /// actor. Override from a view layer that wants pixel-exact metrics by
  /// passing your own closure into `build` / `load`.
  nonisolated static func defaultMeasureLabel(
    text: String,
    fontSize: CGFloat,
  ) -> CGSize {
    // ~0.56 average glyph advance for system text at the target size,
    // plus 14pt horizontal + 6pt vertical padding for the pill chrome.
    let estimatedWidth = CGFloat(max(1, text.count)) * fontSize * 0.56 + 18
    let estimatedHeight = fontSize + 12
    return CGSize(width: estimatedWidth, height: estimatedHeight)
  }

  /// (Re)build the map from the live data. Idempotent under concurrent
  /// triggers (the `isAnalyzing` guard). `measureLabel` is injected so
  /// the SwiftUI panel — which owns the typography — can hand the
  /// pipeline real text metrics; tests pass a stub.
  func build(
    measureLabel: @Sendable @escaping (_ text: String, _ fontSize: CGFloat) -> CGSize
  ) async {
    guard !isAnalyzing else { return }
    isAnalyzing = true
    lastError = nil
    defer { isAnalyzing = false }
    do {
      _ = try await store.rebuildGenreMap()
      let nodes = try await store.genreMapNodes()
      let evidence = try await store.genreMapEvidence()
      let built = GenreMapBuilder.build(
        nodes: nodes,
        evidence: evidence,
        measureLabel: measureLabel,
      )
      model = built
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Read a previously-rebuilt map from the store without re-running the
  /// SQL pass — the panel's `.task` calls this so a map populated in an
  /// earlier session shows immediately.
  func load(
    measureLabel: @Sendable @escaping (_ text: String, _ fontSize: CGFloat) -> CGSize
  ) async {
    do {
      let nodes = try await store.genreMapNodes()
      let evidence = try await store.genreMapEvidence()
      guard !nodes.isEmpty else { return }
      let built = GenreMapBuilder.build(
        nodes: nodes,
        evidence: evidence,
        measureLabel: measureLabel,
      )
      model = built
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Drag affordance: pin `dragged` at `to` and relax its 1-hop layout
  /// neighbours; everything else stays put. Returns nothing — the caller
  /// re-reads `model`. Fast (`O(k²)` for one node's neighbour set) — safe
  /// to call mid-drag.
  func applyDrag(dragged: String, to point: CGPoint) {
    guard var current = model else { return }
    let inputs: [GenreMapForceLayout.InputNode] = current.nodes.map { node in
      GenreMapForceLayout.InputNode(
        id: node.genre,
        weight: node.weight,
        // Use the SAME label rectangle the layout pass measured (cached
        // on the node by `GenreMapBuilder.build`). Previously this path
        // re-approximated a different size, which let drag re-overlap
        // labels the layout had already separated.
        labelSize: node.labelSize,
        communityID: node.communityID,
      )
    }
    var positions = Dictionary(
      uniqueKeysWithValues: current.nodes.map { ($0.genre, $0.position) }
    )
    positions[dragged] = point
    let relaxed = GenreMapForceLayout.relaxDragNeighbours(
      positions: positions,
      dragged: dragged,
      layoutEdges: current.layoutEdges,
      inputs: inputs,
    )
    var updatedNodes = current.nodes
    for index in updatedNodes.indices {
      if let new = relaxed[updatedNodes[index].genre] {
        updatedNodes[index].position = new
      }
    }
    current.nodes = updatedNodes
    // Recompute centroids in-place.
    var byCommunity = [Int: [CGPoint]]()
    for node in updatedNodes {
      byCommunity[node.communityID, default: []].append(node.position)
    }
    current.communities = current.communities.map { community in
      let positions = byCommunity[community.id] ?? []
      var centroid = CGPoint.zero
      for point in positions {
        centroid.x += point.x
        centroid.y += point.y
      }
      if !positions.isEmpty {
        centroid.x /= CGFloat(positions.count)
        centroid.y /= CGFloat(positions.count)
      }
      var copy = community
      copy.centroid = centroid
      return copy
    }
    model = current
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore
}
