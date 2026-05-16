import Foundation
import Testing
@testable import DJRoomba

/// Song upsert dedupes on `(music_item_id, id_namespace)` and preserves the
/// stable app id across re-import (so FKs never orphan).
struct SongUpsertTests {
  @Test
  func `upsert dedupes on music item id and namespace`() async throws {
    let store = try TestSupport.freshStore()

    let first = TestSupport.sampleSong(
      id: "stable-uuid",
      musicItemID: "i.ABC",
      namespace: .library,
      title: "Original Title",
    )
    try await store.upsertSongs([first])

    // Same MusicKit key, different app id + changed metadata.
    let second = TestSupport.sampleSong(
      id: "DIFFERENT-uuid",
      musicItemID: "i.ABC",
      namespace: .library,
      title: "Updated Title",
    )
    try await store.upsertSongs([second])

    #expect(try await store.songCount() == 1)
    let resolved = try await store.song(musicItemID: "i.ABC", namespace: .library)
    #expect(resolved?.title == "Updated Title")
    // Stable id preserved — the second call's id was discarded.
    #expect(resolved?.id == "stable-uuid")
  }

  @Test
  func `same music item id different namespace are distinct songs`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(musicItemID: "X", namespace: .library),
      TestSupport.sampleSong(musicItemID: "X", namespace: .catalog),
    ])
    #expect(try await store.songCount() == 2)
  }

  @Test
  func `reimport keeps playlist membership intact`() async throws {
    let store = try TestSupport.freshStore()
    let song = TestSupport.sampleSong(id: "song-1", musicItemID: "m1")
    try await store.upsertSongs([song])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "pl1", name: "Mix", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["song-1"],
    )

    // Re-import the same song with a fresh app id.
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "would-be-new", musicItemID: "m1", title: "Renamed")
    ])

    let tracks = try await store.songs(inApplePlaylist: "pl1")
    #expect(tracks.count == 1)
    #expect(tracks.first?.id == "song-1")
    #expect(tracks.first?.title == "Renamed")
  }
}
