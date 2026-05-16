import Foundation
import Testing
@testable import DJRoomba

/// The one-shot UserDefaults → SQLite migration of M2 favorites/recents.
/// Covers the pure plan derivation and the end-to-end run (idempotent,
/// order-preserving, no dual-write afterwards).
@MainActor
struct LegacyMigrationTests {

  // MARK: Internal

  @Test
  func `plan maps favorites and orders recents chronologically`() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let plan = LegacyPreferencesMigration.plan(
      favorites: ["fav1", "fav2"],
      recentsMostRecentFirst: ["new", "mid", "old"],
      now: now,
    )
    #expect(plan.favoriteIDs == ["fav1", "fav2"])
    // Stored oldest→newest so `ORDER BY played_at DESC` reproduces the
    // legacy most-recent-first list.
    #expect(plan.recents.map(\.id) == ["old", "mid", "new"])
    #expect(plan.recents[0].playedAt < plan.recents[1].playedAt)
    #expect(plan.recents[1].playedAt < plan.recents[2].playedAt)
    #expect(plan.recents.last?.playedAt == now)
  }

  @Test
  func `plan handles empty legacy state`() {
    let plan = LegacyPreferencesMigration.plan(
      favorites: [],
      recentsMostRecentFirst: [],
      now: .now,
    )
    #expect(plan.favoriteIDs.isEmpty)
    #expect(plan.recents.isEmpty)
  }

  @Test
  func `migrates legacy values into SQ lite then stops`() async throws {
    let defaults = try isolatedDefaults()
    defaults.set(["A", "B"], forKey: LegacyPreferencesMigration.favoritesKey)
    // Legacy recents are most-recent-first.
    defaults.set(["r-new", "r-old"], forKey: LegacyPreferencesMigration.recentsKey)

    let store = try TestSupport.freshStore()
    let migration = LegacyPreferencesMigration(defaults: defaults)

    #expect(migration.hasCompleted == false)
    try await migration.runIfNeeded(into: store)
    #expect(migration.hasCompleted == true)

    let favorites = Set(try await store.favorites().map(\.playlistID))
    #expect(favorites == ["A", "B"])

    // Read back DESC → must reproduce the legacy most-recent-first order.
    let recents = try await store.recentPlaylists().map(\.playlistID)
    #expect(recents == ["r-new", "r-old"])
  }

  @Test
  func `second run is A no op even if legacy keys change`() async throws {
    let defaults = try isolatedDefaults()
    defaults.set(["A"], forKey: LegacyPreferencesMigration.favoritesKey)

    let store = try TestSupport.freshStore()
    let migration = LegacyPreferencesMigration(defaults: defaults)
    try await migration.runIfNeeded(into: store)

    // Simulate the (no longer read) legacy keys changing after migration.
    defaults.set(["A", "SHOULD_NOT_IMPORT"], forKey: LegacyPreferencesMigration.favoritesKey)
    try await migration.runIfNeeded(into: store)

    let favorites = Set(try await store.favorites().map(\.playlistID))
    #expect(favorites == ["A"], "legacy keys must never be read again after the one-shot")
  }

  @Test
  func `empty legacy state still marks completed`() async throws {
    let defaults = try isolatedDefaults()
    let store = try TestSupport.freshStore()
    let migration = LegacyPreferencesMigration(defaults: defaults)

    try await migration.runIfNeeded(into: store)
    #expect(migration.hasCompleted == true)
    #expect(try await store.favorites().isEmpty)
    #expect(try await store.recentPlaylists().isEmpty)
  }

  // MARK: Private

  private func isolatedDefaults() throws -> UserDefaults {
    let suite = "djroomba.test.\(UUID().uuidString)"
    let d = try #require(UserDefaults(suiteName: suite))
    d.removePersistentDomain(forName: suite)
    return d
  }

}
