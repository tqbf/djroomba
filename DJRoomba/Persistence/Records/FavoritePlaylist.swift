import GRDB

// MARK: - FavoritePlaylist

/// A favorited playlist. Replaces the UserDefaults `FavoritesStore`
/// (migrated one-shot in Phase 3). `playlistID` is whatever id the `source`
/// table uses (Apple library `MusicItemID` or app UUID); it is the primary
/// key, so favoriting is idempotent.
///
/// No DB-level foreign key: the referent lives in one of two tables chosen
/// by `source`. Integrity is enforced in app code (only favorite a playlist
/// that exists) and stale rows are harmless (filtered at read/merge time).
struct FavoritePlaylist: Codable, Identifiable, Hashable, Sendable {
  enum CodingKeys: String, CodingKey {
    case playlistID = "playlist_id"
    case source
  }

  /// Apple library `MusicItemID.rawValue` or app playlist UUID. Primary key.
  var playlistID: String
  var source: PlaylistSourceKind

  var id: String {
    playlistID
  }

}

// MARK: FetchableRecord, MutablePersistableRecord

extension FavoritePlaylist: FetchableRecord, MutablePersistableRecord {
  enum Columns {
    static let playlistID = Column(CodingKeys.playlistID)
    static let source = Column(CodingKeys.source)
  }

  static let databaseTableName = "favorite_playlist"

}
