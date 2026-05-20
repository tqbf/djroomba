import Foundation
import MusicKit

/// One-way ingest: MusicKit **catalog** `Song`s → SQLite. The catalog mirror
/// of `ImportService`. Lands catalog tracks into the `song` table so the
/// existing app-playlist / "Add to Playlist ▸" / genre affordances — already
/// namespace-agnostic by construction (they FK our stable `song.id`, not the
/// MusicKit id) — can include catalog tracks without any further plumbing.
///
/// Provenance-fixed: every record minted here uses
/// `idNamespace: .catalog`. This is the exact mirror of
/// `ImportService.song(from:)`'s `.library` rule (the D1 corrective —
/// namespace is by *provenance*, never inferred from the id string). The
/// import dedupe key `(music_item_id, id_namespace)` keeps catalog rows
/// strictly disjoint from library rows even on a colliding raw id, so this
/// service can never clobber a library row and vice versa — covered by
/// `CatalogIsolationTests`.
///
/// Scope (Phase 1 of `plans/catalog-playlists.md`):
///
/// - **Ingest only.** Lands catalog `Song`s as rows in `song`. Never
///   constructs a playlist, never writes `apple_playlist*`, never flips the
///   dormant `PlaybackResolver` catalog branch (Phase 3). The plan's
///   simplification: app-playlist membership FKs our `song.id`, so the
///   instant a catalog song row exists it's eligible for any app playlist
///   the user adds it to — no Phase-4 changes needed.
/// - **Artwork stays nil here.** Catalog artwork URLs are public (unlike
///   library), but Phase 4 is the single place artwork lives (re-resolve
///   on demand through `ArtworkProvider`). Storing a URL at ingest would
///   spread that responsibility.
/// - **Schema unchanged.** The composite unique key was designed for this;
///   no migration is needed.
///
/// Concurrency: `@MainActor` like the sibling MusicKit services. The store
/// is the `Sendable`, off-main `LibraryStore`; only `Sendable` values cross
/// the boundary. Not `@Observable` — there is no streamed mutable state to
/// drive UI (Phase 2 may add a separate search service that *does* surface
/// progress; ingest itself is a single batched UPSERT).
///
/// Batch idiom: one `upsertSongs` (chunked multi-row UPSERT, the same
/// batched write path the library import uses) plus one `songIDsByKey`
/// read, mirroring `ImportService.writePlaylist`. Never a per-song
/// `SELECT`+UPSERT loop.
@MainActor
final class CatalogIngestService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  /// Land a batch of catalog `Song`s into SQLite and return their stable
  /// `song.id`s in input order so the caller can immediately reference
  /// them (e.g. add to an app playlist on the same turn).
  ///
  /// Idempotent: re-ingesting the same `MusicKit.Song` (same catalog id) is
  /// a non-destructive UPSERT — the existing row keeps its stable `song.id`
  /// while mutable metadata is refreshed. The composite unique key
  /// `(music_item_id, id_namespace)` is what makes this safe.
  ///
  /// Tolerates an empty input (no-op, returns `[]`).
  func ingest(_ songs: [MusicKit.Song]) async throws -> [String] {
    guard !songs.isEmpty else { return [] }

    let importedAt = Date.now

    // Map MusicKit.Song → our Song record. Some catalog songs in one
    // request may collide on `music_item_id` (catalog ids are globally
    // stable — collisions would mean the caller passed the same song
    // twice). De-dupe to one record per import key (first occurrence
    // wins; they describe the same song) and preserve the caller's
    // order separately so the returned id list matches `songs` 1:1.
    // This mirrors `ImportService.writePlaylist`'s two-structure pattern.
    var songsByKey = [LibraryStore.SongKey: Song]()
    var orderedKeys = [LibraryStore.SongKey]()
    orderedKeys.reserveCapacity(songs.count)
    for catalogSong in songs {
      let record = Self.song(fromCatalog: catalogSong, importedAt: importedAt)
      let key = LibraryStore.SongKey(
        musicItemID: record.musicItemID,
        namespace: record.idNamespace,
      )
      if songsByKey[key] == nil {
        songsByKey[key] = record
      }
      orderedKeys.append(key)
    }

    // 1. Batch UPSERT the unique catalog records (one chunked multi-row
    //    statement in one transaction; dedupe on
    //    `(music_item_id, id_namespace)`, preserving any existing stable
    //    `song.id` — non-destructive re-ingest, the same guarantee
    //    library import relies on).
    try await store.upsertSongs(Array(songsByKey.values))

    // 2. One batched lookup of every unique key → stored stable `song.id`
    //    (mirrors `ImportService.writePlaylist`'s single batched read —
    //    never a per-song N-await re-read).
    let idByKey = try await store.songIDsByKey(
      songsByKey.keys.map { ($0.musicItemID, $0.namespace) }
    )

    // Expand back to caller order. `compactMap` is defensive — every key
    // present in `songsByKey` was just upserted, so the lookup is
    // total in practice; a missing entry would mean a store-level
    // anomaly worth dropping rather than crashing.
    return orderedKeys.compactMap { idByKey[$0] }
  }

  /// Map a MusicKit catalog `Song` to our `Song` record. Provenance fixes
  /// `idNamespace: .catalog` — period — the exact mirror of
  /// `ImportService.song(from:)`'s `.library` rule.
  ///
  /// `nonisolated static` so it crosses the `@MainActor` boundary freely
  /// and stays trivially testable. The unit-tested entry point is
  /// `song(fromCatalogFields:…)` (this method just extracts those fields
  /// from a live `MusicKit.Song` and forwards) — `MusicKit.Song` can't be
  /// constructed in tests, so the field-taking version is what we cover.
  /// The same factor-for-testability idiom `ImportService.underlyingItemID`
  /// uses.
  nonisolated static func song(fromCatalog catalogSong: MusicKit.Song, importedAt: Date) -> Song {
    song(
      fromCatalogFields: catalogSong.id.rawValue,
      title: catalogSong.title,
      artistName: catalogSong.artistName,
      albumTitle: catalogSong.albumTitle,
      duration: catalogSong.duration,
      isExplicit: catalogSong.contentRating == .explicit,
      importedAt: importedAt,
      trackNumber: catalogSong.trackNumber,
      discNumber: catalogSong.discNumber,
      genreNames: catalogSong.genreNames,
      releaseDate: catalogSong.releaseDate,
      composerName: catalogSong.composerName,
      isrc: catalogSong.isrc,
      hasLyrics: catalogSong.hasLyrics,
      workName: catalogSong.workName,
      movementName: catalogSong.movementName,
    )
  }

  /// The pure field-by-field mapping behind `song(fromCatalog:)`. Takes
  /// only `Sendable` values so it's unit-testable without a live
  /// `MusicKit.Song` (the live type can't be constructed in tests). Every
  /// catalog `Song` field DJ Roomba currently stores flows through here
  /// once; if a new column is added later, it gets a new parameter here
  /// and a new bind in the caller — no second mapping path drifts.
  ///
  /// Provenance is hard-coded `.catalog` — *the* invariant of this
  /// service. A fresh UUID is minted as the app-stable `song.id`; the
  /// store's UPSERT on the composite unique key preserves it on conflict,
  /// the SAME guarantee the library path relies on. Catalog artwork is
  /// re-resolved live by id (Phase 4) — kept `nil` here deliberately.
  nonisolated static func song(
    fromCatalogFields catalogID: String,
    title: String,
    artistName: String,
    albumTitle: String?,
    duration: Double?,
    isExplicit: Bool,
    importedAt: Date,
    trackNumber: Int?,
    discNumber: Int?,
    genreNames: [String],
    releaseDate: Date?,
    composerName: String?,
    isrc: String?,
    hasLyrics: Bool?,
    workName: String?,
    movementName: String?,
  ) -> Song {
    Song(
      id: UUID().uuidString,
      musicItemID: catalogID,
      // Provenance: catalog ingest → catalog namespace. Period.
      idNamespace: .catalog,
      title: title,
      artistName: artistName,
      albumTitle: albumTitle,
      duration: duration,
      isExplicit: isExplicit,
      // Catalog artwork URL is public (unlike library), but Phase 4 is
      // the single place artwork lives — re-resolved live by id through
      // `ArtworkProvider`. Kept nil here deliberately.
      artworkURL: nil,
      importedAt: importedAt,
      trackNumber: trackNumber,
      discNumber: discNumber,
      genreNames: genreNames,
      releaseDate: releaseDate,
      composerName: composerName,
      isrc: isrc,
      hasLyrics: hasLyrics,
      workName: workName,
      movementName: movementName,
    )
  }

  // MARK: Private

  private let store: LibraryStore

}
