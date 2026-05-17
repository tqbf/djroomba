import Foundation
import Testing
@testable import DJRoomba

/// v4 "free" Apple-library metadata: `upsertSongs` round-trips all nine new
/// fields (incl. a multi-element `genreNames` — the gate for the genre-JSON
/// mechanism), a sparse song reads back nil/`[]`, a re-import refreshes the
/// new columns while keeping `id`/`localID` stable, and the wider 19-column
/// row still chunks correctly past the per-statement bound-variable cap.
struct SongMetadataTests {

  @Test
  func `upsert round trips all free metadata including multi element genres`() async throws {
    let store = try TestSupport.freshStore()

    let release = Date(timeIntervalSince1970: 1_500_000_000)
    let full = Song(
      id: "song-full",
      musicItemID: "m-full",
      idNamespace: .library,
      title: "Symphony No. 9",
      artistName: "Beethoven",
      albumTitle: "Complete Symphonies",
      duration: 4_212,
      isExplicit: false,
      artworkURL: nil,
      importedAt: Date(timeIntervalSince1970: 1),
      trackNumber: 4,
      discNumber: 2,
      genreNames: ["Classical", "Romantic", "Orchestral"],
      releaseDate: release,
      composerName: "Ludwig van Beethoven",
      isrc: "USABC1234567",
      hasLyrics: true,
      workName: "Symphony No. 9 in D minor, Op. 125",
      movementName: "IV. Presto",
    )
    try await store.upsertSongs([full])

    let stored = try #require(try await store.song(id: "song-full"))
    #expect(stored.trackNumber == 4)
    #expect(stored.discNumber == 2)
    // The multi-element list survives the genre-JSON round trip in order.
    #expect(stored.genreNames == ["Classical", "Romantic", "Orchestral"])
    #expect(TestSupport.datesMatch(stored.releaseDate, release))
    #expect(stored.composerName == "Ludwig van Beethoven")
    #expect(stored.isrc == "USABC1234567")
    #expect(stored.hasLyrics == true)
    #expect(stored.workName == "Symphony No. 9 in D minor, Op. 125")
    #expect(stored.movementName == "IV. Presto")
  }

  @Test
  func `the same fields round trip on the row decode path`() async throws {
    // `songsWithStats` decodes via `try Song(row:)` (not GRDB Codable), so
    // exercise that second path explicitly — the genre-JSON mechanism must
    // be correct on BOTH decoders.
    let store = try TestSupport.freshStore()
    let song = Song(
      id: "s1",
      musicItemID: "m1",
      idNamespace: .library,
      title: "T",
      artistName: "A",
      isExplicit: false,
      importedAt: Date(timeIntervalSince1970: 2),
      trackNumber: 7,
      genreNames: ["Jazz", "Bebop"],
      isrc: "QQ1112223334",
      hasLyrics: false,
    )
    try await store.upsertSongs([song])
    let pl = try await store.createAppPlaylist(named: "Mix")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["s1"])

    let viaRow = try await store.songsWithStats(inAppPlaylist: pl.id)
    let one = try #require(viaRow.first?.song)
    #expect(one.trackNumber == 7)
    #expect(one.genreNames == ["Jazz", "Bebop"])
    #expect(one.isrc == "QQ1112223334")
    #expect(one.hasLyrics == false)
  }

  @Test
  func `a sparse song reads back nil and empty genres`() async throws {
    let store = try TestSupport.freshStore()
    // All v4 fields defaulted (nil / []), like a macOS library Song that
    // populated none of them — that's expected and harmless.
    let sparse = TestSupport.sampleSong(musicItemID: "sparse")
    try await store.upsertSongs([sparse])

    let stored = try #require(try await store.song(id: sparse.id))
    #expect(stored.trackNumber == nil)
    #expect(stored.discNumber == nil)
    #expect(stored.genreNames == [], "empty list stored NULL, decodes []")
    #expect(stored.releaseDate == nil)
    #expect(stored.composerName == nil)
    #expect(stored.isrc == nil)
    #expect(stored.hasLyrics == nil)
    #expect(stored.workName == nil)
    #expect(stored.movementName == nil)
  }

  @Test
  func `reimport refreshes metadata but keeps id and local id stable`() async throws {
    let store = try TestSupport.freshStore()

    let first = Song(
      id: "stable-uuid",
      musicItemID: "m.same",
      idNamespace: .library,
      title: "Original",
      artistName: "Artist",
      isExplicit: false,
      importedAt: Date(timeIntervalSince1970: 10),
      trackNumber: 1,
      genreNames: ["Pop"],
      composerName: "Old Composer",
      hasLyrics: false,
    )
    try await store.upsertSongs([first])
    let originalLocalID = try #require(try await store.song(id: "stable-uuid")).localID

    // Same import key, different app id, changed metadata — a re-import.
    let second = Song(
      id: "DIFFERENT-uuid",
      musicItemID: "m.same",
      idNamespace: .library,
      title: "Renamed",
      artistName: "Artist",
      isExplicit: false,
      importedAt: Date(timeIntervalSince1970: 20),
      trackNumber: 9,
      discNumber: 3,
      genreNames: ["Rock", "Indie"],
      composerName: "New Composer",
      isrc: "NEWISRC00001",
      hasLyrics: true,
    )
    try await store.upsertSongs([second])

    #expect(try await store.songCount() == 1)
    let resolved = try #require(
      try await store.song(musicItemID: "m.same", namespace: .library)
    )
    // Stable id + canonical local_id unchanged across re-import.
    #expect(resolved.id == "stable-uuid")
    #expect(resolved.localID == originalLocalID)
    // Mutable metadata refreshed (DO UPDATE SET …).
    #expect(resolved.title == "Renamed")
    #expect(resolved.trackNumber == 9)
    #expect(resolved.discNumber == 3)
    #expect(resolved.genreNames == ["Rock", "Indie"])
    #expect(resolved.composerName == "New Composer")
    #expect(resolved.isrc == "NEWISRC00001")
    #expect(resolved.hasLyrics == true)
  }

  /// A batch larger than one chunk (52 rows/chunk at 19 cols, ~988 bound
  /// vars < 999) must still round-trip every row's metadata, in order.
  @Test
  func `chunk boundary still holds with the wider metadata row`() async throws {
    let store = try TestSupport.freshStore()
    // 130 rows ⇒ at least three chunks (52 + 52 + 26).
    let count = 130
    let songs = (0..<count).map { i in
      Song(
        id: "id\(i)",
        musicItemID: "m\(i)",
        idNamespace: .library,
        title: "Track \(i)",
        artistName: "Artist",
        isExplicit: false,
        importedAt: Date(timeIntervalSince1970: Double(1_000 + i)),
        trackNumber: i,
        discNumber: i % 3,
        genreNames: ["G\(i)", "Shared"],
        composerName: "Composer \(i)",
        isrc: "ISRC\(String(format: "%08d", i))",
        hasLyrics: i % 2 == 0,
      )
    }
    try await store.upsertSongs(songs)

    #expect(try await store.songCount() == count)
    for i in 0..<count {
      let stored = try #require(try await store.song(id: "id\(i)"))
      #expect(stored.trackNumber == i)
      #expect(stored.discNumber == i % 3)
      #expect(stored.genreNames == ["G\(i)", "Shared"])
      #expect(stored.composerName == "Composer \(i)")
      #expect(stored.isrc == "ISRC\(String(format: "%08d", i))")
      #expect(stored.hasLyrics == (i % 2 == 0))
    }
  }
}
