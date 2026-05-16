import Foundation
import GRDB

// MARK: - PlayHistoryEntry

/// One row per recorded play in the bounded, newest-first play history
/// (`v3`). The user's "vector of numeric identifiers": a compact append of
/// the canonical `song.local_id`, the same song allowed to appear many
/// times. `LibraryStore.recordPlay` appends one of these and prunes the
/// oldest beyond `LibraryStore.playHistoryCap` in the same transaction.
///
/// `seq` is an AUTOINCREMENT rowid: strictly monotonic and never reused, so
/// "newest first" is `ORDER BY seq DESC` and the cap-prune is a cheap
/// keyset (`DELETE WHERE seq <= MAX(seq) - cap`). It carries no app-stable
/// identity — a history entry is never referenced by anything else.
/// `song_local_id` FK-references `song(local_id)` `ON DELETE RESTRICT`, so
/// listening history is never silently destroyed by deleting a song
/// (documented in LibraryMigrator). This is the only history of record
/// since `play_event` was dropped in `v3`.
struct PlayHistoryEntry: Codable, Identifiable, Hashable, Sendable {
  enum CodingKeys: String, CodingKey {
    case seq
    case songLocalID = "song_local_id"
  }

  /// SQLite rowid; nil before insert, filled by `didInsert`.
  var seq: Int64?
  /// The played song's canonical numeric id (`song.local_id`).
  var songLocalID: Int

  var id: Int64? {
    seq
  }

}

// MARK: FetchableRecord, MutablePersistableRecord

extension PlayHistoryEntry: FetchableRecord, MutablePersistableRecord {
  enum Columns {
    static let seq = Column(CodingKeys.seq)
    static let songLocalID = Column(CodingKeys.songLocalID)
  }

  static let databaseTableName = "play_history"

  mutating func didInsert(_ inserted: InsertionSuccess) {
    seq = inserted.rowID
  }
}
