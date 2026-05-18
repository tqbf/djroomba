import SwiftUI

/// The detail column's composition: the existing playlist detail (or the
/// Recently Played landing surface) takes the available space, with the
/// collapsible/resizable genre-graph visualizer docked at the bottom — the
/// native "debug area" idiom (a secondary panel inside the main pane, not a
/// separate window or a third split column).
///
/// The graph is **library-wide** (genres that share *any* playlist), so it
/// is deliberately independent of the selected playlist: it stays put while
/// the user moves between playlists above it. `GenreGraphPanel` owns its own
/// collapse/height (scene-persisted); when collapsed it is just a slim bar so
/// the playlist detail gets nearly the whole pane.
struct DetailPaneView: View {
  var body: some View {
    VStack(spacing: 0) {
      PlaylistDetailView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      GenreGraphPanel()
    }
  }
}
