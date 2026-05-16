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
  /// The MusicKit id space an id belongs to. Library and catalog ids are
  /// not interchangeable; `PlaybackResolver` keys re-fetch on this.
  enum IDNamespace: String, Codable, Sendable, CaseIterable {
    case library
    case catalog
  }

  /// Swift camelCase ⇄ SQLite snake_case. Explicit so the migrated schema
  /// stays readable SQL and renaming a Swift property never silently
  /// renames a shipped column.
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
  }

  static let databaseTableName = "song"

}
