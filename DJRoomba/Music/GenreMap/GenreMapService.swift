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

  /// Geographic-epsilon for the drag-recommit ⇒ routing-rerun check
  /// (`plans/genre-metro-map.md` Phase 4, step 5). A drag whose final
  /// landing position moved less than `geographicEpsilon` from the
  /// node's pre-drag position does NOT bump `layoutRevision` —
  /// routing's cache hit covers the no-op micro-shuffle.
  nonisolated static let geographicEpsilon: CGFloat = 6.0

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

  /// Phase 4 routing instrumentation (`plans/genre-metro-map.md` Phase 4
  /// success criteria). Updated after each `GenreMapRoutingActor.route`
  /// reply; surfaced via the side-panel footer + `PROGRESS.md` perf gate.
  private(set) var lastRoutingElapsedSeconds: TimeInterval = 0
  private(set) var lastRoutingCorridorCount = 0
  private(set) var lastRoutingBundledCorridorCount = 0
  private(set) var lastRoutingMaxStrandsPerCorridor = 0
  private(set) var lastRoutingCrossingCount = 0
  private(set) var lastRoutingTransferCrossingCount = 0
  /// `true` while a Phase-4 routing pass is in flight. Renderer keeps
  /// rendering the previously-routed polylines (or the Phase-3 fallback)
  /// during the pass — no main-thread block, no spinner overlay.
  private(set) var isRouting = false

  /// System-font-ish label sizing approximation — character count × an
  /// average glyph advance for the font size, plus pill padding. Real
  /// rendering uses SwiftUI's `Text` so the label is pixel-perfect; the
  /// layout pipeline only needs an *approximate* AABB for repulsion, and
  /// approximation lets the rebuild stay pure / off-main / unit-testable
  /// without round-tripping to `NSAttributedString.size()` on the main
  /// actor.
  ///
  /// `kind` shapes the AABB: junction + transferStation pills render a
  /// leading SF Symbol inside the existing pill chrome, so their drawn
  /// width is `fontSize * 0.85` (glyph) + 4pt (HStack spacing) wider
  /// than an ordinary pill. The build path uses this same closure, so
  /// the layout's label-AABB repulsion sees the rectangle the panel
  /// will actually draw — no drift between layout-time and render-time.
  nonisolated static func defaultMeasureLabel(
    text: String,
    fontSize: CGFloat,
    kind: GenreMapNodeKind,
  ) -> CGSize {
    // ~0.56 average glyph advance for system text at the target size,
    // plus 14pt horizontal + 6pt vertical padding for the pill chrome.
    let baseWidth = CGFloat(max(1, text.count)) * fontSize * 0.56 + 18
    let leadingGlyphWidth: CGFloat =
      switch kind {
      case .ordinary: 0
      case .junction,
           .transferStation: fontSize * 0.85 + 4
      }
    let estimatedHeight = fontSize + 12
    return CGSize(width: baseWidth + leadingGlyphWidth, height: estimatedHeight)
  }

  /// (Re)build the map from the live data. Idempotent under concurrent
  /// triggers (the `isAnalyzing` guard). `measureLabel` is injected so
  /// the SwiftUI panel — which owns the typography — can hand the
  /// pipeline real text metrics; tests pass a stub.
  func build(
    measureLabel: @Sendable @escaping (_ text: String, _ fontSize: CGFloat, _ kind: GenreMapNodeKind) -> CGSize
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
      refreshRouting()
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Read a previously-rebuilt map from the store without re-running the
  /// SQL pass — the panel's `.task` calls this so a map populated in an
  /// earlier session shows immediately.
  func load(
    measureLabel: @Sendable @escaping (_ text: String, _ fontSize: CGFloat, _ kind: GenreMapNodeKind) -> CGSize
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
      refreshRouting()
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Evidence-on-demand for the side panel (Phase 2). Reads `selectedGenre`'s
  /// 1-hop neighbours from the current `model` and asks the store for the
  /// top shared artists / albums / tracks across them. Pure read; JIT —
  /// the call site renders a `ProgressView` while this is in flight.
  func evidenceOnDemand(
    for selectedGenre: String,
    perChannelLimit: Int = 8,
  ) async -> GenreMapEvidenceOnDemand? {
    guard let model else { return nil }
    var neighbours = Set<String>()
    for edge in model.layoutEdges {
      if edge.genreA == selectedGenre {
        neighbours.insert(edge.genreB)
      } else if edge.genreB == selectedGenre {
        neighbours.insert(edge.genreA)
      }
    }
    guard !neighbours.isEmpty else {
      return GenreMapEvidenceOnDemand(
        sharedArtists: [],
        sharedAlbums: [],
        sharedTracks: [],
      )
    }
    do {
      return try await store.genreMapEvidenceOnDemand(
        selectedGenre: selectedGenre,
        neighbourGenres: Array(neighbours),
        perChannelLimit: perChannelLimit,
      )
    } catch {
      lastError = error.localizedDescription
      return nil
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

  /// Commit a finished drag — recompute routing if the dragged node
  /// moved beyond `geographicEpsilon`. Called from the panel's
  /// `DragGesture.onEnded`, NOT mid-drag (the live drag affordance
  /// stays on the cheap relaxation pass in `applyDrag`).
  ///
  /// `originalPosition` is the dragged node's position BEFORE the
  /// drag started. Mid-drag the panel calls `applyDrag` repeatedly
  /// to relax neighbours; on release the panel calls this once.
  func commitDrag(
    dragged _: String,
    originalPosition: CGPoint,
    finalPosition: CGPoint,
  ) {
    guard var current = model else { return }
    let dx = finalPosition.x - originalPosition.x
    let dy = finalPosition.y - originalPosition.y
    let distance = sqrt(dx * dx + dy * dy)
    if distance < Self.geographicEpsilon { return }
    // Bump the revision so the routing actor invalidates its cache.
    current.layoutRevision += 1
    model = current
    refreshRouting()
  }

  /// Kick a background routing pass against the current model. The
  /// Phase-3-fallback Catmull-Rom keeps rendering until this reply
  /// lands — no spinner overlay, no main-thread stall.
  func refreshRouting() {
    guard let snapshot = makeRoutingSnapshot() else { return }
    isRouting = true
    Task { [routingActor] in
      let result = await routingActor.route(snapshot)
      await MainActor.run { self.applyRoutingResult(result) }
    }
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore
  @ObservationIgnored private let routingActor = GenreMapRoutingActor()

  /// Apply a finished routing pass onto `model.routedStrands`. Stale
  /// results (`layoutRevision` mismatch) are dropped — a later pass
  /// at the current revision will overwrite.
  private func applyRoutingResult(_ result: GenreMapRoutingActor.Result) {
    guard var current = model else { return }
    guard current.layoutRevision == result.layoutRevision else {
      // A newer revision landed while we were routing — ignore and
      // let the in-flight pass for the newer revision win.
      return
    }
    current.routedStrands = result.routedByStrand
    model = current
    lastRoutingElapsedSeconds = result.elapsedSeconds
    lastRoutingCorridorCount = result.corridorCount
    lastRoutingBundledCorridorCount = result.bundledCorridorCount
    lastRoutingMaxStrandsPerCorridor = result.maxStrandsPerCorridor
    lastRoutingCrossingCount = result.crossingCount
    lastRoutingTransferCrossingCount = result.transferCrossingCount
    isRouting = false
    #if DEBUG
    // Phase-4-gate (2026-05-21): visible-on-stderr perf line, paired
    // with the routing actor's `os_signpost` so the gate can record
    // the median + max drag-release-rebuild ms on the real library
    // without needing `log show` / Console.app.
    let ms = result.elapsedSeconds * 1000
    let nodeCount = current.nodes.count
    let strandCount = current.strands.count
    FileHandle.standardError.write(Data(
      "[GenreMapRouting] revision=\(result.layoutRevision) strands=\(strandCount) nodes=\(nodeCount) corridors=\(result.corridorCount) bundled=\(result.bundledCorridorCount) maxPerCorridor=\(result.maxStrandsPerCorridor) crossings=\(result.crossingCount)/\(result.transferCrossingCount)xfer elapsed=\(String(format: "%.2f", ms))ms\n".utf8
    ))
    #endif
  }

  /// Build a snapshot of the data `GenreMapRouting` needs to recompute.
  /// Returns `nil` when there's no model or no strands.
  private func makeRoutingSnapshot() -> GenreMapRoutingActor.Snapshot? {
    guard let current = model else { return nil }
    guard !current.strands.isEmpty else { return nil }
    let nodes = current.nodes.map { node in
      GenreMapRoutingActor.Snapshot.Node(
        genre: node.genre,
        position: node.position,
        labelSize: node.labelSize,
      )
    }
    return GenreMapRoutingActor.Snapshot(
      layoutRevision: current.layoutRevision,
      strands: current.strands,
      nodes: nodes,
      configuration: GenreMapRouting.Configuration(),
    )
  }

}
