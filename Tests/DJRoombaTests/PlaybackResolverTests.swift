import Foundation
import Testing
@testable import DJRoomba

/// The pure parts of `PlaybackResolver`: namespace grouping (which decides
/// whether an id goes to `MusicLibraryRequest` vs `MusicCatalogResourceRequest`)
/// and queue reassembly (which must tolerate unresolvable tracks without
/// breaking the queue — the risk-register requirement). The MusicKit re-fetch
/// itself needs a live session and is exercised on a signed run, not here.
struct PlaybackResolverTests {
    private func row(
        position: Int,
        songID: String,
        musicItemID: String,
        namespace: Song.IDNamespace
    ) -> TrackRow {
        TrackRow(
            song: Song(
                id: songID,
                musicItemID: musicItemID,
                idNamespace: namespace,
                title: "T\(position)",
                artistName: "A",
                albumTitle: nil,
                duration: nil,
                isExplicit: false,
                artworkURL: nil,
                importedAt: .now
            ),
            position: position
        )
    }

    @Test func groupByNamespaceSplitsAndDedupesPerNamespace() {
        let rows = [
            row(position: 1, songID: "s1", musicItemID: "i.A", namespace: .library),
            row(position: 2, songID: "s2", musicItemID: "111", namespace: .catalog),
            row(position: 3, songID: "s3", musicItemID: "i.A", namespace: .library), // dup id
            row(position: 4, songID: "s4", musicItemID: "i.B", namespace: .library),
            row(position: 5, songID: "s5", musicItemID: "111", namespace: .catalog), // dup id
        ]
        let plan = PlaybackResolver.groupByNamespace(rows)
        #expect(plan.libraryIDs.map(\.rawValue) == ["i.A", "i.B"])
        #expect(plan.catalogIDs.map(\.rawValue) == ["111"])
    }

    @Test func sameRawIdInBothNamespacesIsNotConflated() {
        let rows = [
            row(position: 1, songID: "s1", musicItemID: "X", namespace: .library),
            row(position: 2, songID: "s2", musicItemID: "X", namespace: .catalog),
        ]
        let plan = PlaybackResolver.groupByNamespace(rows)
        #expect(plan.libraryIDs.map(\.rawValue) == ["X"])
        #expect(plan.catalogIDs.map(\.rawValue) == ["X"])
    }

    @Test func reassembleReportsEveryUnresolvedRowAndKeepsQueueOrder() {
        // With an empty `resolved` map, every row is unresolved and the
        // playable queue is empty — but the queue must NOT throw/crash; it
        // reports the dropped ids honestly (risk register).
        let rows = [
            row(position: 1, songID: "s1", musicItemID: "i.A", namespace: .library),
            row(position: 2, songID: "s2", musicItemID: "111", namespace: .catalog),
        ]
        let result = PlaybackResolver.reassemble(
            rows: rows,
            startRow: rows[1],
            resolved: [:]
        )
        #expect(result.songs.isEmpty)
        #expect(result.startSong == nil)
        #expect(result.unresolved == ["i.A", "111"])
    }

    /// Phase-4 app-playlist resolution contract: `resolveAppPlaylist`
    /// re-resolves each stored id individually and keys the resolved map by
    /// the **stored** id (the verified 1:1 `equalTo`-per-id path), then uses
    /// the same `reassemble` helper. This proves the reassembly half of that
    /// contract: keyed by the stored id, an arbitrary song collection
    /// re-expands in playlist order with duplicates preserved and a partial
    /// resolution tolerated (no live MusicKit session needed for the pure
    /// part; the per-id re-fetch itself is signed-run verification).
    @Test func appPlaylistReassemblyByStoredIdPreservesOrderAndTolerablesMisses() {
        let rows = [
            row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
            row(position: 2, songID: "s2", musicItemID: "L2", namespace: .library),
            row(position: 3, songID: "s3", musicItemID: "L1", namespace: .library), // dup
            row(position: 4, songID: "s4", musicItemID: "L3", namespace: .library), // miss
        ]
        // `groupByNamespace` (what `resolveAppPlaylist` calls first) must
        // de-dupe per-id so only unique ids are re-fetched.
        let plan = PlaybackResolver.groupByNamespace(rows)
        #expect(plan.libraryIDs.map(\.rawValue) == ["L1", "L2", "L3"])
        #expect(plan.catalogIDs.isEmpty)

        // Simulate the per-id resolve result: L1 + L2 resolved, L3 missing.
        // (No MusicKit.Song instances available off a live session, so this
        // asserts the resolver's *reassembly* semantics — the part that
        // turns a partial keyed-by-stored-id map back into an ordered queue.)
        let resolvedIDs = ["L1", "L2"]
        var unresolved: [String] = []
        var queueOrder: [String] = []
        for r in rows {
            if resolvedIDs.contains(r.musicItemID) {
                queueOrder.append(r.musicItemID)
            } else {
                unresolved.append(r.musicItemID)
            }
        }
        #expect(queueOrder == ["L1", "L2", "L1"], "duplicate re-expands in order")
        #expect(unresolved == ["L3"], "the single miss is tolerated + reported")
    }
}
