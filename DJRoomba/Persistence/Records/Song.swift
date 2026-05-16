import Foundation
import GRDB

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
    /// App-stable identity (UUID string). Primary key.
    var id: String
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
}

extension Song: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "song"

    enum Columns {
        static let id = Column(CodingKeys.id)
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
}
