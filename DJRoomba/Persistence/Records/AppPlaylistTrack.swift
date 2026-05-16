import Foundation
import GRDB

/// Ordered membership of a `Song` in a user-owned `AppPlaylist`.
///
/// Composite primary key `(app_playlist_id, position)`. Deleting the parent
/// `app_playlist` cascades these rows (the playlist owns its membership).
/// `song_id` references `song(id)`; a song's history must outlive playlist
/// membership, so deleting a song is RESTRICTed at the schema level rather
/// than cascading silent data loss (see LibraryMigrator).
struct AppPlaylistTrack: Codable, Hashable, Sendable {
    var appPlaylistID: String
    var songID: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case appPlaylistID = "app_playlist_id"
        case songID = "song_id"
        case position
    }
}

extension AppPlaylistTrack: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "app_playlist_track"

    enum Columns {
        static let appPlaylistID = Column(CodingKeys.appPlaylistID)
        static let songID = Column(CodingKeys.songID)
        static let position = Column(CodingKeys.position)
    }
}
