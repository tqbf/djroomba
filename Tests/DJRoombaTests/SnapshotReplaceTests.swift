import Foundation
import Testing
@testable import DJRoomba

/// Apple-playlist snapshot replace is transactional and isolated: it
/// replaces membership without touching app playlists, song stats, or
/// play history.
struct SnapshotReplaceTests {
    @Test func snapshotReplaceSwapsMembershipInOrder() async throws {
        let store = try TestSupport.freshStore()
        try await store.upsertSongs([
            TestSupport.sampleSong(id: "a", musicItemID: "a"),
            TestSupport.sampleSong(id: "b", musicItemID: "b"),
            TestSupport.sampleSong(id: "c", musicItemID: "c"),
        ])
        let pl = ApplePlaylist(id: "pl", name: "P", artworkURL: nil, curator: nil, lastImportedAt: .now)

        try await store.replaceApplePlaylistSnapshot(pl, songIDs: ["a", "b"])
        var ids = try await store.songs(inApplePlaylist: "pl").map(\.id)
        #expect(ids == ["a", "b"])

        // Replace with a different, reordered set.
        try await store.replaceApplePlaylistSnapshot(pl, songIDs: ["c", "a"])
        ids = try await store.songs(inApplePlaylist: "pl").map(\.id)
        #expect(ids == ["c", "a"])
    }

    @Test func snapshotReplaceDoesNotTouchAppDataOrStats() async throws {
        let store = try TestSupport.freshStore()
        try await store.upsertSongs([
            TestSupport.sampleSong(id: "s1", musicItemID: "s1"),
            TestSupport.sampleSong(id: "s2", musicItemID: "s2"),
        ])

        // Set up app-owned state + a play stat.
        try await store.createAppPlaylist(
            AppPlaylist(id: "app1", name: "Mine", createdAt: .now, updatedAt: .now, sortIndex: 0)
        )
        try await store.setAppPlaylistTracks("app1", songIDs: ["s1"])
        try await store.recordPlay(songID: "s1", at: .now)

        // Now do an Apple snapshot import twice.
        let pl = ApplePlaylist(id: "ap", name: "Imported", artworkURL: nil, curator: nil, lastImportedAt: .now)
        try await store.replaceApplePlaylistSnapshot(pl, songIDs: ["s1", "s2"])
        try await store.replaceApplePlaylistSnapshot(pl, songIDs: ["s2"])

        // App playlist membership untouched.
        let appTracks = try await store.songs(inAppPlaylist: "app1").map(\.id)
        #expect(appTracks == ["s1"])
        // song_stat untouched.
        let stat = try await store.songStat(songID: "s1")
        #expect(stat?.playCount == 1)
        // play_event untouched.
        #expect(try await store.playEventCount(songID: "s1") == 1)
    }

    @Test func snapshotReplaceIsAtomicOnFailure() async throws {
        let store = try TestSupport.freshStore()
        try await store.upsertSongs([TestSupport.sampleSong(id: "ok", musicItemID: "ok")])
        let pl = ApplePlaylist(id: "p", name: "P", artworkURL: nil, curator: nil, lastImportedAt: .now)
        try await store.replaceApplePlaylistSnapshot(pl, songIDs: ["ok"])

        // Second replace references a nonexistent song → FK RESTRICT throws.
        // The transaction must roll back, leaving the old snapshot intact.
        await #expect(throws: (any Error).self) {
            try await store.replaceApplePlaylistSnapshot(pl, songIDs: ["ok", "missing-song"])
        }
        let ids = try await store.songs(inApplePlaylist: "p").map(\.id)
        #expect(ids == ["ok"], "failed replace must roll back to the prior snapshot")
    }
}
