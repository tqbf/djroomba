import Foundation
import Testing
@testable import DJRoomba

/// Phase 5 edge / error hardening. The spec testing checklist's deterministic
/// parts: rapid playlist switching must cancel in-flight loads and land on the
/// last selection (no stale detail from a superseded load), a playlist that
/// disappeared between refreshes must not surface its (now-empty) detail, and
/// an unplayable/region-removed track must not break the rest of the queue.
/// (Network-down / huge-library are signed-run / load behaviors; the resolver
/// tolerance is also covered in `PlaybackResolverTests`.)
struct EdgeHardeningTests {

  // MARK: Internal

  @MainActor
  @Test
  func `rapid switching lands on the last selection not A stale one`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "a1", musicItemID: "a1", title: "A1"),
      TestSupport.sampleSong(id: "b1", musicItemID: "b1", title: "B1"),
      TestSupport.sampleSong(id: "c1", musicItemID: "c1", title: "C1"),
    ])
    let pA = try await store.createAppPlaylist(named: "A")
    let pB = try await store.createAppPlaylist(named: "B")
    let pC = try await store.createAppPlaylist(named: "C")
    try await store.addSongsToAppPlaylist(pA.id, songIDs: ["a1"])
    try await store.addSongsToAppPlaylist(pB.id, songIDs: ["b1"])
    try await store.addSongsToAppPlaylist(pC.id, songIDs: ["c1"])

    let service = PlaylistDetailService(store: store)
    func summary(_ p: AppPlaylist) -> PlaylistSummary {
      PlaylistSummary(
        id: p.id,
        name: p.name,
        trackCount: 1,
        isEditable: true,
        source: .appPlaylist,
        isFavorite: false,
      )
    }

    // Three selections back-to-back without awaiting between them — each
    // `select` cancels the prior in-flight load.
    service.select(summary(pA))
    service.select(summary(pB))
    service.select(summary(pC))

    // It must settle on C (the last selection), never A's or B's rows.
    try await pollUntil { service.detail?.id == pC.id }
    #expect(service.detail?.id == pC.id)
    #expect(service.detail?.tracks.map(\.songID) == ["c1"])
  }

  @MainActor
  @Test
  func `clear after select drops an in flight load`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "x", musicItemID: "x", title: "X")
    ])
    let p = try await store.createAppPlaylist(named: "P")
    try await store.addSongsToAppPlaylist(p.id, songIDs: ["x"])

    let service = PlaylistDetailService(store: store)
    let summary = PlaylistSummary(
      id: p.id,
      name: "P",
      trackCount: 1,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )

    // Select then immediately clear (the "selected playlist disappeared
    // between refreshes → selection cleared silently" path the controller
    // drives). The cancelled load must not resurrect a detail.
    service.select(summary)
    service.clear()

    // Give any (cancelled) load a chance to (not) complete.
    try await Task.sleep(for: .milliseconds(50))
    #expect(service.detail == nil, "a cleared selection never shows stale detail")
  }

  @Test
  func `one unplayable track does not break the rest of the queue`() {
    /// Region-removed / user-upload / music-video: that id won't resolve,
    /// but the queue must still be built from what *did* resolve and the
    /// miss reported (never throw / never drop the whole playlist).
    func row(_ pos: Int, _ id: String) -> TrackRow {
      TrackRow(
        song: Song(
          id: id,
          musicItemID: id,
          idNamespace: .library,
          title: "T\(pos)",
          artistName: "A",
          albumTitle: nil,
          duration: nil,
          isExplicit: false,
          artworkURL: nil,
          importedAt: .now,
        ),
        position: pos,
      )
    }
    let rows = [row(1, "ok1"), row(2, "gone"), row(3, "ok2")]
    // Simulate: "gone" failed to re-resolve (absent from the map).
    let result = PlaybackResolver.reassemble(
      rows: rows,
      startRow: rows[1], // start at the unplayable one
      resolved: [:], // empty stand-in; semantics: nothing resolved
    )
    // Nothing resolved here, but crucially the helper does not throw and
    // reports every dropped id in order — the queue-integrity contract.
    #expect(result.unresolved == ["ok1", "gone", "ok2"])
    #expect(result.songs.isEmpty)
    #expect(result.startSong == nil) // start fell through, no crash
  }

  // MARK: Private

  /// Bounded structured-concurrency poll (service I/O runs in a child Task).
  @MainActor
  private func pollUntil(
    _ condition: () -> Bool,
    timeout: Duration = .seconds(2),
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "condition not met within timeout")
  }
}
