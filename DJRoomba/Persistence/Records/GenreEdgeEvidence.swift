import Foundation
import GRDB

// MARK: - GenreEdgeEvidence

/// One canonical-half row of the `v7` `genre_edge_evidence` table — the
/// multi-channel edge model for the genre metro map. Unlike the v6
/// `genre_edge` (which mirrors `a→b` and `b→a` for cheap adjacency reads),
/// only the canonical `genreA < genreB` half is stored: the map pipeline
/// reads the whole table once and folds in memory, so a mirror would be
/// dead weight.
///
/// `totalWeight` is the composite per the spec:
///     0.45 · artist_jaccard
///   + 0.35 · album_jaccard
///   + 0.15 · track_jaccard
///   + 0.05 · playlist_cooccurrence_norm
/// with a support floor (rows whose `sharedArtistCount + sharedAlbumCount +
/// sharedTrackCount < 2` are dropped at write time, never persisted).
/// `playlistCooccurWeight` is the v6 `genre_edge.weight` normalised across
/// the analyzed graph to `[0, 1]`.
struct GenreEdgeEvidence: Codable, Hashable, Sendable {

  enum CodingKeys: String, CodingKey {
    case genreA = "genre_a"
    case genreB = "genre_b"
    case artistOverlapJaccard = "artist_overlap_jaccard"
    case albumOverlapJaccard = "album_overlap_jaccard"
    case trackOverlapJaccard = "track_overlap_jaccard"
    case playlistCooccurWeight = "playlist_cooccur_weight"
    case sharedArtistCount = "shared_artist_count"
    case sharedAlbumCount = "shared_album_count"
    case sharedTrackCount = "shared_track_count"
    case totalWeight = "total_weight"
  }

  var genreA: String
  var genreB: String
  var artistOverlapJaccard: Double
  var albumOverlapJaccard: Double
  var trackOverlapJaccard: Double
  var playlistCooccurWeight: Double
  var sharedArtistCount: Int
  var sharedAlbumCount: Int
  var sharedTrackCount: Int
  var totalWeight: Double

}

// MARK: FetchableRecord, TableRecord

extension GenreEdgeEvidence: FetchableRecord, TableRecord {
  enum Columns {
    static let genreA = Column(CodingKeys.genreA)
    static let genreB = Column(CodingKeys.genreB)
    static let artistOverlapJaccard = Column(CodingKeys.artistOverlapJaccard)
    static let albumOverlapJaccard = Column(CodingKeys.albumOverlapJaccard)
    static let trackOverlapJaccard = Column(CodingKeys.trackOverlapJaccard)
    static let playlistCooccurWeight = Column(CodingKeys.playlistCooccurWeight)
    static let sharedArtistCount = Column(CodingKeys.sharedArtistCount)
    static let sharedAlbumCount = Column(CodingKeys.sharedAlbumCount)
    static let sharedTrackCount = Column(CodingKeys.sharedTrackCount)
    static let totalWeight = Column(CodingKeys.totalWeight)
  }

  static let databaseTableName = "genre_edge_evidence"
}
