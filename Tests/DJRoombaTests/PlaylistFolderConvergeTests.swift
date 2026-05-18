import Foundation
import Testing
@testable import DJRoomba

/// Phase 3 (playlist-folders.md) — `LibraryStore.deleteApplePlaylists(ids:)`,
/// the active convergence of an already-stored folder snapshot. A folder's
/// MusicKit id stays *live* in the playlist list, so the end-of-import
/// `pruneApplePlaylists(keeping:)` can't drop a stale folder row; this method
/// deletes it directly. Pins the **one-way isolation** invariant: deleting a
/// folder `apple_playlist` cascades only ITS `apple_playlist_track`
/// membership — `song` (delete-RESTRICTed), the other `apple_playlist*`,
/// `app_playlist*`, `song_stat`, `play_history`, favorites and recents are
/// left exactly as they were; the empty-set call (the iTunesLibrary
/// graceful-degradation case) is a no-op; and a converged folder no longer
/// contributes its membership to the rebuilt genre graph.
struct PlaylistFolderConvergeTests {

  // MARK: Internal

  @Test
  func `delete folder removes only its snapshot and membership`() async throws {
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["s1", "s2", "s3"])

    // A "folder" snapshot (the flattened union of its children) and a real
    // imported playlist, each with membership.
    try await apple(store, "folder-1", songIDs: ["s1", "s2", "s3"])
    try await apple(store, "real-1", songIDs: ["s1", "s2"])

    // App-owned data referencing surviving songs — must be untouched.
    let mine = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(mine.id, songIDs: ["s1", "s3"])
    try await store.recordPlay(songID: "s1", at: Date(timeIntervalSince1970: 10))
    try await store.setFavorite(true, playlistID: "real-1", source: .apple)
    try await store.recordRecent(playlistID: "real-1", source: .apple)

    try await store.deleteApplePlaylists(ids: ["folder-1"])

    // The folder snapshot AND its membership are gone (FK cascade).
    #expect(try await store.applePlaylists().map(\.id) == ["real-1"])
    #expect(try await store.songs(inApplePlaylist: "folder-1").isEmpty)

    // The real playlist + its membership survive intact.
    #expect(try await store.songs(inApplePlaylist: "real-1").map(\.id) == ["s1", "s2"])

    // Songs / app playlist / stats / history / favorites / recents — all
    // byte-for-byte untouched (the one-way isolation invariant).
    #expect(try await store.songCount() == 3)
    #expect(try await store.songs(inAppPlaylist: mine.id).map(\.id) == ["s1", "s3"])
    #expect(try await store.songStat(songID: "s1")?.playCount == 1)
    #expect(try await store.recentlyPlayedSongIDs() == ["s1"])
    #expect(try await store.favorites().map(\.playlistID) == ["real-1"])
    #expect(try await store.recentPlaylists().map(\.playlistID) == ["real-1"])
  }

  @Test
  func `empty set is a no op`() async throws {
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["s1"])
    try await apple(store, "real-1", songIDs: ["s1"])

    // The iTunesLibrary graceful-degradation case: nothing classified as a
    // folder → no exclusion, today's behavior, no DB mutation.
    try await store.deleteApplePlaylists(ids: [])

    #expect(try await store.applePlaylists().map(\.id) == ["real-1"])
    #expect(try await store.songs(inApplePlaylist: "real-1").map(\.id) == ["s1"])
    #expect(try await store.songCount() == 1)
  }

  /// After converging the folder away and rebuilding the graph, the folder's
  /// membership no longer creates edges. The folder ("AAA ME"-shaped) is the
  /// union of its children, so before the fix it manufactured a Rock↔Jazz
  /// edge; once deleted, only the real playlist's genres relate.
  @Test
  func `converged folder no longer contributes genre edges`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.genreSong("r", genres: ["Rock"]),
      Self.genreSong("j", genres: ["Jazz"]),
      Self.genreSong("p", genres: ["Pop"]),
    ])
    // Folder = union of children: Rock + Jazz + Pop together (it alone
    // would link all three).
    try await apple(store, "folder-1", songIDs: ["r", "j", "p"])
    // The real playlist only ever pairs Rock with Pop.
    try await apple(store, "real-1", songIDs: ["r", "p"])

    try await store.deleteApplePlaylists(ids: ["folder-1"])
    _ = try await store.rebuildGenreGraph(
      maxPlaylistTracks: 100_000,
      maxPairsPerPlaylist: 100_000,
    )

    // Only Rock↔Pop survives (from the real playlist), both directed
    // halves. Jazz no longer shares a playlist with anything → no edge,
    // proving the folder's flattened membership stopped feeding the graph.
    #expect(try await store.genreGraphEdges().count == 2)
    #expect(try await store.relatedGenres(to: "Rock")
      == [GenreEdge(genreA: "Rock", genreB: "Pop", weight: 1)])
    #expect(try await store.relatedGenres(to: "Jazz").isEmpty)
  }

  /// The associations-card half of the previous test: a folder converged
  /// away must also stop appearing in `associatedPlaylists`. "AAA ME" was
  /// the union of its children, so a genre present *only* inside a child
  /// (here Jazz) leaked into the folder's flattened membership and the
  /// folder ranked top of that genre's card. After `deleteApplePlaylists`
  /// + `rebuildGenreGraph`, the folder must be gone from the card, while a
  /// genre that legitimately lives in the real playlist still resolves to
  /// the real playlist alone.
  @Test
  func `converged folder no longer appears in associated playlists`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.genreSong("r", genres: ["Rock"]),
      Self.genreSong("j", genres: ["Jazz"]),
      Self.genreSong("p", genres: ["Pop"]),
    ])
    // Folder = flattened union of its children (Rock + Jazz + Pop). Jazz is
    // ONLY ever in the folder — before the fix the folder owned the Jazz
    // card outright.
    try await apple(store, "folder-1", songIDs: ["r", "j", "p"])
    // The real playlist genuinely pairs Rock with Pop (no Jazz).
    try await apple(store, "real-1", songIDs: ["r", "p"])

    try await store.deleteApplePlaylists(ids: ["folder-1"])
    _ = try await store.rebuildGenreGraph(
      maxPlaylistTracks: 100_000,
      maxPairsPerPlaylist: 100_000,
    )

    // Jazz lived only inside the folder → with the folder converged away no
    // playlist is associated with it at all (the "AAA ME 57" symptom gone).
    #expect(try await store.associatedPlaylists(genre: "Jazz", neighbor: nil, limit: 50).isEmpty)

    // Rock is genuinely in the real playlist → it still resolves, and ONLY
    // to the real playlist (never the deleted folder).
    let rock = try await store.associatedPlaylists(genre: "Rock", neighbor: nil, limit: 50)
    #expect(rock.map(\.name) == ["real-1"])
    #expect(rock.map(\.playlistID) == ["real-1"])
    #expect(rock.allSatisfy { !$0.isAppOwned })

    // The Rock↔Pop edge (the surviving graph edge) is backed only by the
    // real playlist — the converged folder contributes no edge card either.
    let edge = try await store.associatedPlaylists(genre: "Rock", neighbor: "Pop", limit: 50)
    #expect(edge.map(\.name) == ["real-1"])
  }

  // MARK: Private

  private static func genreSong(_ id: String, genres: [String]) -> Song {
    Song(
      id: id,
      musicItemID: "m_\(id)",
      idNamespace: .library,
      title: id,
      artistName: "Artist",
      isExplicit: false,
      importedAt: .now,
      genreNames: genres,
    )
  }

  private func seedSongs(_ store: LibraryStore, _ ids: [String]) async throws {
    try await store.upsertSongs(ids.map {
      TestSupport.sampleSong(id: $0, musicItemID: $0, title: "T\($0)")
    })
  }

  private func apple(
    _ store: LibraryStore,
    _ id: String,
    songIDs: [String],
  ) async throws {
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: id, name: id, artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: songIDs,
    )
  }

}
