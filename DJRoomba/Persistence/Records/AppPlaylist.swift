import Foundation
import GRDB

// MARK: - AppPlaylist

/// A user-created playlist that lives ONLY in SQLite — never written back to
/// Apple Music (core product decision: the app owns this data). Created /
/// renamed / reordered in Phase 4.
///
/// `id` is an app-minted UUID string. `sortIndex` is the explicit sidebar
/// order (gaps allowed so reordering is a localized update, not a full
/// renumber). Import never deletes or mutates these rows.
struct AppPlaylist: Codable, Identifiable, Hashable, Sendable {
  enum CodingKeys: String, CodingKey {
    case id
    case name
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case sortIndex = "sort_index"
  }

  /// App-minted UUID string. Primary key.
  var id: String
  var name: String
  var createdAt: Date
  var updatedAt: Date
  /// Explicit sidebar ordering. Lower sorts first.
  var sortIndex: Int

}

// MARK: FetchableRecord, MutablePersistableRecord

extension AppPlaylist: FetchableRecord, MutablePersistableRecord {
  enum Columns {
    static let id = Column(CodingKeys.id)
    static let name = Column(CodingKeys.name)
    static let createdAt = Column(CodingKeys.createdAt)
    static let updatedAt = Column(CodingKeys.updatedAt)
    static let sortIndex = Column(CodingKeys.sortIndex)
  }

  static let databaseTableName = "app_playlist"

}
