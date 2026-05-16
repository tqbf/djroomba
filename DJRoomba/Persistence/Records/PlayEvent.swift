import Foundation
import GRDB

// MARK: - PlayEvent

/// One row per time playback actually started for a song (Phase 4 records
/// these). This is the durable, append-only play history; `song_stat` is a
/// denormalized rollup of it for cheap sorting/UI.
///
/// `id` is an autoincrement rowid (no app-stable identity needed — events
/// are never referenced by anything else). Deleting a song is RESTRICTed
/// while play history exists, so listening history is never silently
/// destroyed by an import edge case (documented in LibraryMigrator).
struct PlayEvent: Codable, Identifiable, Hashable, Sendable {
  enum CodingKeys: String, CodingKey {
    case id
    case songID = "song_id"
    case playedAt = "played_at"
  }

  /// SQLite rowid; nil before insert, filled by `didInsert`.
  var id: Int64?
  var songID: String
  var playedAt: Date

}

// MARK: FetchableRecord, MutablePersistableRecord

extension PlayEvent: FetchableRecord, MutablePersistableRecord {
  enum Columns {
    static let id = Column(CodingKeys.id)
    static let songID = Column(CodingKeys.songID)
    static let playedAt = Column(CodingKeys.playedAt)
  }

  static let databaseTableName = "play_event"

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
