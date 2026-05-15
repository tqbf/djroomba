import Foundation

/// Persisted, capped, most-recent-first list of playlist ids that playback was
/// started from. App state, not music state. Not `@Observable`;
/// `MusicController` holds the observable mirror.
struct RecentlyPlayedStore {
    private let defaults: UserDefaults
    private let key = "recentlyPlayedPlaylistIDs"
    let limit: Int

    init(defaults: UserDefaults = .standard, limit: Int = 12) {
        self.defaults = defaults
        self.limit = limit
    }

    func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Returns the updated list with `id` moved/inserted at the front, capped.
    func record(_ id: String, into current: [String]) -> [String] {
        var updated = current
        updated.removeAll { $0 == id }
        updated.insert(id, at: 0)
        if updated.count > limit {
            updated = Array(updated.prefix(limit))
        }
        defaults.set(updated, forKey: key)
        return updated
    }
}
