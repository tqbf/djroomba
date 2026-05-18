import Foundation
import Testing
@testable import DJRoomba

/// `LibraryStore.rebuildGenreGraph` + the `genre_edge` adjacency reads —
/// the "Analyze" action's deterministic SQLite half. Pins: an undirected
/// genre co-occurrence edge is materialized in BOTH directions with a
/// symmetric weight; weight counts **distinct** playlists (a song listed
/// twice in one playlist does not inflate it); a multi-genre song links its
/// own genres; Apple and app playlists both feed the graph and are counted
/// as distinct playlists (the source-prefixed composite key); NULL / blank /
/// invalid genre JSON is ignored without aborting the rebuild; genres that
/// never share a playlist produce no edge; the adjacency read is ordered
/// strongest-first and honors `limit`; the rebuild is idempotent; and it is
/// one-way isolated (touches only `genre_edge`).
///
/// The MusicKit-free service wrapper (`GenreGraphService`) is a thin
/// `isAnalyzing`-guarded call into this store method; the graph correctness
/// lives here, exactly as `AlbumGenreApplyTests` covers the genre-import
/// store half rather than the un-unit-testable MusicKit fetch.
struct GenreGraphTests {

  // MARK: Internal

  @Test
  func `co occurrence builds symmetric weighted edges in both directions`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
    ])
    try await Self.apple(store, "P1", songIDs: ["r", "j"])

    let count = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)
    #expect(count == 2, "one undirected edge ⇒ two directed half-edges")

    #expect(
      try await store.relatedGenres(to: "Rock")
        == [GenreEdge(genreA: "Rock", genreB: "Jazz", weight: 1)]
    )
    #expect(
      try await store.relatedGenres(to: "Jazz")
        == [GenreEdge(genreA: "Jazz", genreB: "Rock", weight: 1)]
    )
  }

  /// Weight = number of DISTINCT playlists the pair co-occurs in. A song
  /// listed twice in the SAME playlist must NOT inflate it (the
  /// `playlist_genre` `DISTINCT`), and an Apple and an app playlist are two
  /// distinct playlists (the `'apple:'`/`'app:'` composite key — they must
  /// not merge into one).
  @Test
  func `weight counts distinct playlists across both libraries`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
    ])
    // Apple P1: Rock listed TWICE (duplicate position) + Jazz once.
    try await Self.apple(store, "P1", songIDs: ["r", "r", "j"])
    // App A1: the same genre pair, a separate playlist.
    let a1 = try await store.createAppPlaylist(named: "A1")
    try await store.addSongsToAppPlaylist(a1.id, songIDs: ["r", "j"])

    _ = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)

    #expect(
      try await store.relatedGenres(to: "Rock")
        == [GenreEdge(genreA: "Rock", genreB: "Jazz", weight: 2)],
      "2 distinct playlists; the duplicated Rock row collapses",
    )
  }

  /// A single song carrying multiple genres relates those genres to each
  /// other within the playlist (the `json_each` explode + the per-playlist
  /// self-join), even with nobody else in the list.
  @Test
  func `a multi genre song links its own genres`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s", genres: ["Alt/Indie", "Rock"])
    ])
    try await Self.apple(store, "P1", songIDs: ["s"])

    _ = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)

    // Canonical orientation is a<b ("Alt/Indie" < "Rock"); both halves exist.
    let edges = try await store.genreGraphEdges()
    #expect(Set(edges) == [
      GenreEdge(genreA: "Alt/Indie", genreB: "Rock", weight: 1),
      GenreEdge(genreA: "Rock", genreB: "Alt/Indie", weight: 1),
    ])
  }

  @Test
  func `genres that never share a playlist have no edge`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
    ])
    try await Self.apple(store, "P1", songIDs: ["r"])
    try await Self.apple(store, "P2", songIDs: ["j"])

    let count = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)
    #expect(count == 0)
    #expect(try await store.genreGraphEdges().isEmpty)
  }

  /// NULL (empty list ⇒ NULL column), whitespace-only, and a genre-less
  /// song in the same playlist must be ignored and must not abort the
  /// rebuild (the `IS NOT NULL` / `json_valid` / `TRIM <> ''` guards).
  @Test
  func `null empty and blank genres are ignored without aborting`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
      Self.song("none", genres: []), // → genre_names NULL
      Self.song("blank", genres: ["   ", ""]), // all trim to empty
    ])
    try await Self.apple(store, "P1", songIDs: ["r", "j", "none", "blank"])

    let count = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)
    #expect(count == 2, "only the real Rock↔Jazz edge, both directions")
    #expect(
      try await store.relatedGenres(to: "Rock")
        == [GenreEdge(genreA: "Rock", genreB: "Jazz", weight: 1)]
    )
  }

  /// The adjacency read is strongest-first, ties broken by neighbour name,
  /// and `limit` is honored.
  @Test
  func `related genres are ordered by weight then name and limited`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
      Self.song("e", genres: ["Electronic"]),
      Self.song("f", genres: ["Funk"]),
    ])
    // Rock↔Jazz in two playlists (weight 2); Rock↔Electronic and Rock↔Funk
    // in one each (weight 1) — Electronic sorts before Funk.
    try await Self.apple(store, "P1", songIDs: ["r", "j"])
    try await Self.apple(store, "P2", songIDs: ["r", "j", "e"])
    try await Self.apple(store, "P3", songIDs: ["r", "f"])

    _ = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)

    #expect(try await store.relatedGenres(to: "Rock") == [
      GenreEdge(genreA: "Rock", genreB: "Jazz", weight: 2),
      GenreEdge(genreA: "Rock", genreB: "Electronic", weight: 1),
      GenreEdge(genreA: "Rock", genreB: "Funk", weight: 1),
    ])
    #expect(
      try await store.relatedGenres(to: "Rock", limit: 1)
        == [GenreEdge(genreA: "Rock", genreB: "Jazz", weight: 2)],
      "limit caps the neighbour list at the strongest",
    )
  }

  /// Re-running the analyze on unchanged data yields the identical table
  /// (wholesale DELETE + rebuild — no accumulation, no duplicate rows).
  @Test
  func `rebuild is idempotent`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
    ])
    try await Self.apple(store, "P1", songIDs: ["r", "j"])

    let first = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)
    let firstEdges = try await store.genreGraphEdges()
    let second = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)
    let secondEdges = try await store.genreGraphEdges()

    #expect(first == second)
    #expect(firstEdges == secondEdges)
    #expect(firstEdges.count == 2)
  }

  /// One-way isolation, mirroring `AlbumGenreApplyTests`: rebuilding the
  /// graph touches ONLY `genre_edge` — song / app-playlist / apple-snapshot
  /// / stat / history / favorites / recents are all left exactly as they
  /// were, and a clearing rebuild on emptied data is also isolated.
  @Test
  func `rebuild is one way isolated`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
    ])
    let mine = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(mine.id, songIDs: ["r", "j"])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "A", name: "A", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["r", "j"],
    )
    try await store.setFavorite(true, playlistID: "A", source: .apple)
    try await store.recordRecent(playlistID: "A", source: .apple)
    try await store.recordPlay(songID: "r")

    _ = try await store.rebuildGenreGraph(maxPlaylistTracks: 100_000, maxPairsPerPlaylist: 100_000)

    // Everything else is intact.
    #expect(try await store.songCount() == 2)
    #expect(try await store.song(id: "r")?.genreNames == ["Rock"])
    #expect(try await store.songs(inAppPlaylist: mine.id).map(\.id) == ["r", "j"])
    #expect(try await store.songs(inApplePlaylist: "A").map(\.id) == ["r", "j"])
    #expect(try await store.favorites().count == 1)
    #expect(try await store.recentPlaylists().count == 1)
    #expect(try await store.songStat(songID: "r")?.playCount == 1)
    #expect(try await store.recentlyPlayedSongIDs() == ["r"])

    // And the graph itself was built.
    #expect(try await store.genreGraphEdges().count == 2)
  }

  /// Threshold (a): a playlist with more than `maxPlaylistTracks` tracks is
  /// excluded from analysis entirely, so the genre pairs it would have
  /// clique-created never enter the graph.
  @Test
  func `oversized playlists are excluded from analysis`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
      Self.song("p1", genres: ["Pop"]),
      Self.song("p2", genres: ["Pop"]),
    ])
    // Small (2 tracks) — eligible at threshold 3.
    try await Self.apple(store, "Small", songIDs: ["r", "j"])
    // Big (4 tracks) — over threshold 3, excluded. Would otherwise add
    // Pop↔Rock / Pop↔Jazz and bump Rock↔Jazz to weight 2.
    try await Self.apple(store, "Big", songIDs: ["r", "j", "p1", "p2"])

    let count = try await store.rebuildGenreGraph(
      maxPlaylistTracks: 3,
      maxPairsPerPlaylist: 100_000,
    )
    #expect(count == 2, "only Rock↔Jazz from the small playlist, both dirs")
    #expect(
      try await store.relatedGenres(to: "Rock")
        == [GenreEdge(genreA: "Rock", genreB: "Jazz", weight: 1)],
      "weight 1 (Small only) — Big did not also contribute it",
    )
    #expect(
      try await store.relatedGenres(to: "Pop").isEmpty,
      "Pop only ever appeared in the excluded oversized playlist",
    )
  }

  /// Threshold (b): each eligible playlist contributes only its top-N
  /// genre pairs by intra-playlist co-strength
  /// (`min(tracksOfA, tracksOfB)`). With N = 1 only the single strongest
  /// pair of the playlist survives; the weaker pairs (and any genre that
  /// only appeared in them) are dropped.
  @Test
  func `each playlist contributes only its top N strongest pairs`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("a1", genres: ["A"]),
      Self.song("a2", genres: ["A"]),
      Self.song("a3", genres: ["A"]), // 3 A tracks
      Self.song("b1", genres: ["B"]),
      Self.song("b2", genres: ["B"]), // 2 B tracks
      Self.song("c1", genres: ["C"]), // 1 C track
    ])
    // One playlist. Pair strengths: A↔B = min(3,2)=2 (strongest);
    // A↔C = min(3,1)=1; B↔C = min(2,1)=1.
    try await Self.apple(store, "P", songIDs: ["a1", "a2", "a3", "b1", "b2", "c1"])

    let count = try await store.rebuildGenreGraph(
      maxPlaylistTracks: 100_000,
      maxPairsPerPlaylist: 1,
    )
    #expect(count == 2, "only the strongest pair A↔B survives, both dirs")
    #expect(
      try await store.relatedGenres(to: "A")
        == [GenreEdge(genreA: "A", genreB: "B", weight: 1)]
    )
    #expect(
      try await store.relatedGenres(to: "C").isEmpty,
      "C's only pairs (A↔C, B↔C) were the weaker, dropped ones",
    )
  }

  /// Associated-playlists card data: a single genre lists every playlist
  /// it appears in, strength = distinct tracks of that genre, sorted desc
  /// then name, across both libraries with real names.
  @Test
  func `associated playlists for a genre by strength`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r1", genres: ["Rock"]),
      Self.song("r2", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
    ])
    try await Self.apple(store, "P1", songIDs: ["r1", "r2", "j"]) // Rock=2
    let mine = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(mine.id, songIDs: ["r1", "j"]) // Rock=1

    let rock = try await store.associatedPlaylists(
      genre: "Rock",
      neighbor: nil,
      limit: 10,
    )
    #expect(rock.map(\.name) == ["P1", "Mine"], "strength desc (2, 1)")
    #expect(rock.map(\.strength) == [2, 1])
    #expect(rock.map(\.isAppOwned) == [false, true])

    // The limit caps the card.
    #expect(try await store.associatedPlaylists(genre: "Rock", neighbor: nil, limit: 1).count == 1)
  }

  /// Edge narrowing: with a neighbour, only playlists where BOTH genres
  /// co-occur, strength = the pair co-strength `min(tracksA, tracksB)`.
  @Test
  func `associated playlists narrowed to a genre edge`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r1", genres: ["Rock"]),
      Self.song("r2", genres: ["Rock"]),
      Self.song("j", genres: ["Jazz"]),
    ])
    try await Self.apple(store, "Both", songIDs: ["r1", "r2", "j"]) // min(2,1)=1
    try await Self.apple(store, "RockOnly", songIDs: ["r1", "r2"]) // no Jazz
    let mine = try await store.createAppPlaylist(named: "Aux")
    try await store.addSongsToAppPlaylist(mine.id, songIDs: ["r1", "j"]) // min(1,1)=1

    let edge = try await store.associatedPlaylists(
      genre: "Rock",
      neighbor: "Jazz",
      limit: 10,
    )
    #expect(
      Set(edge.map(\.name)) == ["Both", "Aux"],
      "only playlists with BOTH genres — RockOnly excluded",
    )
    #expect(edge.allSatisfy { $0.strength == 1 }, "min(Rock,Jazz) per playlist")
    // The single-genre query still includes the Rock-only playlist.
    #expect(
      Set(try await store.associatedPlaylists(genre: "Rock", neighbor: nil, limit: 10).map(\.name))
        == ["Both", "RockOnly", "Aux"]
    )
  }

  // MARK: Private

  private static func song(_ id: String, genres: [String]) -> Song {
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

  private static func apple(
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
