import Foundation

/// App-local preferences backed by `UserDefaults`. Not `@Observable` on
/// purpose: `@AppStorage`/observable stores must not live inside `@Observable`
/// classes (they don't trigger view updates). `MusicController` reads/writes
/// this explicitly and holds the observable mirror.
struct UserPreferencesStore {

  // MARK: Lifecycle

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: Internal

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

  /// Whether the genre graph is rebuilt automatically after a change that
  /// can alter which genres share a playlist (an import that added/changed
  /// playlists, or an app-playlist membership edit). **Defaults to `true`**
  /// — the absence of the key reads as on, so an existing install opts in
  /// without a migration and the graph stays current out of the box. The
  /// user can turn it off (the "Reanalyze Automatically" menu toggle);
  /// "Analyze Genre Graph" always rebuilds on demand regardless of this.
  var autoReanalyzeGenreGraph: Bool {
    get { defaults.object(forKey: autoReanalyzeKey) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: autoReanalyzeKey) }
  }

  /// **Analysis threshold (a):** a playlist with more than this many tracks
  /// is excluded from the genre analysis entirely. A few pathological lists
  /// — e.g. "every track WLIR played for 8 years" — span thousands of
  /// tracks across every genre and, because a playlist clique-connects all
  /// its genres, single-handedly blow the graph up to near-complete. Curated
  /// playlists are far smaller, so a size ceiling cleanly drops only the
  /// noise sources. Default 500 (most legit comps — decade/year-end lists —
  /// sit well under that). Clamped ≥ 1 so a bad stored value can't disable
  /// all analysis. The same `UserDefaults` key is bound by the Advanced
  /// settings pane via `@AppStorage` (a plain view; allowed there).
  var genreAnalysisMaxPlaylistTracks: Int {
    get { max(1, defaults.object(forKey: maxPlaylistTracksKey) as? Int ?? 500) }
    nonmutating set { defaults.set(max(1, newValue), forKey: maxPlaylistTracksKey) }
  }

  /// **Analysis threshold (b):** the maximum number of genre-pair edges a
  /// single (eligible) playlist may contribute — its top-N pairs by
  /// intra-playlist co-strength. A broad playlist otherwise dumps
  /// `G·(G−1)/2` incidental pairs; capping to its strongest N keeps the
  /// signal and kills the quadratic blow-up. Default 30 (a focused playlist
  /// has fewer pairs than this and is unaffected). Clamped ≥ 1.
  var genreAnalysisMaxPairsPerPlaylist: Int {
    get { max(1, defaults.object(forKey: maxPairsPerPlaylistKey) as? Int ?? 30) }
    nonmutating set { defaults.set(max(1, newValue), forKey: maxPairsPerPlaylistKey) }
  }

  // MARK: Private

  private let defaults: UserDefaults
  private let lastSelectedPlaylistKey = "lastSelectedPlaylistID"
  private let autoReanalyzeKey = "autoReanalyzeGenreGraph"
  private let maxPlaylistTracksKey = "genreAnalysisMaxPlaylistTracks"
  private let maxPairsPerPlaylistKey = "genreAnalysisMaxPairsPerPlaylist"

}
