import Foundation
import GRDB

/// A playlist playback was recently started from. Replaces the UserDefaults
/// `RecentlyPlayedStore` (migrated one-shot in Phase 3). One row per
/// playlist (`playlistID` PK) holding the most recent `playedAt`; the
/// "recents list" is this table ordered by `played_at DESC` and capped at
/// read time, so re-playing a playlist just bumps its timestamp.
///
/// No DB-level foreign key for the same reason as `favorite_playlist`: the
/// referent table varies by `source`.
struct RecentPlaylist: Codable, Identifiable, Hashable, Sendable {
    /// Apple library `MusicItemID.rawValue` or app playlist UUID. Primary key.
    var playlistID: String
    var source: PlaylistSourceKind
    var playedAt: Date

    var id: String { playlistID }

    enum CodingKeys: String, CodingKey {
        case playlistID = "playlist_id"
        case source
        case playedAt = "played_at"
    }
}

extension RecentPlaylist: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recent_playlist"

    enum Columns {
        static let playlistID = Column(CodingKeys.playlistID)
        static let source = Column(CodingKeys.source)
        static let playedAt = Column(CodingKeys.playedAt)
    }
}
