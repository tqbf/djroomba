import Foundation
import Testing
@testable import DJRoomba

/// Phase 4 UI-corrective regressions. These pin the *state-refresh* fixes
/// behind the 4 stickler-bar UI defects (the data layer was already correct
/// and is covered elsewhere):
///
/// - **D3** — `PlaylistSummary` equality must reflect `trackCount` (and
///   `name`) so a membership change reloaded from SQLite actually re-renders
///   the sidebar row. Omitting them made `ForEach` diff the reloaded summary
///   as "unchanged" and the "My Playlists" count went stale after add/remove.
/// - **D4** — `PlaylistDetailService.refreshStats` must pick up a play
///   recorded *after* the detail was first loaded/cached, so the track
///   table's Plays / Last Played columns reflect `song_stat` on the discrete
///   play-recorded / (re)selection events (no refresh loop).
struct UIRefreshCorrectionTests {

  // MARK: Internal

  @Test
  func `summary equality reflects track count`() {
    let a = PlaylistSummary(
      id: "p1",
      name: "Mine",
      trackCount: 0,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )
    let b = PlaylistSummary(
      id: "p1",
      name: "Mine",
      trackCount: 2,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )
    // Same id + favorite but a different count must NOT compare equal,
    // otherwise SwiftUI's ForEach skips the row body and the count stays
    // stale (the D3 defect).
    #expect(a != b)
  }

  @Test
  func `summary equality reflects name`() {
    let a = PlaylistSummary(
      id: "p1",
      name: "Old",
      trackCount: 3,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )
    let b = PlaylistSummary(
      id: "p1",
      name: "New",
      trackCount: 3,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )
    // An inline rename must re-render the row immediately.
    #expect(a != b)
  }

  @Test
  func `summary equality still reflects favorite and identity`() {
    let base = PlaylistSummary(
      id: "p1",
      name: "Mine",
      trackCount: 2,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )
    var favorited = base
    favorited.isFavorite = true
    #expect(base != favorited, "favorite still re-renders the star")

    let same = PlaylistSummary(
      id: "p1",
      name: "Mine",
      trackCount: 2,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )
    #expect(base == same, "identical content compares equal (no churn)")

    let other = PlaylistSummary(
      id: "p2",
      name: "Mine",
      trackCount: 2,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )
    #expect(base != other, "different identity is still unequal")
    // Hash stays id-only (Hashable contract: == implies same id).
    #expect(base.hashValue == same.hashValue)
  }

  @MainActor
  @Test
  func `refresh stats picks up A play recorded after load`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "a", musicItemID: "a", title: "A"),
      TestSupport.sampleSong(id: "b", musicItemID: "b", title: "B"),
    ])
    let pl = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["a", "b"])

    let service = PlaylistDetailService(store: store)
    let summary = PlaylistSummary(
      id: pl.id,
      name: "Mine",
      trackCount: 2,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )

    // Initial load: nothing played yet.
    service.select(summary)
    try await pollUntil { service.detail != nil }
    #expect(service.detail?.tracks.first?.playCount == 0)

    // A play happens while this playlist is on screen.
    try await store.recordPlay(songID: "a", at: Date(timeIntervalSince1970: 100))

    // The discrete play-recorded event refreshes the joined stats.
    await service.refreshStats(for: pl.id)
    let rowA = service.detail?.tracks.first { $0.songID == "a" }
    let rowB = service.detail?.tracks.first { $0.songID == "b" }
    #expect(rowA?.playCount == 1, "Plays column reflects song_stat after a play (D4)")
    #expect(
      TestSupport.datesMatch(rowA?.lastPlayedAt, Date(timeIntervalSince1970: 100))
    )
    #expect(rowB?.playCount == 0, "untouched song unaffected")
    // Membership/order is unchanged by a stats refresh.
    #expect(service.detail?.tracks.map(\.songID) == ["a", "b"])
  }

  @MainActor
  @Test
  func `reselecting A cached playlist refreshes stale stats`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      TestSupport.sampleSong(id: "a", musicItemID: "a", title: "A")
    ])
    let pl = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["a"])

    let service = PlaylistDetailService(store: store)
    let summary = PlaylistSummary(
      id: pl.id,
      name: "Mine",
      trackCount: 1,
      isEditable: true,
      source: .appPlaylist,
      isFavorite: false,
    )

    // Load & cache with 0 plays, then switch away.
    service.select(summary)
    try await pollUntil { service.detail != nil }
    service.clear()

    // A play is recorded while the playlist is NOT on screen.
    try await store.recordPlay(songID: "a", at: .now)

    // Re-selecting serves the cached rows immediately, then the discrete
    // (re)selection event refreshes the stat columns from SQLite.
    service.select(summary)
    try await pollUntil { service.detail?.tracks.first?.playCount == 1 }
    #expect(service.detail?.tracks.first?.playCount == 1)
  }

  // MARK: Private

  /// Poll a main-actor condition with a bounded structured-concurrency wait
  /// (the service does its store I/O in a child Task). No GCD, never the
  /// nanoseconds sleep form.
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
