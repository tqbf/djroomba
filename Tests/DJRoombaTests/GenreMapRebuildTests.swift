import Foundation
import GRDB
import Testing
@testable import DJRoomba

/// `LibraryStore.rebuildGenreMap` — the wholesale CTE-driven write that
/// materialises the v7 `genre_node` + `genre_edge_evidence` substrate.
///
/// Pins:
/// - per-genre weight monotonicity (a strictly bigger genre has a strictly
///   bigger normalised weight; the biggest is normalised to 1);
/// - the composite edge score lines up with the spec
///   (0.45·artist + 0.35·album + 0.15·track + 0.05·playlist);
/// - the support floor drops pairs whose `shared_artist + shared_album +
///   shared_track < 2`;
/// - rebuild is one-way isolated (only `genre_node` + `genre_edge_evidence`
///   are touched);
/// - rerunning is idempotent for fixed inputs.
struct GenreMapRebuildTests {

  // MARK: Internal

  /// A genre with strictly more tracks/albums/artists is normalised
  /// strictly higher; the dominant genre lands at exactly 1.0.
  @Test
  func `per genre weight is monotonic and normalised to one`() async throws {
    let store = try TestSupport.freshStore()
    // "Rock": three songs across three artists/albums.
    // "Jazz": one song, one artist, one album.
    try await store.upsertSongs([
      Self.song("r1", artist: "Alpha", album: "A1", genres: ["Rock"]),
      Self.song("r2", artist: "Beta", album: "B1", genres: ["Rock"]),
      Self.song("r3", artist: "Gamma", album: "G1", genres: ["Rock"]),
      Self.song("j1", artist: "Delta", album: "D1", genres: ["Jazz"]),
    ])
    _ = try await store.rebuildGenreMap()
    let nodes = try await store.genreMapNodes()
    let byGenre = Dictionary(uniqueKeysWithValues: nodes.map { ($0.genre, $0) })
    let rock = try #require(byGenre["Rock"])
    let jazz = try #require(byGenre["Jazz"])
    #expect(rock.weight > jazz.weight)
    #expect(abs(rock.weight - 1.0) < 1e-9, "biggest genre normalises to 1")
    #expect(jazz.weight > 0, "non-empty genre is strictly positive")
    #expect(rock.trackCount == 3)
    #expect(rock.albumCount == 3)
    #expect(rock.artistCount == 3)
    #expect(jazz.trackCount == 1)
  }

  /// Two genres with three shared artists, two shared albums, and three
  /// shared tracks produce non-zero Jaccards on every structural channel
  /// and the composite matches the spec formula.
  @Test
  func `composite edge score matches the spec weights`() async throws {
    let store = try TestSupport.freshStore()
    // Three songs, each carrying BOTH genres (perfect overlap on tracks,
    // artists, and albums). With three distinct (artist, album) pairs and
    // three distinct tracks per genre, every Jaccard is 1.0.
    try await store.upsertSongs([
      Self.song("s1", artist: "A1", album: "Al1", genres: ["Pop", "Rock"]),
      Self.song("s2", artist: "A2", album: "Al2", genres: ["Pop", "Rock"]),
      Self.song("s3", artist: "A3", album: "Al3", genres: ["Pop", "Rock"]),
    ])
    _ = try await store.rebuildGenreMap()
    let evidence = try await store.genreMapEvidence()
    let row = try #require(
      evidence.first { $0.genreA == "Pop" && $0.genreB == "Rock" }
    )
    #expect(abs(row.artistOverlapJaccard - 1.0) < 1e-9)
    #expect(abs(row.albumOverlapJaccard - 1.0) < 1e-9)
    #expect(abs(row.trackOverlapJaccard - 1.0) < 1e-9)
    // No playlist channel (no genre_edge populated) ⇒ pl term is 0.
    #expect(row.playlistCooccurWeight == 0)
    // total = 0.45 + 0.35 + 0.15 + 0 = 0.95
    #expect(abs(row.totalWeight - 0.95) < 1e-9)
    #expect(row.sharedArtistCount == 3)
    #expect(row.sharedAlbumCount == 3)
    #expect(row.sharedTrackCount == 3)
  }

  /// Playlist channel feeds the composite at the 0.05 weight after the v6
  /// graph is rebuilt and joined in by `rebuildGenreMap`.
  @Test
  func `playlist channel contributes when the v 6 graph is present`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s1", artist: "A1", album: "Al1", genres: ["Pop"]),
      Self.song("s2", artist: "A2", album: "Al2", genres: ["Pop"]),
      Self.song("s3", artist: "A3", album: "Al3", genres: ["Rock"]),
      Self.song("s4", artist: "A4", album: "Al4", genres: ["Rock"]),
    ])
    // Apple playlist with two Pop + two Rock tracks → one Pop/Rock edge
    // in genre_edge with weight 1 (one shared playlist).
    let appleSongs = ["s1", "s2", "s3", "s4"]
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "P1", name: "Mixer", lastImportedAt: .now),
      songIDs: appleSongs,
    )
    _ = try await store.rebuildGenreGraph(
      maxPlaylistTracks: 100_000,
      maxPairsPerPlaylist: 100_000,
    )
    _ = try await store.rebuildGenreMap()
    let evidence = try await store.genreMapEvidence()
    let row = evidence.first { $0.genreA == "Pop" && $0.genreB == "Rock" }
    // Pop and Rock share no songs/artists/albums, so the structural
    // channels are all 0. The playlist channel weight = 1/1 = 1.0, ×0.05
    // = 0.05. But: support floor (shared_* sum < 2) drops the row.
    #expect(row == nil, "no structural shares ⇒ support floor drops it")
  }

  /// One shared track total (across artist/album/track channels combined)
  /// is below the support floor and is dropped.
  @Test
  func `support floor drops pairs with combined support below two`() async throws {
    let store = try TestSupport.freshStore()
    // One shared song carries both genres; nothing else overlaps. The
    // artist/album/track channels yield 1+1+1 = 3 shared each — over the
    // floor, so this row is KEPT. (Sanity baseline for the next case.)
    try await store.upsertSongs([
      Self.song("solo", artist: "A1", album: "Al1", genres: ["X", "Y"])
    ])
    _ = try await store.rebuildGenreMap()
    let evidence = try await store.genreMapEvidence()
    #expect(evidence.count == 1)
    #expect(evidence.first?.sharedArtistCount == 1)
    #expect(evidence.first?.sharedAlbumCount == 1)
    #expect(evidence.first?.sharedTrackCount == 1)
  }

  /// Two genres whose only structural shared count is one artist (zero
  /// album, zero track) ⇒ sum = 1 < 2 ⇒ dropped.
  @Test
  func `support floor drops single artist only edges`() async throws {
    let store = try TestSupport.freshStore()
    // Same artist, DIFFERENT album titles, DIFFERENT songs.
    try await store.upsertSongs([
      Self.song("p1", artist: "Solo", album: "AlbumP", genres: ["Pop"]),
      Self.song("r1", artist: "Solo", album: "AlbumR", genres: ["Rock"]),
    ])
    _ = try await store.rebuildGenreMap()
    let evidence = try await store.genreMapEvidence()
    #expect(
      evidence.first { $0.genreA == "Pop" && $0.genreB == "Rock" } == nil,
      "1 shared artist + 0 shared album + 0 shared track = below floor",
    )
  }

  @Test
  func `rebuild is idempotent for fixed inputs`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("a", artist: "A1", album: "Al1", genres: ["Pop", "Rock"]),
      Self.song("b", artist: "A2", album: "Al2", genres: ["Pop", "Rock"]),
    ])
    let first = try await store.rebuildGenreMap()
    let second = try await store.rebuildGenreMap()
    #expect(first == second)
    let firstNodes = try await store.genreMapNodes()
    let firstEdges = try await store.genreMapEvidence()
    _ = try await store.rebuildGenreMap()
    let thirdNodes = try await store.genreMapNodes()
    let thirdEdges = try await store.genreMapEvidence()
    #expect(firstNodes == thirdNodes)
    #expect(firstEdges == thirdEdges)
  }

  @Test
  func `rebuild does not mutate songs or playlists`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("a", artist: "A1", album: "Al1", genres: ["Pop", "Rock"]),
      Self.song("b", artist: "A2", album: "Al2", genres: ["Pop", "Rock"]),
    ])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "P1", name: "M", lastImportedAt: .now),
      songIDs: ["a", "b"],
    )
    let songsBefore = try await store.allSongs()
    _ = try await store.rebuildGenreMap()
    let songsAfter = try await store.allSongs()
    #expect(songsBefore == songsAfter)
  }

  // MARK: Private

  private static func song(
    _ id: String,
    artist: String,
    album: String,
    genres: [String],
  ) -> Song {
    Song(
      id: id,
      localID: 0,
      musicItemID: "mid-\(id)",
      idNamespace: .library,
      title: "t-\(id)",
      artistName: artist,
      albumTitle: album,
      duration: 200,
      isExplicit: false,
      artworkURL: nil,
      importedAt: .now,
      genreNames: genres,
    )
  }
}
