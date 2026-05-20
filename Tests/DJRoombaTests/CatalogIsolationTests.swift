import Foundation
import Testing
@testable import DJRoomba

/// Phase 1 (`plans/catalog-playlists.md`): the **one-way isolation** invariant
/// between the catalog and library id spaces. The composite unique key
/// `(music_item_id, id_namespace)` is what gives us this guarantee
/// structurally; these tests pin that the invariant holds end-to-end against
/// a real `LibraryStore`.
///
/// What's checked:
///
/// - A catalog row survives a library-side `pruneApplePlaylists` /
///   `deleteApplePlaylists` pass untouched. The library-import end-of-run
///   converge can never accidentally take catalog rows with it.
/// - A catalog row and a library row with the SAME `music_item_id` coexist
///   as two distinct `song` rows with distinct stable `song.id`s. Re-importing
///   the library can't clobber the catalog row, and vice versa — they have
///   different unique keys.
/// - Re-ingesting the same catalog `Song` is idempotent: the stable
///   `song.id` is preserved across UPSERT and no duplicate row appears.
///
/// The mapping itself is exercised in `CatalogIngestMappingTests`; here we
/// build records via the same factor-for-testability entry point
/// (`CatalogIngestService.song(fromCatalogFields:…)`) and write them
/// through `upsertSongs` — the same write path `CatalogIngestService.ingest`
/// uses internally. No `MusicKit.Song` is needed (it's not constructible
/// in tests).
struct CatalogIsolationTests {

  @Test
  func `catalog song survives a library prune and delete pass untouched`() async throws {
    let store = try TestSupport.freshStore()

    // Land one catalog song.
    let catalogRecord = CatalogIngestService.song(
      fromCatalogFields: "1440650711",
      title: "Bohemian Rhapsody",
      artistName: "Queen",
      albumTitle: "A Night at the Opera",
      duration: 354,
      isExplicit: false,
      importedAt: .now,
      trackNumber: 11,
      discNumber: 1,
      genreNames: ["Rock"],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: true,
      workName: nil,
      movementName: nil,
    )
    try await store.upsertSongs([catalogRecord])

    // Land an unrelated library song + apple playlist snapshot so the
    // library-side converge has something real to operate on.
    let libraryRecord = TestSupport.sampleSong(
      id: "lib-song",
      musicItemID: "lib-mid",
      namespace: .library,
      title: "Library Song",
    )
    try await store.upsertSongs([libraryRecord])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(
        id: "vanishing-apple-playlist",
        name: "Goes Away",
        artworkURL: nil,
        curator: nil,
        lastImportedAt: .now,
      ),
      songIDs: ["lib-song"],
    )
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(
        id: "folder-id",
        name: "Folder Posing As Playlist",
        artworkURL: nil,
        curator: nil,
        lastImportedAt: .now,
      ),
      songIDs: [],
    )

    // The two library-side converge passes ImportService runs end-of-import.
    try await store.pruneApplePlaylists(keeping: []) // vanishing-apple-playlist drops
    try await store.deleteApplePlaylists(ids: ["folder-id"])

    // Catalog row still there, unchanged, with the same stable song.id.
    let resolved = try await store.song(
      musicItemID: "1440650711",
      namespace: .catalog,
    )
    let kept = try #require(resolved)
    #expect(kept.id == catalogRecord.id)
    #expect(kept.idNamespace == .catalog)
    #expect(kept.title == "Bohemian Rhapsody")
    // The library song row itself is also untouched (snapshot pruning is
    // already one-way isolated — `IncrementalImportTests` pins that).
    #expect(try await store.song(id: "lib-song") != nil)
  }

  @Test
  func `library and catalog rows with the same music item id coexist as distinct rows`() async throws {
    let store = try TestSupport.freshStore()

    // Catalog row first.
    let catalogRecord = CatalogIngestService.song(
      fromCatalogFields: "shared-id",
      title: "Catalog Title",
      artistName: "Same Artist",
      albumTitle: nil,
      duration: nil,
      isExplicit: false,
      importedAt: .now,
      trackNumber: nil,
      discNumber: nil,
      genreNames: [],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    try await store.upsertSongs([catalogRecord])

    // Now a library row with the SAME music_item_id — the colliding case
    // the namespace was designed to keep disjoint.
    let libraryRecord = TestSupport.sampleSong(
      id: "library-stable",
      musicItemID: "shared-id",
      namespace: .library,
      title: "Library Title",
    )
    try await store.upsertSongs([libraryRecord])

    // Both rows exist, addressable by namespace.
    #expect(try await store.songCount() == 2)
    let catalogResolved = try #require(
      try await store.song(musicItemID: "shared-id", namespace: .catalog)
    )
    let libraryResolved = try #require(
      try await store.song(musicItemID: "shared-id", namespace: .library)
    )
    // The catalog row's stable id is unchanged by the colliding library
    // upsert — different unique key, no DO UPDATE.
    #expect(catalogResolved.id == catalogRecord.id)
    #expect(catalogResolved.title == "Catalog Title")
    #expect(catalogResolved.idNamespace == .catalog)
    // The library row is its own row with its own stable id.
    #expect(libraryResolved.id == "library-stable")
    #expect(libraryResolved.title == "Library Title")
    #expect(libraryResolved.idNamespace == .library)
    // The two stable ids must differ — they're FK targets for downstream
    // app-playlist / play-history rows.
    #expect(catalogResolved.id != libraryResolved.id)
  }

  /// **Phase 3 (catalog-playlists).** Play recording is namespace-agnostic:
  /// `LibraryStore.recordPlay(songID:)` takes our app-stable `song.id`
  /// (UUID), looks up `local_id`, and appends a `PlayHistoryEntry` keyed by
  /// `song_local_id`. Nothing on that path reads `id_namespace`, so a
  /// catalog song records exactly like a library song — no Phase-3 code
  /// change is required for stats. This test pins the invariant: ingest a
  /// catalog song, call `recordPlay`, and confirm `song_stat.play_count`
  /// advances, `last_played_at` is set, AND the history row's
  /// `song_local_id` resolves back to the catalog row (the FK target is
  /// correct; play_history doesn't accidentally point at a library row).
  @Test
  func `recordPlay for a catalog song lands on the catalog row by local_id`() async throws {
    let store = try TestSupport.freshStore()

    // Land a catalog song through the same factory the live ingest uses.
    let catalogRecord = CatalogIngestService.song(
      fromCatalogFields: "1440650711",
      title: "Bohemian Rhapsody",
      artistName: "Queen",
      albumTitle: "A Night at the Opera",
      duration: 354,
      isExplicit: false,
      importedAt: .now,
      trackNumber: 11,
      discNumber: 1,
      genreNames: ["Rock"],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: true,
      workName: nil,
      movementName: nil,
    )
    try await store.upsertSongs([catalogRecord])

    // Also land a library row with a colliding music_item_id, to prove
    // that recordPlay attributes by our song.id (UUID), not by Apple id.
    // If the path leaked id_namespace anywhere, this is the case it'd
    // mis-route on.
    let librayCollision = TestSupport.sampleSong(
      id: "library-shared-id",
      musicItemID: "1440650711",
      namespace: .library,
      title: "Library Bohemian Rhapsody",
    )
    try await store.upsertSongs([librayCollision])

    // Record a play against the CATALOG row's stable song.id.
    try await store.recordPlay(
      songID: catalogRecord.id,
      at: Date(timeIntervalSince1970: 100),
    )

    // The catalog row's stat advances.
    let catalogStat = try #require(try await store.songStat(songID: catalogRecord.id))
    #expect(catalogStat.playCount == 1)
    #expect(catalogStat.lastPlayedAt == Date(timeIntervalSince1970: 100))

    // The colliding library row's stat is UNTOUCHED — proving the play
    // was attributed by our PK (song.id), not by Apple id.
    let libraryStat = try await store.songStat(songID: "library-shared-id")
    #expect(libraryStat == nil, "library collider got no stat (record went to catalog by song.id)")

    // The play_history row points at the catalog row by local_id. Pull
    // the bounded history (newest-first) and confirm exactly one entry,
    // whose song_local_id matches the catalog row.
    let history = try await store.recentlyPlayedSongLocalIDs()
    #expect(history.count == 1)
    let catalogStored = try #require(try await store.song(id: catalogRecord.id))
    #expect(
      history.first == catalogStored.localID,
      "play_history row resolves back to the catalog song by local_id (namespace-agnostic FK)",
    )
  }

  @Test
  func `re ingesting the same catalog song is idempotent`() async throws {
    let store = try TestSupport.freshStore()

    let first = CatalogIngestService.song(
      fromCatalogFields: "catalog-1",
      title: "Original",
      artistName: "Artist",
      albumTitle: "Album",
      duration: 200,
      isExplicit: false,
      importedAt: .now,
      trackNumber: 3,
      discNumber: 1,
      genreNames: ["Rock"],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    try await store.upsertSongs([first])

    // Same catalog id, different metadata + a fresh would-be UUID — the
    // mapping mints a new one every call (see `each call mints a fresh
    // stable song id`). The UPSERT preserves the existing stable id and
    // refreshes mutable metadata.
    let second = CatalogIngestService.song(
      fromCatalogFields: "catalog-1",
      title: "Renamed",
      artistName: "Artist",
      albumTitle: "Album (Remaster)",
      duration: 200,
      isExplicit: false,
      importedAt: .now,
      trackNumber: 3,
      discNumber: 1,
      genreNames: ["Rock", "Classic Rock"],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    #expect(second.id != first.id) // freshly minted UUID at the mapping layer
    try await store.upsertSongs([second])

    // Still one row, with the *first* stable id.
    #expect(try await store.songCount() == 1)
    let resolved = try #require(
      try await store.song(musicItemID: "catalog-1", namespace: .catalog)
    )
    #expect(resolved.id == first.id)
    #expect(resolved.title == "Renamed")
    #expect(resolved.albumTitle == "Album (Remaster)")
    #expect(resolved.genreNames == ["Rock", "Classic Rock"])
    #expect(resolved.idNamespace == .catalog)
  }
}
