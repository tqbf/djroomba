import SwiftUI

/// The detail column's composition: the playlist detail (or the Recently
/// Played landing surface) takes the available space, with the
/// collapsible/resizable **bottom dock pane** at the bottom — the native
/// "debug area" idiom (a secondary panel inside the main pane, not a
/// separate window or a third split column).
///
/// The dock hosts two tabs — the DJ Roomba assistant chat and the genre
/// map — switched by a segmented picker in the pane's shared header.
/// Both surfaces are library-wide, so the dock is deliberately
/// independent of the selected playlist: it stays put while the user
/// moves between playlists above it. `BottomDockPane` owns its own
/// collapse/height; collapsed it is just a slim bar so the track list
/// gets nearly the whole pane.
///
/// (History: the bottom dock was originally the `GenreGraphPanel`
/// ForceGraph; replaced by the genre-tree-only `GenreTreeMapPanel`
/// 2026-05-22; widened to share with the DJ Roomba assistant
/// 2026-05-29 — the assistant moved out of its separate `Window` scene
/// into this shared pane at the same time.)
struct DetailPaneView: View {
  var body: some View {
    // Track list fills, bottom dock pane docked beneath it. The trailing
    // `.padding(.bottom, nowPlayingBarHeight)` reserves the height of
    // the window-level now-playing bar (itself a translucent bottom
    // `safeAreaInset` on the `NavigationSplitView` that content draws
    // *under* by default). Without it the pane's footer / collapsed
    // bar lands in the bottom strip and is hidden behind the player;
    // with it the column reads top-to-bottom as track list → bottom
    // dock → now-playing, no overlap.
    VStack(spacing: 0) {
      PlaylistDetailView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      BottomDockPane()
    }
    .padding(.bottom, Self.nowPlayingBarHeight)
  }

  /// Mirror of `NowPlayingBar`'s fixed height (`NowPlayingBar.swift`).
  private static let nowPlayingBarHeight: CGFloat = 60
}
