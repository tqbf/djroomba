import SwiftUI

/// The authorized shell: sidebar + detail split, persistent now-playing bar
/// pinned to the bottom (never gated behind navigation state), refresh in the
/// unified toolbar, and the collapsible extension `.inspector()` (the M3
/// `MusicContext`/`MusicCommand` boundary, realized in Phase 5) — collapsed by
/// default, toggled from the toolbar.
struct MainShellView: View {

  // MARK: Internal

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      PlaylistSidebar()
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      PlaylistDetailView()
        .navigationSplitViewColumnWidth(min: 480, ideal: 660)
    }
    .onAppear {
      columnVisibility = sidebarCollapsed ? .detailOnly : .all
    }
    .onChange(of: columnVisibility) { _, newValue in
      sidebarCollapsed = (newValue == .detailOnly)
    }
    .inspector(isPresented: $inspectorPresented) {
      ExtensionInspectorView()
        // Native macOS inspectors sit ~270–360pt. min:300 gives the
        // grouped `Form`'s `LabeledContent` rows (label + value) and
        // the wrapping footer explainer enough width to lay out
        // cleanly even at the inspector's narrowest. The window can
        // never be narrower than sidebarMin + detailMin + this
        // (≈ 220+480+300 = 1000) because the scene uses
        // `.windowResizability(.contentSize)` (see PlaylistPlayerApp)
        // — so the inspector column always gets its full min width
        // *inside* the window and its content fits without clipping
        // at either edge (the deeper Phase-5 D2 fix).
        .inspectorColumnWidth(min: 300, ideal: 320, max: 420)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await controller.refreshLibrary() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh playlists (⌘R)")
        .disabled(controller.isLibraryBusy)
      }
      // Standard macOS inspector toggle placement (trailing edge of the
      // toolbar, the side the panel slides from) — the native idiom
      // (Xcode / Freeform / Numbers). Reflects + flips presentation.
      ToolbarItem(placement: .automatic) {
        Button {
          inspectorPresented.toggle()
        } label: {
          Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help("Show or hide the extension inspector")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      NowPlayingBar()
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  /// Per-scene persisted sidebar collapse state. Kept in the view layer
  /// (scene storage must not live inside an `@Observable`). The window
  /// frame itself is restored by macOS automatic state restoration.
  @SceneStorage("sidebarCollapsed") private var sidebarCollapsed = false
  /// Extension inspector visibility — **collapsed by default** (it's a
  /// readiness surface, not a primary feature). Per-scene persisted so a
  /// user who opens it keeps it open across relaunch.
  @SceneStorage("inspectorPresented") private var inspectorPresented = false

  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

}
