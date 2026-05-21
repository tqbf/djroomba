import Foundation
import GRDB

// MARK: - GenreNode

/// One row of the `v7` `genre_node` table — the per-genre weight + the raw
/// cardinalities that fed it. Written wholesale by
/// `LibraryStore.rebuildGenreMap`; read-only from the app's side.
///
/// `weight` is the normalised importance in `[0, 1]`, shaped from
/// `log(1 + track_count) + 0.8·log(1 + album_count) + 1.2·log(1 +
/// artist_count)` and then divided by the max raw weight across all rows in
/// the same rebuild — see `LibraryStore+GenreMap`. The raw counts are
/// preserved alongside so the layout / future tooltips can show "how big is
/// this genre" without re-querying the underlying joins.
struct GenreNode: Codable, Hashable, Sendable {

  enum CodingKeys: String, CodingKey {
    case genre
    case trackCount = "track_count"
    case albumCount = "album_count"
    case artistCount = "artist_count"
    case weight
  }

  var genre: String
  var trackCount: Int
  var albumCount: Int
  var artistCount: Int
  var weight: Double

}

// MARK: FetchableRecord, TableRecord

extension GenreNode: FetchableRecord, TableRecord {
  enum Columns {
    static let genre = Column(CodingKeys.genre)
    static let trackCount = Column(CodingKeys.trackCount)
    static let albumCount = Column(CodingKeys.albumCount)
    static let artistCount = Column(CodingKeys.artistCount)
    static let weight = Column(CodingKeys.weight)
  }

  static let databaseTableName = "genre_node"
}
