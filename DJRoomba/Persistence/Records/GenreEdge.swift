import Foundation
import GRDB

// MARK: - GenreEdge

/// One directed half-edge of the genre co-occurrence graph (the `v6`
/// `genre_edge` table — the "Analyze" action's output).
///
/// `genreA` and `genreB` are two genre strings (verbatim from the
/// `song.genre_names` JSON list — the user's own tags, e.g. `"Alt/Indie"`),
/// `weight` is the number of **distinct** playlists (Apple *or* app) in which
/// a track of `genreA` and a track of `genreB` appear together. The graph is
/// undirected; both half-edges (`a→b` and `b→a`) are stored with the same
/// weight so "what is `X` related to" is a single PK-indexed
/// `WHERE genre_a = ?` adjacency lookup. The table is only ever rebuilt
/// wholesale by `LibraryStore.rebuildGenreGraph`, so the two directions can
/// never drift (see `LibraryMigrator` `v6.genreGraph`).
///
/// Read-only from the app's side: nothing constructs/persists a `GenreEdge`
/// directly (the rebuild is one CTE `INSERT … SELECT`); this is purely the
/// `FetchableRecord` shape for the adjacency reads / a future graph view /
/// tests. No `Identifiable` synthesis is meaningful (the identity is the
/// composite `(genreA, genreB)`), so callers key on the pair when needed.
struct GenreEdge: Codable, Hashable, Sendable {

  /// Swift camelCase ⇄ SQLite snake_case, explicit for the same reason as
  /// the other records (renaming a Swift property never silently renames a
  /// shipped column).
  enum CodingKeys: String, CodingKey {
    case genreA = "genre_a"
    case genreB = "genre_b"
    case weight
  }

  /// The "from" genre — the indexed adjacency key (`WHERE genre_a = ?`).
  var genreA: String
  /// The "to" / neighbour genre.
  var genreB: String
  /// Distinct playlists in which `genreA` and `genreB` co-occur. Symmetric:
  /// the mirrored `b→a` row carries the identical weight.
  var weight: Int

}

// MARK: FetchableRecord, TableRecord

extension GenreEdge: FetchableRecord, TableRecord {
  enum Columns {
    static let genreA = Column(CodingKeys.genreA)
    static let genreB = Column(CodingKeys.genreB)
    static let weight = Column(CodingKeys.weight)
  }

  static let databaseTableName = "genre_edge"

}
