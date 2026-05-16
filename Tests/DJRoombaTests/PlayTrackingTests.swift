import Foundation
import Testing
@testable import DJRoomba

/// `recordPlay` appends a `play_event` and keeps `song_stat`
/// (play_count / last_played_at) consistent in the same transaction.
struct PlayTrackingTests {
    @Test func firstPlayCreatesStatAtCountOne() async throws {
        let store = try TestSupport.freshStore()
        try await store.upsertSongs([TestSupport.sampleSong(id: "s", musicItemID: "s")])

        let t0 = Date.now
        try await store.recordPlay(songID: "s", at: t0)

        let stat = try await store.songStat(songID: "s")
        #expect(stat?.playCount == 1)
        #expect(TestSupport.datesMatch(stat?.lastPlayedAt, t0))
        #expect(try await store.playEventCount(songID: "s") == 1)
    }

    @Test func repeatedPlaysIncrementCountAndAdvanceRecency() async throws {
        let store = try TestSupport.freshStore()
        try await store.upsertSongs([TestSupport.sampleSong(id: "s", musicItemID: "s")])

        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        try await store.recordPlay(songID: "s", at: t1)
        try await store.recordPlay(songID: "s", at: t2)

        let stat = try await store.songStat(songID: "s")
        #expect(stat?.playCount == 2)
        #expect(stat?.lastPlayedAt == t2)
        #expect(try await store.playEventCount(songID: "s") == 2)
    }

    @Test func backfilledOlderPlayDoesNotMoveRecencyBackward() async throws {
        let store = try TestSupport.freshStore()
        try await store.upsertSongs([TestSupport.sampleSong(id: "s", musicItemID: "s")])

        let recent = Date(timeIntervalSince1970: 5_000)
        let older = Date(timeIntervalSince1970: 1_000)
        try await store.recordPlay(songID: "s", at: recent)
        try await store.recordPlay(songID: "s", at: older)

        let stat = try await store.songStat(songID: "s")
        #expect(stat?.playCount == 2)
        #expect(stat?.lastPlayedAt == recent, "last_played_at must only advance")
    }

    @Test func playEventForMissingSongIsRejectedAndStatUnchanged() async throws {
        let store = try TestSupport.freshStore()
        // No song inserted → FK RESTRICT on play_event.song_id must throw,
        // and the whole transaction (incl. song_stat) must roll back.
        await #expect(throws: (any Error).self) {
            try await store.recordPlay(songID: "ghost", at: .now)
        }
        #expect(try await store.songStat(songID: "ghost") == nil)
        #expect(try await store.playEventCount(songID: "ghost") == 0)
    }
}
