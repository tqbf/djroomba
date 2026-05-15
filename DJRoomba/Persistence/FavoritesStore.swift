import Foundation

/// Persisted set of favorited playlist ids (MusicItemID rawValues). App state,
/// not music state. Not `@Observable` (UserDefaults must not back an
/// `@Observable`); `MusicController` holds the observable mirror.
struct FavoritesStore {
    private let defaults: UserDefaults
    private let key = "favoritePlaylistIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func save(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: key)
    }
}
