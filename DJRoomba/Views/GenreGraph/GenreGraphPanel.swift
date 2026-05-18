import SwiftUI

/// The collapsible, resizable genre-graph panel docked at the bottom of the
/// detail pane.
///
/// - **Collapsible:** a chevron in the header toggles `collapsed`; collapsed
///   it is just the ~header-height bar (the graph is hidden but the bar
///   stays, so re-expanding is always discoverable — the native debug-area
///   pattern, not a vanishing panel).
/// - **Resizable:** a drag handle on the panel's top edge changes the body
///   height; both `collapsed` and the height are `@SceneStorage` so they
///   survive relaunch (scene state must live in the view layer, never inside
///   an `@Observable`).
///
/// The graph data + the (re)build live on `MusicController.genreGraphService`
/// (the observable source of truth); this view only renders it and triggers
/// the initial read. Width comes from the detail column; height is the only
/// dimension this panel manages.
struct GenreGraphPanel: View {

  // MARK: Internal

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      if !collapsed {
        GenreGraphResizeHandle(
          height: $panelHeight,
          range: Self.minBodyHeight ... Self.maxBodyHeight,
        )
      }
      GenreGraphPanelHeader(collapsed: $collapsed)
      if !collapsed {
        Divider()
        GenreGraphContent()
          .frame(height: CGFloat(panelHeight))
      }
    }
    .background(.background)
    .animation(.easeOut(duration: 0.22), value: collapsed)
    .task {
      // Show a graph built in a prior session / by an earlier
      // auto-reanalyze immediately, without forcing a fresh rebuild.
      await controller.genreGraphService.loadGraph()
    }
  }

  // MARK: Private

  /// The body's resizable bounds. The min keeps the force layout readable;
  /// the max stops the panel from swallowing the playlist detail above it
  /// on a tall window (the user can still collapse it entirely).
  private static let minBodyHeight: Double = 180
  private static let maxBodyHeight: Double = 680

  @Environment(MusicController.self) private var controller

  /// Default **expanded** at a modest height: the user explicitly asked for
  /// the visualizer in the main pane, so it should be visible on first run,
  /// but not so tall it crowds the track list (both stay usable; the user
  /// resizes or collapses to taste, and the choice persists).
  @SceneStorage("genreGraphPanelCollapsed") private var collapsed = false
  @SceneStorage("genreGraphPanelHeight") private var panelHeight = 300.0
}
