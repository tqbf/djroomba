import Foundation
import Testing
@testable import DJRoomba

/// Incremental import (the only real lever on the ~90–120 s import — see
/// plans/profiling.md): skip the expensive MusicKit track fetch for
/// playlists whose change token is unchanged. All of this is exercised
/// **unsigned, no MusicKit** — the pure decision and the SQLite plumbing
/// are the parts we control; the MusicKit list/track fetch is the
/// signed-only boundary and is deliberately not in scope here.
struct IncrementalImportTests {

  @Test
  func `force always refetches even when tokens match`() {
    #expect(
      ImportService.importDecision(
        currentToken: 7,
        storedToken: 7,
        hasStoredSnapshot: true,
        force: true,
      ) == .fetch
    )
  }

  @Test
  func `missing current token refetches (no usable signal)`() {
    #expect(
      ImportService.importDecision(
        currentToken: nil,
        storedToken: 7,
        hasStoredSnapshot: true,
        force: false,
      ) == .fetch
    )
  }

  @Test
  func `no existing snapshot refetches`() {
    #expect(
      ImportService.importDecision(
        currentToken: 7,
        storedToken: nil,
        hasStoredSnapshot: false,
        force: false,
      ) == .fetch
    )
  }

  @Test
  func `snapshot without a stored token refetches`() {
    #expect(
      ImportService.importDecision(
        currentToken: 7,
        storedToken: nil,
        hasStoredSnapshot: true,
        force: false,
      ) == .fetch
    )
  }

  @Test
  func `equal tokens skip the expensive fetch`() {
    #expect(
      ImportService.importDecision(
        currentToken: 42,
        storedToken: 42,
        hasStoredSnapshot: true,
        force: false,
      ) == .skipUnchanged
    )
  }

  @Test
  func `changed token refetches`() {
    #expect(
      ImportService.importDecision(
        currentToken: 43,
        storedToken: 42,
        hasStoredSnapshot: true,
        force: false,
      ) == .fetch
    )
  }

  @Test
  func `change tokens round trip including nil and absent`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([TestSupport.sampleSong(id: "s", musicItemID: "m")])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(
        id: "withTok",
        name: "A",
        artworkURL: nil,
        curator: nil,
        lastImportedAt: .now,
        changeToken: 12345,
      ),
      songIDs: ["s"],
    )
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(
        id: "noTok",
        name: "B",
        artworkURL: nil,
        curator: nil,
        lastImportedAt: .now,
      ),
      songIDs: ["s"],
    )

    let tokens = try await store.applePlaylistChangeTokens()
    #expect(tokens["withTok"].flatMap { $0 } == 12345)
    #expect(tokens.keys.contains("noTok"))
    #expect(tokens["noTok"].flatMap { $0 } == nil)
    #expect(!tokens.keys.contains("absent"))
  }

  @Test
  func `touch import date keeps membership and token`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "s1", musicItemID: "m1"),
      TestSupport.sampleSong(id: "s2", musicItemID: "m2"),
    ])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(
        id: "p",
        name: "P",
        artworkURL: nil,
        curator: nil,
        lastImportedAt: Date(timeIntervalSince1970: 1_000_000),
        changeToken: 999,
      ),
      songIDs: ["s1", "s2"],
    )

    try await store.touchApplePlaylistImportDate(
      "p",
      to: Date(timeIntervalSince1970: 2_000_000),
    )

    #expect(try await store.songs(inApplePlaylist: "p").map(\.id) == ["s1", "s2"])
    let tokens = try await store.applePlaylistChangeTokens()
    #expect(tokens["p"].flatMap { $0 } == 999)
  }

  @Test
  func `prune drops vanished apple playlists but never app-owned data`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([TestSupport.sampleSong(id: "song", musicItemID: "mm")])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "A", name: "A", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["song"],
    )
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "B", name: "B", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["song"],
    )

    // App-owned data, some of it deliberately referencing pruned playlist
    // "A" by id (favorites/recents have no FK — must survive regardless).
    let mine = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(mine.id, songIDs: ["song"])
    try await store.setFavorite(true, playlistID: "A", source: .apple)
    try await store.recordRecent(playlistID: "A", source: .apple)
    try await store.recordPlay(songID: "song")

    try await store.pruneApplePlaylists(keeping: ["B"])

    // Vanished snapshot + its membership gone; kept one intact.
    let appleIDs = try await store.applePlaylists().map(\.id)
    #expect(!appleIDs.contains("A"))
    #expect(appleIDs.contains("B"))
    #expect(try await store.songs(inApplePlaylist: "A").isEmpty)
    #expect(try await store.songs(inApplePlaylist: "B").map(\.id) == ["song"])

    // One-way isolation: nothing app-owned was touched.
    #expect(try await store.appPlaylists().contains { $0.id == mine.id })
    #expect(try await store.songs(inAppPlaylist: mine.id).map(\.id) == ["song"])
    #expect(try await store.favorites().count == 1)
    #expect(try await store.recentPlaylists().count == 1)
    #expect(try await store.songStat(songID: "song")?.playCount == 1)
    #expect(try await store.songCount() == 1) // song never deleted
  }
}
