import Foundation
import Testing
@testable import DJRoomba

/// Phase 4 app-playlist CRUD over `LibraryStore`. Covers create / rename /
/// delete / add / remove / reorder-tracks / reorder-playlists, the batch
/// idioms (chunk-boundary correctness), the cascade on delete, and the
/// **one-way isolation** invariant: every app-playlist edit must leave the
/// imported `apple_playlist*` snapshot (and song/stat/history) untouched.
struct AppPlaylistCRUDTests {

  // MARK: Internal

  @Test
  func `create appends at end of sort order`() async throws {
    let store = try TestSupport.freshStore()
    let a = try await store.createAppPlaylist(named: "Alpha")
    let b = try await store.createAppPlaylist(named: "Beta")
    let c = try await store.createAppPlaylist(named: "Gamma")

    let ordered = try await store.appPlaylists()
    #expect(ordered.map(\.name) == ["Alpha", "Beta", "Gamma"])
    #expect(a.sortIndex < b.sortIndex)
    #expect(b.sortIndex < c.sortIndex)
    // Distinct ids minted.
    #expect(Set([a.id, b.id, c.id]).count == 3)
  }

  @Test
  func `rename updates name and stamps updated at`() async throws {
    let store = try TestSupport.freshStore()
    let created = try await store.createAppPlaylist(
      named: "Old",
      at: Date(timeIntervalSince1970: 1_000),
    )
    try await store.renameAppPlaylist(
      created.id,
      to: "New",
      at: Date(timeIntervalSince1970: 5_000),
    )
    let reloaded = try await store.appPlaylists().first { $0.id == created.id }
    #expect(reloaded?.name == "New")
    #expect(TestSupport.datesMatch(reloaded?.updatedAt, Date(timeIntervalSince1970: 5_000)))
    // created_at is not moved by a rename.
    #expect(TestSupport.datesMatch(reloaded?.createdAt, Date(timeIntervalSince1970: 1_000)))
  }

  @Test
  func `delete cascades membership but not songs or history`() async throws {
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["s1", "s2"])
    let pl = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["s1", "s2"])
    try await store.recordPlay(songID: "s1", at: .now)

    try await store.deleteAppPlaylist(pl.id)

    #expect(try await store.appPlaylists().isEmpty)
    #expect(try await store.songs(inAppPlaylist: pl.id).isEmpty)
    // Songs survive (delete-RESTRICT on song; membership cascaded away).
    #expect(try await store.songCount() == 2)
    // Play history survives (a song outlives playlist membership).
    #expect(try await store.songStat(songID: "s1")?.playCount == 1)
    #expect(try await store.recentlyPlayedSongIDs() == ["s1"])
  }

  @Test
  func `add appends and allows duplicates`() async throws {
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["a", "b", "c"])
    let pl = try await store.createAppPlaylist(named: "P")

    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["a", "b"])
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["c", "a"]) // 'a' again

    let ids = try await store.songs(inAppPlaylist: pl.id).map(\.id)
    #expect(ids == ["a", "b", "c", "a"], "append preserves order; a song may repeat")
  }

  @Test
  func `remove by position renumbers survivors`() async throws {
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["a", "b", "c", "d"])
    let pl = try await store.createAppPlaylist(named: "P")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["a", "b", "c", "d"])

    // Remove positions 1 and 3 (0-based) → drops 'b' and 'd'.
    try await store.removeTracksFromAppPlaylist(pl.id, positions: [1, 3])

    let ids = try await store.songs(inAppPlaylist: pl.id).map(\.id)
    #expect(ids == ["a", "c"])
    // Re-adding must work — proves positions were compacted (no PK
    // collision on the dense 0..<count range).
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["d"])
    #expect(try await store.songs(inAppPlaylist: pl.id).map(\.id) == ["a", "c", "d"])
  }

  @Test
  func `set tracks replaces whole ordered membership`() async throws {
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["a", "b", "c"])
    let pl = try await store.createAppPlaylist(named: "P")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["a", "b", "c"])

    // Reorder via full replace (the drag-to-reorder persist path).
    try await store.setAppPlaylistTracks(pl.id, songIDs: ["c", "a", "b"])
    #expect(try await store.songs(inAppPlaylist: pl.id).map(\.id) == ["c", "a", "b"])
  }

  @Test
  func `reorder app playlists persists new sidebar order`() async throws {
    let store = try TestSupport.freshStore()
    let a = try await store.createAppPlaylist(named: "A")
    let b = try await store.createAppPlaylist(named: "B")
    let c = try await store.createAppPlaylist(named: "C")

    try await store.reorderAppPlaylists([c.id, a.id, b.id])
    #expect(try await store.appPlaylists().map(\.name) == ["C", "A", "B"])

    // Idempotent / re-orderable again.
    try await store.reorderAppPlaylists([b.id, c.id, a.id])
    #expect(try await store.appPlaylists().map(\.name) == ["B", "C", "A"])
  }

  @Test
  func `add across chunk boundary keeps order`() async throws {
    // 800 songs in one add → exercises the chunked multi-row INSERT
    // (333 rows/chunk at 3 vars/row) across a boundary, in order.
    let store = try TestSupport.freshStore()
    let ids = (0..<800).map { "s\($0)" }
    try await seedSongs(store, ids)
    let pl = try await store.createAppPlaylist(named: "Big")

    try await store.addSongsToAppPlaylist(pl.id, songIDs: ids)
    #expect(try await store.songs(inAppPlaylist: pl.id).map(\.id) == ids)
  }

  @Test
  func `app edits never touch imported apple snapshot`() async throws {
    // The one-way-isolation invariant for Phase 4: nothing in app-playlist
    // CRUD may mutate `apple_playlist*` (or song/stat/history).
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["s1", "s2", "s3"])
    let apple = ApplePlaylist(
      id: "apple-1",
      name: "Imported",
      artworkURL: nil,
      curator: nil,
      lastImportedAt: .now,
    )
    try await store.replaceApplePlaylistSnapshot(apple, songIDs: ["s1", "s2"])
    try await store.recordPlay(songID: "s1", at: .now)

    // Exercise every app-playlist mutation.
    let pl = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["s1", "s3"])
    try await store.renameAppPlaylist(pl.id, to: "Renamed")
    try await store.removeTracksFromAppPlaylist(pl.id, positions: [0])
    try await store.setAppPlaylistTracks(pl.id, songIDs: ["s3", "s1"])
    let pl2 = try await store.createAppPlaylist(named: "Other")
    try await store.reorderAppPlaylists([pl2.id, pl.id])
    try await store.deleteAppPlaylist(pl2.id)

    // Imported snapshot untouched: same playlist, same membership/order.
    #expect(try await store.songs(inApplePlaylist: "apple-1").map(\.id) == ["s1", "s2"])
    #expect(try await store.applePlaylists().map(\.id) == ["apple-1"])
    // Songs / stats / history untouched.
    #expect(try await store.songCount() == 3)
    #expect(try await store.songStat(songID: "s1")?.playCount == 1)
    #expect(try await store.recentlyPlayedSongIDs() == ["s1"])
  }

  @Test
  func `songs with stats joins play count for app playlist`() async throws {
    let store = try TestSupport.freshStore()
    try await seedSongs(store, ["a", "b"])
    let pl = try await store.createAppPlaylist(named: "P")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["a", "b"])
    try await store.recordPlay(songID: "a", at: Date(timeIntervalSince1970: 9))
    try await store.recordPlay(songID: "a", at: Date(timeIntervalSince1970: 10))

    let rows = try await store.songsWithStats(inAppPlaylist: pl.id)
    #expect(rows.map(\.song.id) == ["a", "b"])
    #expect(rows[0].playCount == 2)
    #expect(TestSupport.datesMatch(rows[0].lastPlayedAt, Date(timeIntervalSince1970: 10)))
    // Never-played song → 0 / nil (LEFT JOIN COALESCE).
    #expect(rows[1].playCount == 0)
    #expect(rows[1].lastPlayedAt == nil)
  }

  // MARK: Private

  private func seedSongs(_ store: LibraryStore, _ ids: [String]) async throws {
    try await store.upsertSongs(ids.map {
      TestSupport.sampleSong(id: $0, musicItemID: $0, title: "T\($0)")
    })
  }

}
