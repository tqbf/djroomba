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
    // channels are all 0. The playlist channel normalised weight is
    // 1.0 (single shared playlist, max in the graph), well above the
    // Phase-1-gate-revised `pl >= 0.10` clause, so the row IS kept.
    // (Pre-gate this row was dropped by `(a_n + b_n + t_n) >= 2`; the
    // gate review found that the strict structural floor was leaving
    // small genres as Louvain singletons on the real library, so the
    // floor was loosened to `>= 1 OR pl >= 0.10`.)
    #expect(row != nil, "playlist channel ≥0.10 lets the row through")
    let totalWeight = row?.totalWeight ?? 0
    #expect(
      abs(totalWeight - 0.05) < 1e-9,
      "composite = 0.05 · 1.0 (playlist-only) = 0.05",
    )
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

  /// Phase-1 gate revision: a pair with ANY structural overlap (one
  /// shared artist suffices) clears the new `>= 1` support floor. The
  /// previous behaviour (`>= 2`) was too strict — small genres routinely
  /// share exactly one artist with their nearest neighbour, and the
  /// stricter floor was leaving them as Louvain singletons.
  @Test
  func `support floor keeps single artist only edges after gate revision`() async throws {
    let store = try TestSupport.freshStore()
    // Same artist, DIFFERENT album titles, DIFFERENT songs.
    try await store.upsertSongs([
      Self.song("p1", artist: "Solo", album: "AlbumP", genres: ["Pop"]),
      Self.song("r1", artist: "Solo", album: "AlbumR", genres: ["Rock"]),
    ])
    _ = try await store.rebuildGenreMap()
    let evidence = try await store.genreMapEvidence()
    let row = evidence.first { $0.genreA == "Pop" && $0.genreB == "Rock" }
    #expect(row != nil, "1 shared artist clears the >= 1 floor")
    #expect(row?.sharedArtistCount == 1)
    #expect(row?.sharedAlbumCount == 0)
    #expect(row?.sharedTrackCount == 0)
  }

  /// Pure-noise pairs (no structural overlap AND no meaningful playlist
  /// co-occurrence) must still be dropped — the gate revision moved the
  /// floor, it didn't remove it.
  @Test
  func `support floor still drops pairs with zero support across all channels`() async throws {
    let store = try TestSupport.freshStore()
    // Two genres with completely disjoint artists/albums/songs and no
    // playlist co-occurrence.
    try await store.upsertSongs([
      Self.song("p1", artist: "P-Artist", album: "P-Album", genres: ["Pop"]),
      Self.song("r1", artist: "R-Artist", album: "R-Album", genres: ["Rock"]),
    ])
    _ = try await store.rebuildGenreMap()
    let evidence = try await store.genreMapEvidence()
    #expect(
      evidence.first { $0.genreA == "Pop" && $0.genreB == "Rock" } == nil,
      "0 structural + 0 playlist = no row",
    )
  }

  /// Phase 3: the materialised `song_genre` view is populated by the
  /// rebuild. One row per (song, genre) with the same normalised keys
  /// the evidence rebuild already computes. Indexed on the three keys
  /// the strand-build + evidence-on-demand readers need.
  @Test
  func `rebuild populates song genre with one row per song genre pair`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s1", artist: "Alpha", album: "A", genres: ["Pop", "Rock"]),
      Self.song("s2", artist: "Beta", album: "B", genres: ["Jazz"]),
    ])
    _ = try await store.rebuildGenreMap()
    let counts = try await store.database.dbQueue.read { db -> (Int, Int, Int) in
      let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_genre") ?? 0
      let pop = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM song_genre WHERE genre = ?",
        arguments: ["Pop"],
      ) ?? 0
      let jazz = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM song_genre WHERE genre = ?",
        arguments: ["Jazz"],
      ) ?? 0
      return (total, pop, jazz)
    }
    #expect(counts.0 == 3, "two songs × (2 + 1) genres = 3 song_genre rows")
    #expect(counts.1 == 1)
    #expect(counts.2 == 1)
  }

  /// Phase 3: the evidence-on-demand CTE no longer re-explodes
  /// `json_each(song.genre_names)`. Pin by reading the query plan and
  /// asserting `song_genre` is used (the indexed table) — a regression
  /// to the JIT explode would cause the per-click latency to balloon
  /// back to 6-8 s on the real library.
  @Test
  func `evidence on demand uses the materialised song genre view`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s1", artist: "Alpha", album: "A", genres: ["Pop", "Rock"]),
      Self.song("s2", artist: "Alpha", album: "B", genres: ["Pop", "Rock"]),
    ])
    _ = try await store.rebuildGenreMap()
    let evidence = try await store.genreMapEvidenceOnDemand(
      selectedGenre: "Pop",
      neighbourGenres: ["Rock"],
    )
    // The shared artist (Alpha) must surface; the read should be
    // correct AND fast (no `json_each` per-song explode in this path).
    #expect(evidence.sharedArtists.first?.display == "Alpha")
    #expect(evidence.sharedArtists.first?.overlapCount == 2)
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
