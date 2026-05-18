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
/// **Genre is resolved via an explicit per-album fetch — the bulk request's
/// implicit projection is NOT trusted.** A bulk `MusicLibraryRequest<Album>`
/// returns a *partial* projection whose contents vary by OS: on newer macOS
/// `album.genreNames` happens to be populated for the genre-bearing subset,
/// but on **macOS 14.4** the in-app diagnostic proved `album.genreNames` is
/// empty for **all** albums (the bulk projection there omits genre entirely,
/// the same way `album.title`/`artistName` came back empty in the same
/// request — see `plans/data-and-import.md`). Trusting the bulk value made
/// every album fail the genre `guard` on 14.4, so nothing was ever tagged.
/// Each album's genre is therefore resolved by a *fast path then fallback*:
/// use `album.genreNames` if the bulk projection already filled it (newer
/// OS — preserves the "skip genre-less albums before the track fetch"
/// optimization), otherwise explicitly `album.with([.genres])` and read the
/// genre off the *detailed* object (the documented "request more Album
/// properties" path — the same mechanism by which `playlist.with([.tracks])`
/// returns full song metadata the list request lacks).
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
  /// How many scanned albums actually carried a non-empty `genreNames`. The
  /// (b)-vs-(c) discriminator for the diagnostic readout: with 0 tagged songs,
  /// `== 0` means the library's albums have no genre (b) while `> 0` means
  /// albums had genres but the album→song id join produced nothing (c).
  private(set) var albumsWithGenreCount = 0
  /// How many rows the last completed pass actually updated (the
  /// accumulated `db.changes` from `applyAlbumGenres`). For verification /
  /// a future "N tracks tagged" affordance.
  private(set) var taggedSongCount = 0

  /// Pure genre-resolution precedence, dependency-free so it is unit-tested
  /// with no MusicKit (`GenreResolutionTests`). The bug this fixes is
  /// trusting the bulk request's implicit projection: on macOS 14.4 it omits
  /// genre for every album. Precedence, first non-empty wins:
  /// 1. `bulk` — the bulk `MusicLibraryRequest<Album>` projection
  ///    (`album.genreNames`); present on newer macOS, the fast path.
  /// 2. `detailedRelationship` — names off the explicitly-fetched
  ///    `album.with([.genres])` `Album.genres` relationship.
  /// 3. `detailedGenreNames` — the detailed album's own `genreNames`, which
  ///    a full per-item fetch often populates when the bulk projection did
  ///    not.
  /// All inputs empty → `[]` (a genuinely genre-less album, skipped). Names
  /// are whitespace-trimmed and de-duplicated (order-preserving) so the
  /// `song.genre_names` value is clean regardless of source.
  nonisolated static func resolvedGenres(
    bulk: [String],
    detailedRelationship: [String],
    detailedGenreNames: [String],
  ) -> [String] {
    for candidate in [bulk, detailedRelationship, detailedGenreNames] {
      let cleaned = dedupedTrimmed(candidate)
      if !cleaned.isEmpty { return cleaned }
    }
    return []
  }

  /// Read every library album that carries a genre, attribute it to its
  /// tracks, and write the genres onto the matching `song` rows one-way.
  /// Per-album failures are tolerated (logged into `lastError`) so one bad
  /// album never aborts the whole pass — exactly `ImportService`'s posture.
  ///
  /// **Strictly serial** per the same honest performance finding as
  /// `ImportService`: app-side parallelism doesn't help here (the
  /// bottleneck is MusicKit's own per-collection track resolution on
  /// macOS). Each album's genre is resolved by `Self.resolvedGenres` (bulk
  /// projection fast path → explicit `album.with([.genres])` fallback for
  /// the macOS-14.4 case where the bulk projection omits genre); albums that
  /// genuinely carry no genre are still skipped before the expensive
  /// `.tracks` fetch. On macOS 14.4 the cheap `.with([.genres])` runs for
  /// (potentially) every album while `.with([.tracks])` runs only for
  /// genre-bearing ones — the accepted correctness cost (this pass only runs
  /// on a full / first import, and the "Refreshing genres…" status makes it
  /// visible). Accumulates one `[musicItemID: genreNames]` map and applies
  /// it in a single store transaction (the simplest shape and exactly the
  /// "one write transaction" the store method documents).
  func importAlbumGenres() async {
    guard !isImporting else { return }
    isImporting = true
    lastError = nil
    importedAlbumCount = 0
    totalAlbumCount = 0
    albumsWithGenreCount = 0
    taggedSongCount = 0
    defer { isImporting = false }

    do {
      let albums = try await fetchAllLibraryAlbums()
      totalAlbumCount = albums.count

      var genreByMusicItemID = [String: [String]]()
      var failures = [String]()

      // Serial, one album in flight at a time (the proven loop). Resolve
      // genre per album WITHOUT trusting the bulk projection, then skip
      // genuinely genre-less albums BEFORE their track fetch — that's the
      // win that survives on macOS 14.4 (where the bulk projection is empty
      // for every album).
      for album in albums {
        defer { importedAlbumCount += 1 }

        // Fast path: the bulk projection already filled genre (newer OS).
        let bulkGenres = album.genreNames

        // Robust fallback (the macOS-14.4 path): only when the bulk
        // projection is empty, explicitly load the album's genre. Tolerant
        // — a "relationship absent" is NOT a failure, it just means this
        // album has no genre (exactly the rest of the pass's posture); a
        // genuine fetch error is collected but never aborts the pass.
        var detailedRelationship = [String]()
        var detailedGenreNames = [String]()
        if bulkGenres.isEmpty {
          do {
            let detailed = try await album.with([.genres])
            detailedRelationship = detailed.genres?.map(\.name) ?? []
            // A full per-item fetch often populates `genreNames` the bulk
            // projection omitted (same as `playlist.with([.tracks])`
            // returning full song metadata the list request lacked).
            detailedGenreNames = detailed.genreNames
          } catch {
            failures.append("\(album.title): \(error.localizedDescription)")
          }
        }

        let genres = Self.resolvedGenres(
          bulk: bulkGenres,
          detailedRelationship: detailedRelationship,
          detailedGenreNames: detailedGenreNames,
        )
        guard !genres.isEmpty else { continue }
        // Increment only once genre is CONFIRMED non-empty (after the
        // fallback) so the diagnostic triad reports the real number of
        // genre-bearing albums on macOS 14.4, not 0.
        albumsWithGenreCount += 1
        do {
          let tracks = try await Self.fetchTracks(
            of: album,
            maxTrackBatches: maxTrackBatches,
          )
          for track in tracks {
            // Last album wins for a track on multiple albums — fine,
            // attribution is album-granular by design.
            genreByMusicItemID[ImportService.underlyingItemID(of: track)] = genres
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

  /// Trim each name and drop empties, preserving first-seen order with no
  /// duplicates. Shared by `resolvedGenres` so every source is normalized
  /// identically.
  private nonisolated static func dedupedTrimmed(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var result = [String]()
    for name in names {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      result.append(trimmed)
    }
    return result
  }

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
