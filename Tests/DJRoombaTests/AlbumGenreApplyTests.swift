import Foundation
import Testing
@testable import DJRoomba

/// `LibraryStore.applyAlbumGenres` — the batched album→track genre write
/// (the `GenreImportService` SQLite side). Pins: it sets `genre_names` on
/// the matching library rows via the chunked `CASE`-driven UPDATE, is
/// correct across a chunk boundary regardless of map order, touches ONLY
/// `.library` rows / ONLY the `genre_names` column, leaves ids not in the
/// map alone, is one-way isolated from app/stat/history/apple-snapshot
/// data, JSON-round-trips a multi-element genre, and is idempotent.
///
/// The MusicKit fetch in `GenreImportService.importAlbumGenres` itself
/// stays signed-gated and is NOT unit-tested: a MusicKit `Album`/`Track`
/// cannot be constructed in a unit test (exactly like
/// `ImportService.song(from:)` / `fetchTracks` today). The shared
/// `ImportService.underlyingItemID(of:)` unwrap is likewise not
/// unit-testable (a `Track` isn't constructible) — same precedent; it is
/// not faked here. These tests cover the deterministic store half, which
/// is where the batch correctness lives.
struct AlbumGenreApplyTests {
  @Test
  func `applies genres keyed by music item id across multiple rows`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "s1", musicItemID: "m1", namespace: .library),
      TestSupport.sampleSong(id: "s2", musicItemID: "m2", namespace: .library),
      TestSupport.sampleSong(id: "s3", musicItemID: "m3", namespace: .library),
    ])

    let updated = try await store.applyAlbumGenres([
      "m1": ["Alt/Goth/Industrial"],
      "m2": ["Pop", "Rock"],
      "m3": ["Jazz"],
    ])
    #expect(updated == 3)

    #expect(try await store.song(id: "s1")?.genreNames == ["Alt/Goth/Industrial"])
    #expect(try await store.song(id: "s2")?.genreNames == ["Pop", "Rock"])
    #expect(try await store.song(id: "s3")?.genreNames == ["Jazz"])
  }

  /// A multi-element list with a slash-bearing tag is exactly the real
  /// probe shape; it must JSON-round-trip in order on both decode paths
  /// (Codable `song(id:)` here; the row-decode path is covered by
  /// `SongMetadataTests`, same `genre_names` mechanism).
  @Test
  func `json round trips a multi element genre with slashes`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "s", musicItemID: "m", namespace: .library)
    ])
    try await store.applyAlbumGenres(["m": ["Alt/Goth/Industrial", "Pop/Rock/60s-70s/Classic"]])
    #expect(
      try await store.song(id: "s")?.genreNames
        == ["Alt/Goth/Industrial", "Pop/Rock/60s-70s/Classic"]
    )
  }

  /// A map larger than one chunk (`999/3 = 333` entries/chunk) must tag
  /// every row correctly regardless of dictionary iteration order — the
  /// `CASE music_item_id WHEN … END` batch must not depend on order.
  @Test
  func `chunk boundary correctness for a large unordered map`() async throws {
    let store = try TestSupport.freshStore()
    let count = 700 // > 2 chunks at 333/chunk
    let songs = (0..<count).map { i in
      TestSupport.sampleSong(id: "id\(i)", musicItemID: "m\(i)", namespace: .library)
    }
    try await store.upsertSongs(songs)

    var map = [String: [String]]()
    for i in 0..<count { map["m\(i)"] = ["G\(i)", "Shared"] }
    let updated = try await store.applyAlbumGenres(map)
    #expect(updated == count)

    for i in 0..<count {
      #expect(try await store.song(id: "id\(i)")?.genreNames == ["G\(i)", "Shared"])
    }
  }

  /// Provenance: only `.library` rows are touched. A `.catalog` row that
  /// happens to share a `music_item_id` must be left exactly as it was.
  @Test
  func `only library namespace rows are updated`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "lib", musicItemID: "shared", namespace: .library),
      TestSupport.sampleSong(id: "cat", musicItemID: "shared", namespace: .catalog),
    ])

    let updated = try await store.applyAlbumGenres(["shared": ["Electronic"]])
    #expect(updated == 1, "only the .library row matched")

    #expect(try await store.song(id: "lib")?.genreNames == ["Electronic"])
    #expect(
      try await store.song(id: "cat")?.genreNames == [],
      "the catalog row with the same music_item_id is untouched",
    )
  }

  @Test
  func `ids not in the map are left untouched`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "tagged", musicItemID: "in", namespace: .library),
      TestSupport.sampleSong(id: "kept", musicItemID: "out", namespace: .library),
    ])
    // Seed a pre-existing genre on the row that's NOT in the map.
    try await store.applyAlbumGenres(["out": ["PreExisting"]])

    let updated = try await store.applyAlbumGenres(["in": ["New"]])
    #expect(updated == 1)
    #expect(try await store.song(id: "tagged")?.genreNames == ["New"])
    #expect(
      try await store.song(id: "kept")?.genreNames == ["PreExisting"],
      "a row absent from the map keeps its prior genre",
    )
  }

  /// Applying the same map twice yields the same result (the UPDATE is a
  /// pure overwrite of one column; no insert, no accumulation).
  @Test
  func `apply is idempotent`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "s", musicItemID: "m", namespace: .library)
    ])
    let map = ["m": ["Classical", "Romantic"]]
    try await store.applyAlbumGenres(map)
    try await store.applyAlbumGenres(map)
    #expect(try await store.song(id: "s")?.genreNames == ["Classical", "Romantic"])
    #expect(try await store.songCount() == 1, "no rows inserted by the second apply")
  }

  @Test
  func `empty map is a no op`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "s", musicItemID: "m", namespace: .library)
    ])
    let updated = try await store.applyAlbumGenres([:])
    #expect(updated == 0)
    #expect(try await store.song(id: "s")?.genreNames == [])
  }

  /// One-way isolation, mirroring the existing
  /// `pruneApplePlaylists` / snapshot-replace isolation tests: the genre
  /// write touches ONLY `song.genre_names` — never any other `song`
  /// column, and never `app_playlist*`, `song_stat`, `play_history`,
  /// `apple_playlist*`, favorites or recents.
  @Test
  func `genre write is one way isolated and touches only genre names`() async throws {
    let store = try TestSupport.freshStore()

    // A song with full metadata so we can prove NO other column moves.
    let release = Date(timeIntervalSince1970: 1_500_000_000)
    try await store.upsertSongs([
      Song(
        id: "song",
        musicItemID: "mm",
        idNamespace: .library,
        title: "Original",
        artistName: "Artist",
        albumTitle: "An Album",
        duration: 321,
        isExplicit: true,
        importedAt: Date(timeIntervalSince1970: 1),
        trackNumber: 5,
        discNumber: 2,
        genreNames: [],
        releaseDate: release,
        composerName: "A Composer",
        isrc: "ISRC00000001",
        hasLyrics: true,
        workName: "A Work",
        movementName: "A Movement",
      )
    ])
    let before = try #require(try await store.song(id: "song"))

    // App-owned + apple-snapshot + stat/history state alongside it.
    let mine = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(mine.id, songIDs: ["song"])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "A", name: "A", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["song"],
    )
    try await store.setFavorite(true, playlistID: "A", source: .apple)
    try await store.recordRecent(playlistID: "A", source: .apple)
    try await store.recordPlay(songID: "song")

    try await store.applyAlbumGenres(["mm": ["Shoegaze"]])

    // genre_names changed; EVERY other song column is byte-identical.
    let after = try #require(try await store.song(id: "song"))
    #expect(after.genreNames == ["Shoegaze"])
    #expect(after.id == before.id)
    #expect(after.localID == before.localID)
    #expect(after.musicItemID == before.musicItemID)
    #expect(after.idNamespace == before.idNamespace)
    #expect(after.title == before.title)
    #expect(after.artistName == before.artistName)
    #expect(after.albumTitle == before.albumTitle)
    #expect(after.duration == before.duration)
    #expect(after.isExplicit == before.isExplicit)
    #expect(TestSupport.datesMatch(after.importedAt, before.importedAt))
    #expect(after.trackNumber == before.trackNumber)
    #expect(after.discNumber == before.discNumber)
    #expect(TestSupport.datesMatch(after.releaseDate, before.releaseDate))
    #expect(after.composerName == before.composerName)
    #expect(after.isrc == before.isrc)
    #expect(after.hasLyrics == before.hasLyrics)
    #expect(after.workName == before.workName)
    #expect(after.movementName == before.movementName)

    // One-way isolation: nothing app-owned / stat / history / snapshot
    // was touched.
    #expect(try await store.songs(inAppPlaylist: mine.id).map(\.id) == ["song"])
    #expect(try await store.songs(inApplePlaylist: "A").map(\.id) == ["song"])
    #expect(try await store.favorites().count == 1)
    #expect(try await store.recentPlaylists().count == 1)
    #expect(try await store.songStat(songID: "song")?.playCount == 1)
    #expect(try await store.recentlyPlayedSongIDs() == ["song"])
    #expect(try await store.songCount() == 1)
  }
}
