import Foundation

/// One-shot migration of the M2 UserDefaults stores
/// (`FavoritesStore` / `RecentlyPlayedStore`) into the SQLite
/// `favorite_playlist` / `recent_playlist` tables.
///
/// Runs at most once per install: a sentinel UserDefaults flag records
/// completion, after which the legacy keys are NEVER read or written again
/// (no dual-write — the local-first pivot makes SQLite the sole source of
/// truth). `UserPreferencesStore` (last selection / sidebar) deliberately
/// stays in UserDefaults and is untouched here.
///
/// Driven only from the `@MainActor` controller (it holds a non-`Sendable`
/// `UserDefaults`, so it is intentionally not `Sendable`). The pure planning
/// step (`plan(favorites:recentsMostRecentFirst:now:)`) is `static` and is
/// unit-tested without touching SQLite or a live `UserDefaults`.
struct LegacyPreferencesMigration {
    /// Sentinel: set true once the migration has run (success or no-op).
    static let completedKey = "legacyPrefsMigratedToSQLite_v1"

    /// Legacy keys (must match the M2 stores byte-for-byte).
    static let favoritesKey = "favoritePlaylistIDs"
    static let recentsKey = "recentlyPlayedPlaylistIDs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What the migration intends to write, derived purely from the legacy
    /// values (no DB, no clock). Recents are written oldest→newest so the
    /// stored `played_at` ordering matches the legacy most-recent-first list
    /// when read back `ORDER BY played_at DESC`.
    struct Plan: Equatable, Sendable {
        /// All legacy favorite ids (source defaults to `.apple`: every M2
        /// favorite was an Apple library playlist — app playlists are Phase 4).
        var favoriteIDs: [String]
        /// Recent ids in *chronological* order (oldest first) with the
        /// timestamp to stamp each at.
        var recents: [(id: String, playedAt: Date)]

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.favoriteIDs == rhs.favoriteIDs
                && lhs.recents.map(\.id) == rhs.recents.map(\.id)
                && zip(lhs.recents, rhs.recents).allSatisfy {
                    abs($0.playedAt.timeIntervalSince($1.playedAt)) < 0.001
                }
        }
    }

    /// Build the migration plan from the legacy arrays. `now` anchors the
    /// recents timeline; the most-recent legacy entry (index 0) gets `now`,
    /// each older one a second earlier — only the relative order matters for
    /// `ORDER BY played_at DESC`.
    static func plan(
        favorites: [String],
        recentsMostRecentFirst: [String],
        now: Date
    ) -> Plan {
        let chronological = recentsMostRecentFirst.reversed().enumerated().map {
            offsetFromOldest, id -> (id: String, playedAt: Date) in
            // oldest gets the earliest time; index 0 (newest) gets `now`.
            let secondsBeforeNow = Double(recentsMostRecentFirst.count - 1 - offsetFromOldest)
            return (id: id, playedAt: now.addingTimeInterval(-secondsBeforeNow))
        }
        return Plan(favoriteIDs: favorites, recents: chronological)
    }

    var hasCompleted: Bool {
        defaults.bool(forKey: Self.completedKey)
    }

    /// Run the one-shot migration if it hasn't already. Idempotent: returns
    /// immediately on subsequent launches. The legacy keys are intentionally
    /// left in place but never read again (cheap, and avoids destroying data
    /// if a downgrade ever happens); the sentinel is what gates re-runs.
    /// `@MainActor`: called from the `@MainActor` controller and touches a
    /// non-`Sendable` `UserDefaults`, so it stays pinned to the main actor
    /// across `await`s. The `store` calls it awaits hop off-main internally
    /// (GRDB) — the migration writes are not done on the main thread.
    @MainActor
    func runIfNeeded(into store: LibraryStore) async throws {
        guard !hasCompleted else { return }

        let favorites = defaults.stringArray(forKey: Self.favoritesKey) ?? []
        let recents = defaults.stringArray(forKey: Self.recentsKey) ?? []
        let plan = Self.plan(
            favorites: favorites,
            recentsMostRecentFirst: recents,
            now: .now
        )

        for id in plan.favoriteIDs {
            try await store.setFavorite(true, playlistID: id, source: .apple)
        }
        for entry in plan.recents {
            try await store.recordRecent(
                playlistID: entry.id,
                source: .apple,
                at: entry.playedAt
            )
        }

        defaults.set(true, forKey: Self.completedKey)
    }
}
