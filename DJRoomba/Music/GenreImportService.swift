import Foundation
import MusicKit
import Observation

/// One-way genre enrichment: MusicKit library **albums** → `song.genre_names`
/// in SQLite. A companion to `ImportService` with the same posture (Apple
/// Music is a strictly read source; this never deletes or mutates app-owned
/// data — it only refines one already-imported `song` column via
/// `LibraryStore.applyAlbumGenres`, whose one-way isolation is store-
/// guaranteed and test-verified).
///
/// **Why a separate request type.** On the macOS *library* graph, genre is
/// populated on the `Album` (`MusicLibraryRequest<MusicKit.Album>` →
/// `album.genreNames`, a non-optional `[String]` with real user tags like
/// `["Alt/Goth/Industrial"]`), NOT on the library `Song` (a library `Song`
/// has no `.genres` relationship to even request) nor `Artist` (signed
/// probe, 2026-05-17). So genre cannot ride the existing
/// `playlist.with([.tracks])` fetch — it needs its own bulk Album pass.
/// There is no album entity/table: each album's genre is attributed onto
/// its track rows, where the v4 `genre_names` column already lives.
///
/// **Attribution.** Page `MusicLibraryRequest<Album>`; for each album that
/// actually carries a genre, `album.with([.tracks])`, page its `.tracks`,
/// and unwrap each `Track` to its underlying-item id via the shared
/// `ImportService.underlyingItemID(of:)` — exactly the id
/// `ImportService.song(from:)` already stored as `song.music_item_id`
/// (library namespace by provenance). Accumulate
/// `[musicItemID: genreNames]`, then one `applyAlbumGenres`. Attribution is
/// album-granular by design (a compilation gets one genre; a track on
/// multiple albums takes the last-walked album's genre — acceptable, the
/// data is album-level to begin with).
///
/// Concurrency: `@MainActor @Observable` exactly like `ImportService`
/// (MusicKit request/response types are main-actor-friendly; volumes are
/// modest). It `await`s the `Sendable`, off-main `LibraryStore`; only
/// `Sendable` value types (the `[String: [String]]` map, ids) cross that
/// boundary. The `nonisolated static` fetch helpers run the CPU-heavy
/// MusicKit paging off the `@MainActor` and capture nothing isolated.
///
/// **Performance.** Strictly serial, like `ImportService`'s proven loop and
/// for the same measured reason — app-side parallelism over per-collection
/// MusicKit fetches does not help on macOS (it contends on MusicKit's
/// internal machinery rather than overlapping; the `TaskGroup` attempt was
/// measured ineffective and reverted). Albums with no genre are skipped
/// **before** their `.tracks` fetch — roughly half the sampled albums carry
/// no tag, so this halves the per-album track fetches. The per-album
/// `album.with([.tracks])` is the accepted cost (same class as
/// `ImportService`'s per-playlist fetch); this runs only on a full /
/// first import, never on the fast incremental Refresh (see
/// `MusicController`).
@MainActor
@Observable
final class GenreImportService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  private(set) var isImporting = false
  private(set) var lastError: String?
  /// Coarse progress for a future affordance: albums processed / total
  /// discovered. Surfaced the same way `ImportService` surfaces its
  /// playlist counts (no new UI is wired in this change; the property
  /// exists so the trigger sites mirror `ImportService` and a later
  /// "Refreshing genres…" affordance is a one-liner).
  private(set) var importedAlbumCount = 0
  private(set) var totalAlbumCount = 0
  /// How many rows the last completed pass actually updated (the
  /// accumulated `db.changes` from `applyAlbumGenres`). For verification /
  /// a future "N tracks tagged" affordance.
  private(set) var taggedSongCount = 0

  /// Read every library album that carries a genre, attribute it to its
  /// tracks, and write the genres onto the matching `song` rows one-way.
  /// Per-album failures are tolerated (logged into `lastError`) so one bad
  /// album never aborts the whole pass — exactly `ImportService`'s posture.
  ///
  /// **Strictly serial** per the same honest performance finding as
  /// `ImportService`: app-side parallelism doesn't help here (the
  /// bottleneck is MusicKit's own per-collection track resolution on
  /// macOS). Albums with an empty `genreNames` are skipped before the
  /// expensive `.tracks` fetch. Accumulates one `[musicItemID: genreNames]`
  /// map and applies it in a single store transaction (the simplest shape
  /// and exactly the "one write transaction" the store method documents).
  func importAlbumGenres() async {
    guard !isImporting else { return }
    isImporting = true
    lastError = nil
    importedAlbumCount = 0
    totalAlbumCount = 0
    taggedSongCount = 0
    defer { isImporting = false }

    do {
      let albums = try await fetchAllLibraryAlbums()
      totalAlbumCount = albums.count

      var genreByMusicItemID = [String: [String]]()
      var failures = [String]()

      // Serial, one album in flight at a time (the proven loop). Skip
      // genre-less albums BEFORE their track fetch — that's the win.
      for album in albums {
        defer { importedAlbumCount += 1 }
        let genreNames = album.genreNames
        guard !genreNames.isEmpty else { continue }
        do {
          let tracks = try await Self.fetchTracks(
            of: album,
            maxTrackBatches: maxTrackBatches,
          )
          for track in tracks {
            // Last album wins for a track on multiple albums — fine,
            // attribution is album-granular by design.
            genreByMusicItemID[ImportService.underlyingItemID(of: track)] = genreNames
          }
        } catch {
          failures.append("\(album.title): \(error.localizedDescription)")
        }
      }

      // One transaction (the store method's documented shape). Empty map
      // (no album carried a genre) → store early-returns 0, harmless.
      taggedSongCount = try await store.applyAlbumGenres(genreByMusicItemID)

      if !failures.isEmpty {
        lastError = "Some album genres could not be imported:\n"
          + failures.prefix(5).joined(separator: "\n")
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore

  /// Hard caps on pagination loops to avoid pathological infinite paging
  /// (mirrors `ImportService`'s `maxPlaylistBatches` / `maxTrackBatches`).
  private let maxAlbumBatches = 1000
  private let maxTrackBatches = 5000

  /// Page a single album's tracks. `nonisolated static` so the MusicKit
  /// paging (CPU-heavy + internally serialized on macOS) runs off the
  /// `@MainActor`; it captures nothing isolated and only returns `Sendable`
  /// `Track`s. The proven `ImportService.fetchTracks` paging loop + cap,
  /// applied to an `Album` instead of a `Playlist` (the relationship and
  /// the batch type are identical).
  private nonisolated static func fetchTracks(
    of album: Album,
    maxTrackBatches: Int,
  ) async throws -> [Track] {
    let detailed = try await album.with([.tracks])

    var allTracks = [Track]()
    var batch: MusicItemCollection<Track>? = detailed.tracks
    var batchCount = 0
    while let current = batch {
      allTracks.append(contentsOf: current)
      batchCount += 1
      if current.hasNextBatch, batchCount < maxTrackBatches {
        batch = try await current.nextBatch()
      } else {
        batch = nil
      }
    }
    return allTracks
  }

  private func fetchAllLibraryAlbums() async throws -> [Album] {
    var request = MusicLibraryRequest<Album>()
    request.limit = 100
    let response = try await request.response()

    var collected = [Album]()
    var batch: MusicItemCollection<Album>? = response.items
    var batchCount = 0
    while let current = batch {
      collected.append(contentsOf: current)
      batchCount += 1
      if current.hasNextBatch, batchCount < maxAlbumBatches {
        batch = try await current.nextBatch()
      } else {
        batch = nil
      }
    }
    return collected
  }

}
