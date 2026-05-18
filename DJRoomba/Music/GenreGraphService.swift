import ForceGraph
import Foundation
import Observation

/// The **"Analyze"** action: rebuild the genre co-occurrence graph from all
/// playlists. A thin observable wrapper over `LibraryStore.rebuildGenreGraph`
/// (where the actual CTE-driven graph SQL lives) so the trigger sites and a
/// future "Genre Graph" view bind to one observable surface — exactly the
/// shape of the sibling `GenreImportService` / `ImportService`.
///
/// Unlike `ImportService` / `GenreImportService` this touches **no**
/// MusicKit at all: the graph is derived purely from data already in SQLite
/// (playlist membership + the `song.genre_names` the genre import wrote), so
/// "Analyze" works offline, needs no signing, and is cheap relative to an
/// import. It is therefore safe to (re)run after any change that can alter
/// which genres share a playlist — see `MusicController`'s
/// auto-reanalyze hook.
///
/// Concurrency: `@MainActor @Observable` like the sibling services; it
/// `await`s the `Sendable`, off-main `LibraryStore` (all the work runs in
/// GRDB's serialized writer). The `isAnalyzing` guard coalesces overlapping
/// triggers (e.g. a burst of playlist edits with auto-reanalyze on) into a
/// single in-flight rebuild instead of stacking redundant full scans — the
/// next trigger after it finishes picks up the latest data.
@MainActor
@Observable
final class GenreGraphService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  /// A pure **performance backstop** on how many edges the force view is
  /// ever handed (`ForceGraphView`'s spring sim, edge-crossing detection
  /// and per-frame Canvas redraw all scale with edge count).
  ///
  /// Graph *density* is no longer shaped here. It is controlled upstream,
  /// at analysis time, by `LibraryStore.rebuildGenreGraph`'s two
  /// thresholds (exclude oversized playlists; cap each playlist's
  /// contributed pairs) — the principled, user-tunable place: it shapes the
  /// persisted graph and every consumer, not just this view. The earlier
  /// display-time "strongest-neighbour backbone" heuristic was removed in
  /// that re-evaluation: re-pruning a graph that is already curated at
  /// source only obscured it. This ceiling remains solely so the view
  /// stays responsive if some library still yields an unusually large
  /// curated graph; post-curation it is expected to rarely bind. Keeps the
  /// strongest `displayEdgeMax` edges by weight.
  nonisolated static let displayEdgeMax = 1200

  /// Max rows in the associated-playlists corner card — capped so the
  /// overlay stays a glanceable strip, not a wall (the strongest few are
  /// what matter; the store sorts by strength desc).
  nonisolated static let maxAssociatedPlaylists = 8

  private(set) var isAnalyzing = false
  private(set) var lastError: String?
  /// Edge rows (both directions) written by the last successful analyze —
  /// for verification / a future "N genre links" affordance. `0` is a
  /// legitimate result (no playlist yet shares two genres).
  private(set) var edgeCount = 0

  /// The displayable graph the `GenreGraphPanel` binds to: the canonical
  /// (undirected, de-duplicated) nodes + edges with weights normalised to
  /// `ForceGraphView`'s `0...1`. Rebuilt by `loadGraph()` (on panel appear)
  /// and by `analyze()` after a successful rebuild, so the visualizer
  /// tracks both the manual "Analyze" action and the automatic reanalyze.
  private(set) var displayNodes = [GraphNode<Void>]()
  private(set) var displayEdges = [GraphEdge]()
  /// True only while the initial/refresh read is in flight, so the panel
  /// can show a spinner without flickering it during the (fast) rebuild.
  private(set) var isLoadingGraph = false
  /// Distinguishes "not read yet" from "read, and the graph is empty" so
  /// the panel shows the right state (spinner vs the Analyze empty state).
  private(set) var hasLoadedGraph = false

  /// Pure, `nonisolated` so it's unit-tested without a store or the
  /// MainActor: fold the persisted `genre_edge` half-edges into the node +
  /// edge lists `ForceGraphView` wants. The graph's *density* is shaped
  /// upstream at analysis time (`rebuildGenreGraph`'s thresholds), so this
  /// is a faithful projection, no longer a heuristic re-pruning:
  ///
  /// 1. Keep only the canonical `a < b` half (each undirected edge once).
  /// 2. **Nodes = EVERY genre that co-occurs with anything**, sorted for
  ///    deterministic layout seeding — so a low-degree genre like
  ///    "Americana" stays searchable/centerable even if it has few/no
  ///    edges (`ForceGraphView` is explicitly built for partly-
  ///    disconnected graphs; node count was never the cost — edges are).
  /// 3. Edges = the strongest `maxEdges` by weight — a pure performance
  ///    backstop (`displayEdgeMax`; expected to rarely bind once analysis
  ///    curates density), deterministic (weight desc, then names) so the
  ///    layout seeds stably and tests are exact. Weight is linearly
  ///    normalised `raw / maxRaw` over the kept set, floored at `0.12` so
  ///    the weakest kept link keeps a little spring; a single-edge graph
  ///    maps to `1`.
  nonisolated static func buildDisplayGraph(
    from edges: [GenreEdge],
    maxEdges: Int = displayEdgeMax,
  ) -> (nodes: [GraphNode<Void>], edges: [GraphEdge]) {
    let canonical = edges.filter { $0.genreA < $0.genreB }
    guard !canonical.isEmpty else { return ([], []) }

    // Node set = every genre that co-occurs with anything, so a perf cap
    // on edges never makes a genre unfindable (the "centre americana"
    // guarantee).
    var genres = Set<String>()
    for edge in canonical {
      genres.insert(edge.genreA)
      genres.insert(edge.genreB)
    }
    let graphNodes = genres.sorted().map { GraphNode<Void>(id: $0, label: $0) }

    // Strongest first (deterministic tiebreak), then the perf backstop.
    let ranked = canonical.sorted { lhs, rhs in
      if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
      if lhs.genreA != rhs.genreA { return lhs.genreA < rhs.genreA }
      return lhs.genreB < rhs.genreB
    }
    let kept = ranked.count > maxEdges ? Array(ranked.prefix(maxEdges)) : ranked
    let maxWeight = kept.map(\.weight).max() ?? 1
    let denominator = Double(max(maxWeight, 1))
    let graphEdges = kept.map { edge in
      GraphEdge(
        a: edge.genreA,
        b: edge.genreB,
        weight: min(1, max(0.12, Double(edge.weight) / denominator)),
      )
    }

    return (graphNodes, graphEdges)
  }

  /// Rebuild the whole graph now. Safe to call repeatedly; a call while a
  /// rebuild is already running is a no-op (the guard) — the graph is
  /// wholesale-derived, so the *next* run after this one already reflects
  /// any data that changed in between. A store failure is surfaced via
  /// `lastError` and never propagates (matching the import services'
  /// tolerate-and-surface posture); it never throws into a trigger site.
  /// The two analysis thresholds are passed in (not read here) because
  /// they live in `UserPreferencesStore`, which `MusicController` owns —
  /// the same way it owns the `autoReanalyze` mirror. Every trigger
  /// (the ⌥⌘A menu action and the auto-reanalyze hook) routes the current
  /// preference values through here into the store SQL.
  func analyze(maxPlaylistTracks: Int, maxPairsPerPlaylist: Int) async {
    guard !isAnalyzing else { return }
    isAnalyzing = true
    lastError = nil
    defer { isAnalyzing = false }
    do {
      edgeCount = try await store.rebuildGenreGraph(
        maxPlaylistTracks: maxPlaylistTracks,
        maxPairsPerPlaylist: maxPairsPerPlaylist,
      )
      // Refresh the displayable graph in the SAME call so the panel
      // updates after both the manual action and the auto-reanalyze
      // (which routes through `analyze()`), with no separate trigger.
      try await reloadDisplayGraph()
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Playlists associated with `genre`, or — when `neighbor` is given —
  /// only those pertinent to the `genre ↔ neighbor` edge. A thin pass to
  /// the store; failures yield `[]` (the card just hides) and never throw
  /// into the view, matching this service's tolerate-and-surface posture.
  func associatedPlaylists(
    genre: String,
    neighbor: String?,
  ) async -> [PlaylistAssociation] {
    do {
      return try await store.associatedPlaylists(
        genre: genre,
        neighbor: neighbor,
        limit: Self.maxAssociatedPlaylists,
      )
    } catch {
      lastError = error.localizedDescription
      return []
    }
  }

  /// Read the persisted graph into the displayable form (no rebuild) — the
  /// panel's `.task` calls this so a graph built in a previous session / by
  /// an earlier auto-reanalyze shows immediately without forcing a fresh
  /// (and possibly redundant) `Analyze`. A failure surfaces via `lastError`
  /// and never throws into the view.
  func loadGraph() async {
    isLoadingGraph = true
    defer { isLoadingGraph = false }
    do {
      try await reloadDisplayGraph()
    } catch {
      lastError = error.localizedDescription
    }
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore

  /// Shared body of `analyze()`/`loadGraph()`: one read + the pure fold,
  /// then publish. Throws so each caller applies its own `lastError`
  /// posture (analyze already owns the catch; loadGraph wraps it).
  private func reloadDisplayGraph() async throws {
    let stored = try await store.genreGraphEdges()
    let built = Self.buildDisplayGraph(from: stored)
    displayNodes = built.nodes
    displayEdges = built.edges
    hasLoadedGraph = true
  }

}
