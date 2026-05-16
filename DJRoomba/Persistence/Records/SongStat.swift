import Foundation
import GRDB

// MARK: - SongStat

/// Denormalized per-song play rollup: `play_count` and `last_played_at`,
/// maintained from `play_event` in the same write that records a play
/// (kept in app code rather than a SQL trigger so the logic is testable
/// and visible — see `LibraryStore.recordPlay`).
///
/// One row per song (`song_id` is both PK and FK). It exists so the track
/// table can sort by play count / recency without scanning the full
/// `play_event` history. Cascade-deleted with its `song`.
struct SongStat: Codable, Identifiable, Hashable, Sendable {
  enum CodingKeys: String, CodingKey {
    case songID = "song_id"
    case playCount = "play_count"
    case lastPlayedAt = "last_played_at"
  }

  /// `song(id)`. Primary key and foreign key.
  var songID: String
  var playCount: Int
  var lastPlayedAt: Date?

  var id: String {
    songID
  }

}

// MARK: FetchableRecord, MutablePersistableRecord

extension SongStat: FetchableRecord, MutablePersistableRecord {
  enum Columns {
    static let songID = Column(CodingKeys.songID)
    static let playCount = Column(CodingKeys.playCount)
    static let lastPlayedAt = Column(CodingKeys.lastPlayedAt)
  }

  static let databaseTableName = "song_stat"

}
