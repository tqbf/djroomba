import Foundation
import Testing
@testable import DJRoomba

/// `LibraryStore.renameGenre` / `addGenre` / `distinctGenres`. Pins the
/// merge behaviour end-to-end through SQLite (rename onto an existing genre
/// unions the songs), idempotent assign, the chunk-boundary batch write,
/// and the **one-way isolation** invariant — only `song.genre_names`
/// moves; apple/app playlists, play stats, history, favorites and recents
/// are untouched (the same assertion every other store-mutation test
/// makes).
struct GenreEditStoreTests {

  // MARK: Internal

  @Test
  func `rename merges onto an existing genre and is one-way isolated`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      song(id: "s1", genres: ["Rok"]),
      song(id: "s2", genres: ["Rock"]),
      song(id: "s3", genres: ["Rok", "Rock"]), // carries BOTH → merge case
      song(id: "s4", genres: ["Jazz"]),
    ])
    // Fixture across every app-owned table.
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "ap", name: "Mix", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["s1", "s2", "s3", "s4"],
    )
    let app = try await store.createAppPlaylist(named: "Faves")
    try await store.addSongsToAppPlaylist(app.id, songIDs: ["s2"])
    try await store.recordPlay(songID: "s1")
    try await store.setFavorite(true, playlistID: "ap", source: .apple)
    try await store.recordRecent(playlistID: "ap", source: .apple)

    let changed = try await store.renameGenre(from: "Rok", to: "Rock")
    // s1 (Rok→Rock) and s3 (Rok,Rock→Rock) changed; s2/s4 untouched.
    #expect(changed == 2)
    #expect(try await store.song(id: "s1")?.genreNames == ["Rock"])
    #expect(try await store.song(id: "s2")?.genreNames == ["Rock"])
    #expect(try await store.song(id: "s3")?.genreNames == ["Rock"]) // merged + deduped
    #expect(try await store.song(id: "s4")?.genreNames == ["Jazz"])

    // The merge from the query's point of view: "Rock" now unions s1+s2+s3,
    // and "Rok" no longer exists.
    let rockIDs = try await store.songsWithStats(matchingGenre: "Rock")
      .map(\.song.id).sorted()
    #expect(rockIDs == ["s1", "s2", "s3"])
    #expect(try await store.songsWithStats(matchingGenre: "Rok").isEmpty)
    #expect(!(try await store.distinctGenres().contains("Rok")))

    // One-way isolation: nothing but song.genre_names moved.
    #expect(try await store.songs(inApplePlaylist: "ap").map(\.id) == ["s1", "s2", "s3", "s4"])
    #expect(try await store.songs(inAppPlaylist: app.id).map(\.id) == ["s2"])
    #expect(try await store.songStat(songID: "s1")?.playCount == 1)
    #expect(try await store.favorites().map(\.playlistID) == ["ap"])
    #expect(try await store.recentPlaylists().map(\.playlistID) == ["ap"])
  }

  @Test
  func `addGenre appends, is idempotent, and one-way isolated`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      song(id: "s1", genres: ["Rock"]),
      song(id: "s2", genres: []),
    ])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "ap", name: "Mix", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["s1", "s2"],
    )
    try await store.recordPlay(songID: "s1")

    let added = try await store.addGenre("Live", toSongIDs: ["s1", "s2"])
    #expect(added == 2)
    #expect(try await store.song(id: "s1")?.genreNames == ["Rock", "Live"])
    #expect(try await store.song(id: "s2")?.genreNames == ["Live"])

    // Idempotent: re-adding the same genre changes nothing.
    #expect(try await store.addGenre("Live", toSongIDs: ["s1", "s2"]) == 0)

    // Isolation.
    #expect(try await store.songs(inApplePlaylist: "ap").map(\.id) == ["s1", "s2"])
    #expect(try await store.songStat(songID: "s1")?.playCount == 1)
  }

  @Test
  func `distinctGenres is trimmed, de-duped, non-empty, NOCASE ordered`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      song(id: "s1", genres: [" Pop ", "rock", ""]),
      song(id: "s2", genres: ["Pop", "ROCK", "Jazz"]),
    ])
    // "Pop" (trim-deduped), "rock"/"ROCK" are distinct values but ordered
    // case-insensitively; empties dropped.
    let genres = try await store.distinctGenres()
    #expect(genres.contains("Pop"))
    #expect(genres.contains("Jazz"))
    #expect(!genres.contains(""))
    // Case-insensitive ascending order.
    #expect(genres == genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
  }

  @Test
  func `rename is correct across a chunk boundary`() async throws {
    let store = try TestSupport.freshStore()
    // > 499 rows/chunk so the batched write spans multiple statements.
    let n = 1100
    let songs = (0..<n).map { song(id: "s\($0)", genres: ["Old"]) }
    try await store.upsertSongs(songs)

    let changed = try await store.renameGenre(from: "Old", to: "New")
    #expect(changed == n)
    #expect(try await store.songsWithStats(matchingGenre: "New").count == n)
    #expect(try await store.songsWithStats(matchingGenre: "Old").isEmpty)
  }

  // MARK: Private

  private func song(
    id: String,
    genres: [String],
    title: String = "T",
  ) -> Song {
    Song(
      id: id,
      musicItemID: "mid-\(id)",
      idNamespace: .library,
      title: title,
      artistName: "A",
      albumTitle: "Al",
      isExplicit: false,
      importedAt: .now,
      genreNames: genres,
    )
  }

}
