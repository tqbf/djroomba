import Foundation
import GRDB

/// Ordered membership of a `Song` in an imported `ApplePlaylist`.
///
/// Composite primary key `(apple_playlist_id, position)` — position is the
/// playlist order as Apple returned it. A song may appear in many Apple
/// playlists. The whole set for one playlist is deleted and re-inserted
/// inside a single import transaction (snapshot replace), so this table is
/// always internally consistent with its parent.
///
/// FK behavior: deleting the parent `apple_playlist` cascades these rows
/// (the snapshot owns its membership). `song_id` references `song(id)`;
/// import never deletes songs, so no cascade is needed there.
struct ApplePlaylistTrack: Codable, Hashable, Sendable {
    var applePlaylistID: String
    var songID: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case applePlaylistID = "apple_playlist_id"
        case songID = "song_id"
        case position
    }
}

extension ApplePlaylistTrack: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "apple_playlist_track"

    enum Columns {
        static let applePlaylistID = Column(CodingKeys.applePlaylistID)
        static let songID = Column(CodingKeys.songID)
        static let position = Column(CodingKeys.position)
    }
}
