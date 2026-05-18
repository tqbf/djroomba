import Foundation
import GRDB
import Testing
@testable import DJRoomba

/// `LibraryStore.songsWithStats(matchingGenre:)` — the genre-graph
/// navigation's store query. Pins: it returns exactly the songs tagged
/// with the genre (one of the `genre_names` JSON array entries,
/// whitespace-trimmed via the same `json_each` + `TRIM` idiom as
/// `associatedPlaylists`), each song exactly once (no playlist join),
/// ordered title then artist (case-insensitive), with the `song_stat`
/// rollup joined; rows with NULL or invalid `genre_names` never match.
struct GenreSongsQueryTests {

  // MARK: Internal

  /// Multi-genre, whitespace, a non-matching song, and a NULL-genre song
  /// all in one library: only the Rock-tagged rows come back, once each,
  /// ordered by title then artist.
  @Test
  func `returns exactly the matching songs once each ordered by title then artist`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      // Multi-genre — matches on the second entry.
      song("s1", title: "Bravo", artist: "Z Artist", genres: ["Pop", "Rock"]),
      // Whitespace around the tag — TRIM must still match.
      song("s2", title: "Alpha", artist: "M Artist", genres: [" Rock "]),
      // Same title as s2 → artist is the tiebreaker.
      song("s3", title: "Alpha", artist: "A Artist", genres: ["Rock"]),
      // Different genre — must NOT match.
      song("s4", title: "Charlie", artist: "Q Artist", genres: ["Jazz"]),
      // NULL genre_names (empty array encodes to NULL) — must NOT match.
      song("s5", title: "Delta", artist: "R Artist", genres: []),
    ])

    let result = try await store.songsWithStats(matchingGenre: "Rock")

    // s3 (Alpha / A Artist) < s2 (Alpha / M Artist) < s1 (Bravo / …).
    #expect(result.map(\.song.id) == ["s3", "s2", "s1"])
  }

  /// A song tagged with the genre twice (or via two list entries that
  /// both trim to it) appears exactly once — there is no playlist join,
  /// and the `EXISTS` sub-select is membership, not a row multiplier.
  @Test
  func `each song appears exactly once even with duplicate genre entries`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      song("dup", title: "Once", artist: "A", genres: ["Rock", " Rock ", "Rock"])
    ])

    let result = try await store.songsWithStats(matchingGenre: "Rock")

    #expect(result.map(\.song.id) == ["dup"])
  }

  /// The `song_stat` LEFT JOIN is carried through: a played song reports
  /// its play count / last-played; an unplayed match is `0` / `nil`.
  @Test
  func `joins play statistics`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      song("played", title: "A", artist: "A", genres: ["Rock"]),
      song("unplayed", title: "B", artist: "B", genres: ["Rock"]),
    ])
    try await store.recordPlay(songID: "played")
    try await store.recordPlay(songID: "played")

    let byID = Dictionary(
      uniqueKeysWithValues: try await store
        .songsWithStats(matchingGenre: "Rock")
        .map { ($0.song.id, $0) }
    )

    #expect(byID["played"]?.playCount == 2)
    #expect(byID["played"]?.lastPlayedAt != nil)
    #expect(byID["unplayed"]?.playCount == 0)
    #expect(byID["unplayed"]?.lastPlayedAt == nil)
  }

  /// A row whose `genre_names` is non-NULL but NOT valid JSON must be
  /// silently skipped (the `json_valid` guard), not error the query.
  @Test
  func `invalid genre names json is ignored`() async throws {
    let (store, database) = try TestSupport.freshStoreWithDatabase()
    try await store.upsertSongs([
      song("good", title: "A", artist: "A", genres: ["Rock"]),
      song("bad", title: "B", artist: "B", genres: ["Rock"]),
    ])
    // Corrupt one row's genre_names to a non-JSON string.
    try await database.dbQueue.write { db in
      try db.execute(
        sql: "UPDATE song SET genre_names = ? WHERE id = ?",
        arguments: ["not json at all", "bad"],
      )
    }

    let result = try await store.songsWithStats(matchingGenre: "Rock")

    #expect(result.map(\.song.id) == ["good"])
  }

  /// An unknown genre returns nothing (not an error).
  @Test
  func `unknown genre returns empty`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      song("s", title: "A", artist: "A", genres: ["Rock"])
    ])

    let result = try await store.songsWithStats(matchingGenre: "Polka")

    #expect(result.isEmpty)
  }

  // MARK: Private

  private func song(
    _ id: String,
    title: String,
    artist: String,
    genres: [String],
  ) -> Song {
    Song(
      id: id,
      musicItemID: "m-\(id)",
      idNamespace: .library,
      title: title,
      artistName: artist,
      isExplicit: false,
      importedAt: .now,
      genreNames: genres,
    )
  }
}
