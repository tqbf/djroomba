import SwiftUI

/// The **Advanced** settings pane: the two genre-analysis thresholds the
/// graph is shaped by at analysis time. Set-and-forget knobs — sane
/// defaults, bounded steppers, a one-line explanation per row.
///
/// `@AppStorage` is the right tool here: this is a plain `View`, NOT inside
/// an `@Observable` (the rule only forbids the latter). It binds the SAME
/// `UserDefaults` keys `UserPreferencesStore` reads, so a change is picked
/// up by the next analysis with zero wiring between this window and
/// `MusicController` — the defaults below MUST match `UserPreferencesStore`.
struct GenreAnalysisAdvancedPane: View {

  // MARK: Internal

  var body: some View {
    Form {
      Section {
        LabeledContent("Largest playlist analyzed") {
          Stepper(
            "^[\(maxPlaylistTracks) track](inflect: true)",
            value: $maxPlaylistTracks,
            in: 50 ... 20000,
            step: 50,
          )
        }
        Text(
          "Playlists larger than this are skipped. A few huge lists — e.g. a years-long radio log — span nearly every genre and would otherwise dominate the graph."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        LabeledContent("Genre links per playlist") {
          Stepper(
            "^[\(maxPairsPerPlaylist) link](inflect: true)",
            value: $maxPairsPerPlaylist,
            in: 5 ... 300,
            step: 5,
          )
        }
        Text(
          "Each analyzed playlist contributes only its strongest genre relationships, ranked by how many tracks of each genre it holds."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Genre Analysis")
      } footer: {
        Text(
          "Changes take effect the next time the graph is analyzed: the Genre Graph panel’s rebuild button, ⌥⌘A, or automatically after a playlist changes."
        )
      }
    }
    .formStyle(.grouped)
  }

  // MARK: Private

  // Keys + defaults MUST match `UserPreferencesStore`
  // (`genreAnalysisMaxPlaylistTracks` / `genreAnalysisMaxPairsPerPlaylist`,
  // 500 / 30). The store clamps each ≥ 1 on read; the stepper ranges keep
  // the value sane from this side.
  @AppStorage("genreAnalysisMaxPlaylistTracks") private var maxPlaylistTracks = 500
  @AppStorage("genreAnalysisMaxPairsPerPlaylist") private var maxPairsPerPlaylist = 30
}
