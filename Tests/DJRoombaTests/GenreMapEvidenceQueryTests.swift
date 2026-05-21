import Foundation
import Testing
@testable import DJRoomba

/// Phase 5 (`plans/genre-metro-map.md`) evidence-on-demand reads on
/// the `song_genre` materialised view. Hits the indexed
/// `(genre, song_id)`, `(genre, artist_key)`, `(genre, album_key)`
/// paths the plan calls out as the right shape.
///
/// Each test seeds a small in-memory store, runs `rebuildGenreMap` to
/// materialise `song_genre`, then probes the Phase-5 queries.
struct GenreMapEvidenceQueryTests {

  // MARK: Internal

  /// `genreMapTopArtists` returns rows sorted by song count desc.
  @Test
  func `topArtists returns rows sorted by song count desc`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r1", artist: "Pixies", album: "Doolittle", genres: ["Alternative"]),
      Self.song("r2", artist: "Pixies", album: "Surfer", genres: ["Alternative"]),
      Self.song("r3", artist: "Pavement", album: "Slanted", genres: ["Alternative"]),
    ])
    _ = try await store.rebuildGenreMap()
    let artists = try await store.genreMapTopArtists(for: "Alternative", limit: 10)
    #expect(artists.count == 2)
    #expect(artists[0].display == "Pixies")
    #expect(artists[0].overlapCount == 2)
    #expect(artists[1].display == "Pavement")
    #expect(artists[1].overlapCount == 1)
  }

  /// `genreMapTopArtists` paginates with `offset`.
  @Test
  func `topArtists paginates with offset`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("a1", artist: "A", album: "A1", genres: ["Folk"]),
      Self.song("a2", artist: "A", album: "A2", genres: ["Folk"]),
      Self.song("b1", artist: "B", album: "B1", genres: ["Folk"]),
      Self.song("c1", artist: "C", album: "C1", genres: ["Folk"]),
    ])
    _ = try await store.rebuildGenreMap()
    let page1 = try await store.genreMapTopArtists(for: "Folk", limit: 2)
    let page2 = try await store.genreMapTopArtists(for: "Folk", limit: 2, offset: 2)
    #expect(page1.count == 2)
    #expect(page2.count == 1)
    let combinedNames = (page1 + page2).map(\.display)
    #expect(Set(combinedNames) == Set(["A", "B", "C"]))
  }

  /// `genreMapTopAlbums` keys on `album_key` and renders artist+album.
  @Test
  func `topAlbums keys on album_key and renders artist plus album`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s1", artist: "Beck", album: "Odelay", genres: ["Alt"]),
      Self.song("s2", artist: "Beck", album: "Odelay", genres: ["Alt"]),
      Self.song("s3", artist: "Beck", album: "Sea Change", genres: ["Alt"]),
    ])
    _ = try await store.rebuildGenreMap()
    let albums = try await store.genreMapTopAlbums(for: "Alt", limit: 10)
    #expect(albums.count == 2)
    #expect(albums[0].display.contains("Odelay"))
    #expect(albums[0].overlapCount == 2)
  }

  /// `genreMapSharedArtists` returns artists present under BOTH genres.
  @Test
  func `sharedArtists returns artists under both genres`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      // Both genres → counts as shared.
      Self.song("s1", artist: "Radiohead", album: "OK", genres: ["Alt", "Rock"]),
      Self.song("s2", artist: "Radiohead", album: "Kid A", genres: ["Alt", "Electronic"]),
      // Only Alt.
      Self.song("s3", artist: "Pavement", album: "Slanted", genres: ["Alt"]),
      // Only Rock.
      Self.song("s4", artist: "Queens", album: "Songs", genres: ["Rock"]),
    ])
    _ = try await store.rebuildGenreMap()
    let shared = try await store.genreMapSharedArtists(
      between: "Alt",
      and: "Rock",
      limit: 10,
    )
    #expect(shared.count == 1)
    #expect(shared[0].display == "Radiohead")
  }

  /// `genreMapSharedAlbums` joins on `album_key`. A track must carry
  /// both genres for the album to count as shared.
  @Test
  func `sharedAlbums joins on album_key`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s1", artist: "Beck", album: "Odelay", genres: ["Alt", "Rock"]),
      Self.song("s2", artist: "Beck", album: "Odelay", genres: ["Alt", "Rock"]),
      Self.song("s3", artist: "Beck", album: "Sea Change", genres: ["Alt"]),
    ])
    _ = try await store.rebuildGenreMap()
    let albums = try await store.genreMapSharedAlbums(
      between: "Alt",
      and: "Rock",
      limit: 10,
    )
    #expect(albums.count == 1)
    #expect(albums[0].display.contains("Odelay"))
  }

  /// `genreMapSharedTracks` joins on `song_id`.
  @Test
  func `sharedTracks joins on song_id`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s1", artist: "Beck", album: "Odelay", genres: ["Alt", "Rock"]),
      Self.song("s2", artist: "Beck", album: "Odelay", genres: ["Alt"]),
      Self.song("s3", artist: "Beck", album: "Odelay", genres: ["Rock"]),
    ])
    _ = try await store.rebuildGenreMap()
    let tracks = try await store.genreMapSharedTracks(
      between: "Alt",
      and: "Rock",
      limit: 10,
    )
    #expect(tracks.count == 1)
    #expect(tracks[0].display.contains("Beck"))
  }

  /// Pagination on `sharedArtists` returns disjoint pages.
  @Test
  func `sharedArtists paginates`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("s1", artist: "A", album: "A1", genres: ["X", "Y"]),
      Self.song("s2", artist: "B", album: "B1", genres: ["X", "Y"]),
      Self.song("s3", artist: "C", album: "C1", genres: ["X", "Y"]),
    ])
    _ = try await store.rebuildGenreMap()
    let page1 = try await store.genreMapSharedArtists(
      between: "X",
      and: "Y",
      limit: 2,
    )
    let page2 = try await store.genreMapSharedArtists(
      between: "X",
      and: "Y",
      limit: 2,
      offset: 2,
    )
    #expect(page1.count == 2)
    #expect(page2.count == 1)
    let names = Set((page1 + page2).map(\.display))
    #expect(names == ["A", "B", "C"])
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
