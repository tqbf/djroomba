import Foundation
import GRDB

// MARK: - ApplePlaylist

/// A read-only *snapshot* of an Apple Music library playlist, populated by
/// the one-way import (Phase 3). The app never writes these back to Apple.
///
/// `id` is the library-namespace `MusicItemID` raw value (Apple owns this
/// identity; there is no app-minted id here because the row is purely a
/// mirror). Its track membership lives in `apple_playlist_track`, replaced
/// transactionally on every import so a changed/disappeared upstream
/// playlist re-syncs cleanly without touching app-owned data.
struct ApplePlaylist: Codable, Identifiable, Hashable, Sendable {
  enum CodingKeys: String, CodingKey {
    case id
    case name
    case artworkURL = "artwork_url"
    case curator
    case lastImportedAt = "last_imported_at"
    case changeToken = "change_token"
  }

  /// Library-namespace `MusicItemID.rawValue`. Primary key.
  var id: String
  var name: String
  var artworkURL: String?
  var curator: String?
  var lastImportedAt: Date
  /// Opaque per-playlist change token for incremental import:
  /// `Int(Playlist.lastModifiedDate.timeIntervalSince1970)` captured at
  /// import time from the cheap library-list fetch. `nil` when MusicKit
  /// didn't provide a `lastModifiedDate` (common on macOS — see
  /// musickit-notes) or the row predates the v2 migration; the import
  /// decision treats `nil` as "no comparable signal → re-fetch", so the
  /// default keeps every existing call site (and old rows) correct.
  var changeToken: Int? = nil

}

// MARK: FetchableRecord, MutablePersistableRecord

extension ApplePlaylist: FetchableRecord, MutablePersistableRecord {
  enum Columns {
    static let id = Column(CodingKeys.id)
    static let name = Column(CodingKeys.name)
    static let artworkURL = Column(CodingKeys.artworkURL)
    static let curator = Column(CodingKeys.curator)
    static let lastImportedAt = Column(CodingKeys.lastImportedAt)
    static let changeToken = Column(CodingKeys.changeToken)
  }

  static let databaseTableName = "apple_playlist"

}
