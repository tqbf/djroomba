import Foundation
import GRDB

// MARK: - GenreMapStateRow

/// One row of the `v9` `genre_map_state` table — the persisted Phase-6
/// layout state for a single genre (`plans/genre-metro-map.md` Phase 6).
/// Written wholesale by `LibraryStore.writeGenreMapState`; read-only from
/// the app's side.
///
/// `x`/`y` are world-space layout coordinates from the most-recent build.
/// `communityCoarse`/`communityMedium`/`communityFine` are **string**
/// community ids (algorithmic small-ints stringified for matched
/// communities; freshly-minted ids carry the `new-…` prefix). `strandIds`
/// is a JSON array of integer strand ids the genre serves. `revision`
/// bumps wholesale on each rebuild.
struct GenreMapStateRow: Codable, Hashable, Sendable {

  enum CodingKeys: String, CodingKey {
    case genre
    case x
    case y
    case communityCoarse = "community_coarse"
    case communityMedium = "community_medium"
    case communityFine = "community_fine"
    case strandIds = "strand_ids"
    case updatedAt = "updated_at"
    case revision
  }

  var genre: String
  var x: Double
  var y: Double
  var communityCoarse: String
  var communityMedium: String
  var communityFine: String
  /// JSON array of integer strand ids — e.g. `"[1,4,7]"`.
  var strandIds: String
  /// Unix epoch seconds (integer). Stored as `INTEGER` for exact equality.
  var updatedAt: Int64
  var revision: Int
}

// MARK: FetchableRecord, PersistableRecord, TableRecord

extension GenreMapStateRow: FetchableRecord, PersistableRecord, TableRecord {
  enum Columns {
    static let genre = Column(CodingKeys.genre)
    static let x = Column(CodingKeys.x)
    static let y = Column(CodingKeys.y)
    static let communityCoarse = Column(CodingKeys.communityCoarse)
    static let communityMedium = Column(CodingKeys.communityMedium)
    static let communityFine = Column(CodingKeys.communityFine)
    static let strandIds = Column(CodingKeys.strandIds)
    static let updatedAt = Column(CodingKeys.updatedAt)
    static let revision = Column(CodingKeys.revision)
  }

  static let databaseTableName = "genre_map_state"
}

// MARK: - GenreMapStrandRow

/// One row of the `v9` `genre_map_strand` table — the persisted Phase-6
/// per-strand state (`plans/genre-metro-map.md` Phase 6). Keyed by the
/// **stable** `strand_id` minted across rebuilds via the strand-matching
/// pass; the colour + label tokens persist so a re-Analyze with an
/// unchanged member set leaves the strand visibly identical.
struct GenreMapStrandRow: Codable, Hashable, Sendable {

  enum CodingKeys: String, CodingKey {
    case strandID = "strand_id"
    case colour
    case labelTokens = "label_tokens"
    case revision
  }

  /// String form of the stable strand id (small-int stringified for
  /// matched strands; freshly-minted ids carry the `new-…` prefix).
  var strandID: String
  /// ARGB-packed colour (stored as `Int64` for SQLite signedness).
  var colour: Int64
  /// JSON array of label tokens — e.g. `"[\"Alternative\",\"Britpop\"]"`.
  var labelTokens: String
  var revision: Int
}

// MARK: FetchableRecord, PersistableRecord, TableRecord

extension GenreMapStrandRow: FetchableRecord, PersistableRecord, TableRecord {
  enum Columns {
    static let strandID = Column(CodingKeys.strandID)
    static let colour = Column(CodingKeys.colour)
    static let labelTokens = Column(CodingKeys.labelTokens)
    static let revision = Column(CodingKeys.revision)
  }

  static let databaseTableName = "genre_map_strand"
}
