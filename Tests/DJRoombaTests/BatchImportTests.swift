import Foundation
import Testing
@testable import DJRoomba

/// D3 corrective: row-by-row import is replaced with SQLite batch idioms —
/// a chunked multi-row `INSERT … ON CONFLICT DO UPDATE` UPSERT, a single
/// chunked `IN (VALUES …)` id lookup, and chunked membership inserts. These
/// pin the two non-negotiable invariants: the UPSERT must preserve the
/// stable `song.id` PK on re-import (non-destructive — FKs never orphan),
/// and the batched lookup must be correct across a chunk boundary.
struct BatchImportTests {
  @Test
  func `upsert preserves stable song ID on reimport`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(
        id: "keep-me",
        musicItemID: "i.MID",
        namespace: .library,
        title: "First",
      )
    ])
    // Re-import the SAME key with a different app id + changed metadata
    // (what a real refresh does). The UPSERT's DO UPDATE must NOT touch
    // `id`: the original row id survives, metadata refreshes.
    try await store.upsertSongs([
      TestSupport.sampleSong(
        id: "DISCARD-ME",
        musicItemID: "i.MID",
        namespace: .library,
        title: "Refreshed",
      )
    ])

    #expect(try await store.songCount() == 1)
    let resolved = try await store.song(musicItemID: "i.MID", namespace: .library)
    #expect(resolved?.id == "keep-me")
    #expect(resolved?.title == "Refreshed")
  }

  @Test
  func `upsert preserves playlist FK across reimport`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "song-1", musicItemID: "m1", namespace: .library)
    ])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "pl", name: "Mix", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["song-1"],
    )
    // Re-import with a fresh app id → FK from apple_playlist_track must
    // still resolve (id preserved by the UPSERT).
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "fresh", musicItemID: "m1", namespace: .library, title: "Renamed")
    ])
    let tracks = try await store.songs(inApplePlaylist: "pl")
    #expect(tracks.map(\.id) == ["song-1"])
    #expect(tracks.first?.title == "Renamed")
  }

  @Test
  func `batched ID lookup is correct across A chunk boundary`() async throws {
    let store = try TestSupport.freshStore()
    // 1200 songs > the 999-variable cap (≈499 keys/chunk), so the lookup
    // and the upsert both cross several chunk boundaries.
    let songs = (0..<1200).map { i in
      TestSupport.sampleSong(
        id: "id-\(i)",
        musicItemID: "mid-\(i)",
        namespace: .library,
        title: "T\(i)",
      )
    }
    try await store.upsertSongs(songs)
    #expect(try await store.songCount() == 1200)

    let keys = (0..<1200).map { ("mid-\($0)", Song.IDNamespace.library) }
    let map = try await store.songIDsByKey(keys)
    #expect(map.count == 1200)
    for i in 0..<1200 {
      let key = LibraryStore.SongKey(musicItemID: "mid-\(i)", namespace: .library)
      #expect(map[key] == "id-\(i)")
    }
  }

  @Test
  func `chunked membership insert preserves order for large playlist`() async throws {
    let store = try TestSupport.freshStore()
    let songs = (0..<1100).map {
      TestSupport.sampleSong(id: "s\($0)", musicItemID: "mi\($0)", namespace: .library)
    }
    try await store.upsertSongs(songs)
    let ordered = (0..<1100).map { "s\($0)" }
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "big", name: "Big", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ordered,
    )
    let got = try await store.songs(inApplePlaylist: "big").map(\.id)
    #expect(got == ordered)
  }

  @Test
  func `empty inputs are no ops`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([])
    #expect(try await store.songCount() == 0)
    let map = try await store.songIDsByKey([])
    #expect(map.isEmpty)
  }
}
