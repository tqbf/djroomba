import CoreGraphics
import Foundation
import Observation

// MARK: - GenreMapService

/// Substrate loader for the tree view. Phase E of
/// `plans/son-of-genre-map.md` retires the metro renderer + every
/// piece of state that fed it (force-layout positions, obstacle-aware
/// routing, corridor bundling, strand inference). What survives in
/// this service is the **read path** — community detection +
/// transferness + cross-resolution Louvain matching — that the tree
/// view's `GenreTreeService` reads through.
///
/// A thin `@MainActor @Observable` wrapper over `LibraryStore`
/// + the pure `GenreMapBuilder` pipeline. `isAnalyzing` coalesces
/// triggers; failures surface via `lastError`, never thrown.
@MainActor
@Observable
final class GenreMapService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  /// True while a build is in flight. A second `build()` while one is
  /// running is a no-op.
  private(set) var isAnalyzing = false
  /// Last error, or `nil`. Surfaced to UI as a fail-soft chip;
  /// rebuilds never throw into call sites.
  private(set) var lastError: String?

  /// The current substrate model. `nil` ⇒ "not built yet". The tree
  /// view's `GenreTreeService` reads `model.nodes[*].communityID` to
  /// drive trunk selection + `model.layoutEdges` to drive Kruskal.
  private(set) var model: GenreMapModel?

  /// Wall time of the most recent `loadGenreMapState` read. Surfaced
  /// for the PROGRESS.md persistence-perf entry (Phase 6 target:
  /// <50 ms on a 200-genre library).
  private(set) var lastPersistedReadSeconds: TimeInterval = 0

  /// Default measurement closure — kept around for source/binary
  /// compatibility with the metro era's call sites, where the panel
  /// passed a `measureLabel` closure shaping label-AABB repulsion.
  /// Phase E retires the force layout; `measureLabel` is no longer
  /// consulted. The closure remains so existing `await
  /// service.load(measureLabel:)` / `service.build(measureLabel:)`
  /// call sites keep compiling unchanged while the call signature
  /// settles into the Phase E posture.
  nonisolated static func defaultMeasureLabel(
    text _: String,
    fontSize _: CGFloat,
    kind _: GenreMapNodeKind,
  ) -> CGSize {
    .zero
  }

  /// (Re)build the substrate from the live DB. Idempotent under
  /// concurrent triggers (the `isAnalyzing` guard). The
  /// `measureLabel` parameter is unused in Phase E but kept for
  /// call-site compatibility — see `defaultMeasureLabel`.
  func build(
    measureLabel _: @Sendable @escaping (
      _ text: String,
      _ fontSize: CGFloat,
      _ kind: GenreMapNodeKind,
    ) -> CGSize = defaultMeasureLabel
  ) async {
    guard !isAnalyzing else { return }
    isAnalyzing = true
    lastError = nil
    defer { isAnalyzing = false }
    do {
      let readStart = Date.now
      let previousState = try await store.loadGenreMapState()
      lastPersistedReadSeconds = Date.now.timeIntervalSince(readStart)

      _ = try await store.rebuildGenreMap()
      let nodes = try await store.genreMapNodes()
      let evidence = try await store.genreMapEvidence()
      let result = GenreMapBuilder.build(
        nodes: nodes,
        evidence: evidence,
        previousState: previousState,
      )
      model = result.model
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Read a previously-rebuilt substrate without re-running the SQL
  /// rebuild — the panel's `.task` calls this so a substrate
  /// populated in an earlier session shows immediately.
  func load(
    measureLabel _: @Sendable @escaping (
      _ text: String,
      _ fontSize: CGFloat,
      _ kind: GenreMapNodeKind,
    ) -> CGSize = defaultMeasureLabel
  ) async {
    do {
      let previousState = try await store.loadGenreMapState()
      let nodes = try await store.genreMapNodes()
      let evidence = try await store.genreMapEvidence()
      guard !nodes.isEmpty else { return }
      let result = GenreMapBuilder.build(
        nodes: nodes,
        evidence: evidence,
        previousState: previousState,
      )
      model = result.model
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Representative artists / albums for an ordinary genre. Reads
  /// `song_genre` via the indexed `(genre, artist_key)` /
  /// `(genre, album_key)` joins. Returned in a single tuple so the
  /// panel's call site is one `await`.
  func representativeEvidence(
    for genre: String,
    limit: Int = 25,
  ) async -> GenreMapRepresentativeEvidence? {
    do {
      let artists = try await store.genreMapTopArtists(for: genre, limit: limit)
      let albums = try await store.genreMapTopAlbums(for: genre, limit: limit)
      return GenreMapRepresentativeEvidence(
        topArtists: artists,
        topAlbums: albums,
      )
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// Paginated shared evidence between two genres for the compare-
  /// mode inspector section. Three channels (artists / albums /
  /// tracks); the same `limit`/`offset` is applied to each channel.
  func compareEvidence(
    between genreA: String,
    and genreB: String,
    limit: Int = 25,
    offset: Int = 0,
  ) async -> GenreMapCompareEvidence? {
    do {
      async let artists = store.genreMapSharedArtists(
        between: genreA,
        and: genreB,
        limit: limit,
        offset: offset,
      )
      async let albums = store.genreMapSharedAlbums(
        between: genreA,
        and: genreB,
        limit: limit,
        offset: offset,
      )
      async let tracks = store.genreMapSharedTracks(
        between: genreA,
        and: genreB,
        limit: limit,
        offset: offset,
      )
      return try await GenreMapCompareEvidence(
        sharedArtists: artists,
        sharedAlbums: albums,
        sharedTracks: tracks,
      )
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore

}

// MARK: - GenreMapRepresentativeEvidence

/// Single-genre evidence — the "what does this genre look like?"
/// payload for the inspector's single-genre mode.
struct GenreMapRepresentativeEvidence: Equatable, Sendable {
  var topArtists: [GenreMapEvidenceItem]
  var topAlbums: [GenreMapEvidenceItem]
}

// MARK: - GenreMapCompareEvidence

/// Two-genre evidence — the "why is this relationship here?" payload
/// for the inspector's compare mode. Three channels; one pagination
/// cursor per channel.
struct GenreMapCompareEvidence: Equatable, Sendable {
  var sharedArtists: [GenreMapEvidenceItem]
  var sharedAlbums: [GenreMapEvidenceItem]
  var sharedTracks: [GenreMapEvidenceItem]
}
