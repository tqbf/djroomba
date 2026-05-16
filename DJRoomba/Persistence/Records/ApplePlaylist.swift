import Foundation
import GRDB

/// A read-only *snapshot* of an Apple Music library playlist, populated by
/// the one-way import (Phase 3). The app never writes these back to Apple.
///
/// `id` is the library-namespace `MusicItemID` raw value (Apple owns this
/// identity; there is no app-minted id here because the row is purely a
/// mirror). Its track membership lives in `apple_playlist_track`, replaced
/// transactionally on every import so a changed/disappeared upstream
/// playlist re-syncs cleanly without touching app-owned data.
struct ApplePlaylist: Codable, Identifiable, Hashable, Sendable {
    /// Library-namespace `MusicItemID.rawValue`. Primary key.
    var id: String
    var name: String
    var artworkURL: String?
    var curator: String?
    var lastImportedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artworkURL = "artwork_url"
        case curator
        case lastImportedAt = "last_imported_at"
    }
}

extension ApplePlaylist: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "apple_playlist"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let artworkURL = Column(CodingKeys.artworkURL)
        static let curator = Column(CodingKeys.curator)
        static let lastImportedAt = Column(CodingKeys.lastImportedAt)
    }
}
