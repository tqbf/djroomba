import Foundation

/// App-local preferences backed by `UserDefaults`. Not `@Observable` on
/// purpose: `@AppStorage`/observable stores must not live inside `@Observable`
/// classes (they don't trigger view updates). `MusicController` reads/writes
/// this explicitly and holds the observable mirror.
struct UserPreferencesStore {
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var lastSelectedPlaylistID: String? {
    get { defaults.string(forKey: lastSelectedPlaylistKey) }
    nonmutating set {
      if let newValue {
        defaults.set(newValue, forKey: lastSelectedPlaylistKey)
      } else {
        defaults.removeObject(forKey: lastSelectedPlaylistKey)
      }
    }
  }

  private let defaults: UserDefaults
  private let lastSelectedPlaylistKey = "lastSelectedPlaylistID"

}
