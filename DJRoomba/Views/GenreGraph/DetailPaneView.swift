import SwiftUI

/// The detail column's composition: the playlist detail (or the Recently
/// Played landing surface) takes the available space, with the
/// collapsible/resizable **genre tree** docked at the bottom — the native
/// "debug area" idiom (a secondary panel inside the main pane, not a
/// separate window or a third split column).
///
/// The tree is **library-wide**, so it is deliberately independent of the
/// selected playlist: it stays put while the user moves between playlists
/// above it. `GenreTreeMapPanel` owns its own collapse/height; collapsed it
/// is just a slim bar so the track list gets nearly the whole pane.
///
/// (The genre tree first shipped in a sheet; per user direction
/// 2026-05-22 it moved inline here, where the retired ForceGraph
/// `GenreGraphPanel` used to live.)
struct DetailPaneView: View {
  var body: some View {
    // Track list fills, genre tree docked beneath it. The trailing
    // `.padding(.bottom, nowPlayingBarHeight)` reserves the height of
    // the window-level now-playing bar (itself a translucent bottom
    // `safeAreaInset` on the `NavigationSplitView` that content draws
    // *under* by default). Without it the pane's footer / collapsed
    // bar lands in the bottom strip and is hidden behind the player;
    // with it the column reads top-to-bottom as track list → genre
    // tree → now-playing, no overlap.
    VStack(spacing: 0) {
      PlaylistDetailView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      GenreTreeMapPanel()
    }
    .padding(.bottom, Self.nowPlayingBarHeight)
  }

  /// Mirror of `NowPlayingBar`'s fixed height (`NowPlayingBar.swift`).
  private static let nowPlayingBarHeight: CGFloat = 60
}
