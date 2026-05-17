import Foundation
import GRDB

// MARK: - Song

/// A track imported from Apple Music into the local store.
///
/// The app's stable identity is `id` (a UUID string we mint), *not* the
/// MusicKit id — so a song row survives even if Apple re-issues ids, and
/// foreign keys from playlists / play history stay stable. The MusicKit
/// `MusicItemID` raw value plus its namespace (`library` vs `catalog`) are
/// stored so `PlaybackResolver` (Phase 3) can re-fetch a playable item:
/// the two id spaces are NOT interchangeable, so the namespace must travel
/// with the id. `UNIQUE(music_item_id, id_namespace)` is what import dedupes
/// against.
///
/// Extensibility: new optional columns (rating, tags via a join table,
/// artwork variants, soft-delete flag, artist/album FK, …) are added in
/// *future* migrations; this struct then gains the matching properties.
/// Because persistence is Codable-driven, adding a nullable column is a
/// localized change here — no store-API refactor.
struct Song: Codable, Identifiable, Hashable, Sendable {

  // MARK: Lifecycle

  /// Explicit memberwise init. Needed (unlike the other records, which keep
  /// the synthesized one) because `genreNames` is a computed accessor over
  /// the private `genreNamesJSON` storage — the synthesized init would
  /// surface `genreNamesJSON` instead of `genreNames` and wouldn't be
  /// visible across files. Every `v4` parameter is defaulted so existing
  /// `Song(...)` constructions and `TestSupport.sampleSong` keep compiling
  /// (same shape as `localID = 0`). `genreNames` is taken as `[String]`
  /// here and JSON-encoded into the backing column via the computed setter.
  init(
    id: String,
    localID: Int = 0,
    musicItemID: String,
    idNamespace: IDNamespace,
    title: String,
    artistName: String,
    albumTitle: String? = nil,
    duration: Double? = nil,
    isExplicit: Bool,
    artworkURL: String? = nil,
    importedAt: Date,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    genreNames: [String] = [],
    releaseDate: Date? = nil,
    composerName: String? = nil,
    isrc: String? = nil,
    hasLyrics: Bool? = nil,
    workName: String? = nil,
    movementName: String? = nil,
  ) {
    self.id = id
    self.localID = localID
    self.musicItemID = musicItemID
    self.idNamespace = idNamespace
    self.title = title
    self.artistName = artistName
    self.albumTitle = albumTitle
    self.duration = duration
    self.isExplicit = isExplicit
    self.artworkURL = artworkURL
    self.importedAt = importedAt
    self.trackNumber = trackNumber
    self.discNumber = discNumber
    self.releaseDate = releaseDate
    self.composerName = composerName
    self.isrc = isrc
    self.hasLyrics = hasLyrics
    self.workName = workName
    self.movementName = movementName
    genreNamesJSON = Self.encodeGenreNames(genreNames)
  }

  // MARK: Internal

  /// The MusicKit id space an id belongs to. Library and catalog ids are
  /// not interchangeable; `PlaybackResolver` keys re-fetch on this.
  enum IDNamespace: String, Codable, Sendable, CaseIterable {
    case library
    case catalog
  }

  /// Swift camelCase ⇄ SQLite snake_case. Explicit so the migrated schema
  /// stays readable SQL and renaming a Swift property never silently
  /// renames a shipped column.
  ///
  /// `genreNamesJSON` (the `genre_names` column) is the **only** coded key
  /// for genres — see the `genreNames` computed accessor below; there is no
  /// `genreNames` key because the array never has its own column.
  enum CodingKeys: String, CodingKey {
    case id
    case localID = "local_id"
    case musicItemID = "music_item_id"
    case idNamespace = "id_namespace"
    case title
    case artistName = "artist_name"
    case albumTitle = "album_title"
    case duration
    case isExplicit = "is_explicit"
    case artworkURL = "artwork_url"
    case importedAt = "imported_at"
    case trackNumber = "track_number"
    case discNumber = "disc_number"
    case genreNamesJSON = "genre_names"
    case releaseDate = "release_date"
    case composerName = "composer_name"
    case isrc
    case hasLyrics = "has_lyrics"
    case workName = "work_name"
    case movementName = "movement_name"
  }

  /// App-stable identity (UUID string). Primary key.
  var id: String
  /// The durable canonical numeric song id (`v3`; see
  /// plans/play-statistics.md "Two identities"). `id` stays the relational
  /// key; `localID` is the compact stable handle alongside it.
  ///
  /// **Read-authoritative, never written from this struct:** the contract
  /// is comment-enforced, not type-enforced. `LibraryStore.upsertSongs`
  /// assigns it inside the upsert transaction; the upsert SQL omits
  /// `local_id` so a re-import keeps each existing row's value, and no
  /// other persist path writes it. The `= 0` default is an
  /// always-overwritten sentinel (decoding always reads a real value — the
  /// column is populated post-migration / post-upsert); a future
  /// `try song.save(db)` through GRDB's record API would wrongly persist
  /// it and is the thing to watch.
  ///
  /// Contract: assigned at import, monotonic, stable across re-import,
  /// never the rowid, never an Apple id. The allocator is `MAX(local_id)+1`
  /// over live rows, so a value is never recycled while its song exists —
  /// and any song ever played or placed in a playlist is FK-RESTRICTed
  /// against deletion (`play_history` / `*_playlist_track`), so a
  /// `local_id` that could ever have been observed/stored can't recur.
  var localID = 0
  /// `MusicItemID.rawValue` as imported from MusicKit.
  var musicItemID: String
  /// Which MusicKit id space `musicItemID` belongs to.
  var idNamespace: IDNamespace
  var title: String
  var artistName: String
  var albumTitle: String?
  /// Duration in seconds. Nullable — MusicKit often omits it on macOS.
  var duration: Double?
  var isExplicit: Bool
  /// A resolved/cached artwork URL string. Nullable.
  var artworkURL: String?
  /// When this row was first written / last refreshed by import.
  var importedAt: Date

  /// Direct properties already present on the library `Song`/`Track`
  /// objects import ALREADY fetches (`playlist.with([.tracks])`) — zero
  /// extra API calls, zero per-item/catalog fan-out. **Nullable/sparse by
  /// nature:** a library `Song` on macOS may not populate every field;
  /// that's expected and harmless — NULL just means we didn't get it. All
  /// mutable: a re-import refreshes them (the UPSERT `DO UPDATE`s them, like
  /// `title`). Read-through like the rest (decoded via GRDB Codable AND
  /// `try Song(row:)`).
  var trackNumber: Int?
  var discNumber: Int?
  var releaseDate: Date?
  var composerName: String?
  var isrc: String?
  /// `true`/`false` for a song, `nil` when the item isn't a song (a music
  /// video has no lyrics in our model). Stored as the `has_lyrics` 0/1/NULL
  /// BOOLEAN column.
  var hasLyrics: Bool?
  /// Classical-work title (`MusicKit.Song.workName`), usually `nil`.
  var workName: String?
  /// Classical-movement title (`MusicKit.Song.movementName`), usually `nil`.
  var movementName: String?

  /// The full ordered genre list (`MusicKit.Song.genreNames`). Persisted as
  /// the single `genre_names` TEXT column, JSON-encoded — deliberately NOT a
  /// normalized `song_genre` table (out of scope); the JSON array preserves
  /// the entire list, which is the ask. Empty ⇒ stored NULL.
  ///
  /// Backed by an explicit private JSON `String?` coded property rather
  /// than GRDB's default Codable handling for `[String]`: `Song` is decoded
  /// on two paths — GRDB `Song.fetchAll`/`fetchOne` (Codable) **and**
  /// `try Song(row:)` in `songsWithStats`/`recentlyPlayedPage` — and the
  /// hand-rolled raw multi-row `INSERT` in `LibraryStore.upsertSongs` binds
  /// one scalar per column. A single explicit JSON string round-trips
  /// cleanly and identically on every one of those paths (verified by
  /// `SongMetadataTests`); letting Codable synthesize array handling would
  /// not match that single-scalar column.
  var genreNames: [String] {
    get {
      guard
        let genreNamesJSON,
        let data = genreNamesJSON.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String].self, from: data)
      else {
        return []
      }
      return decoded
    }
    set {
      genreNamesJSON = Self.encodeGenreNames(newValue)
    }
  }

  /// JSON-array form of `genreNames` (the `genre_names` column), or `nil`
  /// for an empty list. The codable/persisted representation; app code uses
  /// the `genreNames` computed accessor instead.
  static func encodeGenreNames(_ names: [String]) -> String? {
    guard !names.isEmpty else { return nil }
    guard
      let data = try? JSONEncoder().encode(names),
      let json = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return json
  }

  // MARK: Private

  /// JSON-encoded `genreNames` ⇄ the `genre_names` TEXT column. `nil`/absent
  /// ⇒ an empty list. See the `genreNames` accessor for why this is
  /// explicit rather than synthesized.
  private var genreNamesJSON: String?

}

// MARK: FetchableRecord, MutablePersistableRecord

extension Song: FetchableRecord, MutablePersistableRecord {
  enum Columns {
    static let id = Column(CodingKeys.id)
    static let localID = Column(CodingKeys.localID)
    static let musicItemID = Column(CodingKeys.musicItemID)
    static let idNamespace = Column(CodingKeys.idNamespace)
    static let title = Column(CodingKeys.title)
    static let artistName = Column(CodingKeys.artistName)
    static let albumTitle = Column(CodingKeys.albumTitle)
    static let duration = Column(CodingKeys.duration)
    static let isExplicit = Column(CodingKeys.isExplicit)
    static let artworkURL = Column(CodingKeys.artworkURL)
    static let importedAt = Column(CodingKeys.importedAt)
    // "Free" Apple-library metadata (v4). `genreNamesJSON` is the
    // `genre_names` TEXT column (the `genreNames` accessor is computed).
    static let trackNumber = Column(CodingKeys.trackNumber)
    static let discNumber = Column(CodingKeys.discNumber)
    static let genreNamesJSON = Column(CodingKeys.genreNamesJSON)
    static let releaseDate = Column(CodingKeys.releaseDate)
    static let composerName = Column(CodingKeys.composerName)
    static let isrc = Column(CodingKeys.isrc)
    static let hasLyrics = Column(CodingKeys.hasLyrics)
    static let workName = Column(CodingKeys.workName)
    static let movementName = Column(CodingKeys.movementName)
  }

  static let databaseTableName = "song"

}
