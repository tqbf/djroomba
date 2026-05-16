import Foundation
import Testing
@testable import DJRoomba

/// D1 corrective: the string-sniffing `ImportService.namespace(forRawID:)`
/// heuristic is **deleted**. Imported tracks come exclusively from the user's
/// *library* playlists, so namespace is fixed by **provenance** to
/// `.library` — never inferred from the shape of the id string. There is no
/// pure classifier left to unit-test (the old one degenerated to integer
/// sign on real data, which is exactly the bug the gate caught).
///
/// What IS testable without a live MusicKit session: that the store round
/// trips a library-provenance song key correctly (the half of the 🔴
/// round trip the agent can exercise — the MusicKit re-fetch itself is a
/// signed-run check). These pin the contract `PlaybackResolver` depends on.
struct ImportProvenanceTests {
  @Test
  func `library provenance song round trips by key`() async throws {
    let store = try TestSupport.freshStore()
    // An opaque macOS library MusicItemID (persistentID-derived) — the
    // exact shape that broke the old heuristic. Provenance says library.
    let song = TestSupport.sampleSong(
      id: "stable",
      musicItemID: "8675309123456789",
      namespace: .library,
      title: "Round Trip",
    )
    try await store.upsertSongs([song])

    let map = try await store.songIDsByKey([
      ("8675309123456789", .library)
    ])
    #expect(map[LibraryStore.SongKey(
      musicItemID: "8675309123456789",
      namespace: .library,
    )] == "stable")
  }

  @Test
  func `different namespaces are distinct keys in batch lookup`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "lib", musicItemID: "DUP", namespace: .library),
      TestSupport.sampleSong(id: "cat", musicItemID: "DUP", namespace: .catalog),
    ])
    let map = try await store.songIDsByKey([
      ("DUP", .library),
      ("DUP", .catalog),
    ])
    #expect(map[LibraryStore.SongKey(musicItemID: "DUP", namespace: .library)] == "lib")
    #expect(map[LibraryStore.SongKey(musicItemID: "DUP", namespace: .catalog)] == "cat")
  }
}
