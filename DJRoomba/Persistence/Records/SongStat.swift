import Foundation
import GRDB

// MARK: - SongStat

/// Denormalized per-song play rollup: `play_count`, `last_played_at`, and
/// (since `v3`) `skip_count` / `replay_count`. All four are maintained
/// directly in app code in the same write that records the event
/// (`LibraryStore.recordPlay` / `recordSkip` / `recordReplay`) — kept here
/// rather than in a SQL trigger or derived from an event log so the logic
/// is testable and visible, and so it stays correct independently of the
/// bounded (capped) `play_history`.
///
/// One row per song (`song_id` is both PK and FK). It exists so the track
/// table can sort by play count / recency (and, later, skip/replay)
/// without scanning history. Cascade-deleted with its `song`.
struct SongStat: Codable, Identifiable, Hashable, Sendable {
  enum CodingKeys: String, CodingKey {
    case songID = "song_id"
    case playCount = "play_count"
    case lastPlayedAt = "last_played_at"
    case skipCount = "skip_count"
    case replayCount = "replay_count"
  }

  /// `song(id)`. Primary key and foreign key.
  var songID: String
  var playCount: Int
  var lastPlayedAt: Date?
  /// "Next" pressed before halfway through the track. App-maintained,
  /// independent of `play_history`.
  var skipCount = 0
  /// "Back" pressed after halfway through the track. App-maintained,
  /// independent of `play_history`.
  var replayCount = 0

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
    static let skipCount = Column(CodingKeys.skipCount)
    static let replayCount = Column(CodingKeys.replayCount)
  }

  static let databaseTableName = "song_stat"

}
